import Foundation

/// Zero-network limit signals harvested from Claude Code's OWN local state.
/// The network usage endpoint goes 429-blind exactly when an account's
/// sessions are burning hardest (its org request bucket saturates) — but the
/// CLI leaves ground truth on disk (verified live 2026-08-12, five-agent
/// research round + local shape checks):
///
/// 1. `~/.claude/projects/**/*.jsonl` transcripts record the moment a session
///    DIES on the limit: `{"type":"assistant","error":"rate_limit",
///    "apiErrorStatus":429,...}` with message text
///    "You've hit your session limit · resets 10:50pm (America/Los_Angeles)".
///    That is a server-affirmed exhaustion signal for the account that owned
///    the shared CLI login at that timestamp — the exact event the widget
///    missed while 'Harbor' sat displayed at 67% (real 100%).
/// 2. `~/.claude.json` carries `cachedUsageUtilization` — the CLI's own last
///    fetch of the usage bars ({utilization.limits[], fetchedAtMs,
///    accountUuid}) — a free measurement the widget can adopt without
///    spending its per-IP budget.
///
/// All functions do file I/O — call them OFF the main actor (the sweep wraps
/// them in a detached task).
///
/// The `nonisolated` keyword on the enum is LOAD-BEARING, not decoration.
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes every unannotated type
/// implicitly `@MainActor`, so without it these statics are main-actor
/// isolated and the sweep's `Task.detached` wrapper is defeated: the compiler
/// inserts a hop back to main and the whole transcript walk (measured
/// 2026-09-01: 28,976 files / 3,529 directories / 12 GB) runs on the UI
/// thread once every 30-second sweep. The tell that it regressed is an
/// "expression is 'async' but is not marked with 'await'" warning at the call
/// site in `MenuBarManager.harvestLocalLimitSignals`.
nonisolated enum LocalLimitSignalService {

    // MARK: - Transcript rate-limit tripwire

    struct RateLimitEvent: Sendable, Equatable {
        let at: Date
        /// Parsed from the message text when present. The Fable message
        /// carries none; nothing is invented in its place.
        let resetsAt: Date?
        /// The window the message named (`classifyWindow`).
        let window: LimitWindow
    }

    private static let projectsRoot = NSString(string: "~/.claude/projects").expandingTildeInPath

    /// Subtrees pruned from the walk. `tool-results` holds the CLI's
    /// per-tool-call payload dumps — the overwhelming majority of the file
    /// count under `~/.claude/projects`, and never a transcript line, so
    /// descending it buys nothing and costs the whole sweep.
    private static let prunedDirectoryNames: Set<String> = ["tool-results"]

    /// Scans transcripts modified since `since` for rate-limit death events.
    /// Cheap by construction: mtime-filtered file list, tail-read only
    /// (`tailBytes`), events older than `since` ignored. Returns events
    /// newest-last.
    static func scanRateLimitEvents(
        since: Date,
        root: String = projectsRoot,
        tailBytes: Int = 262_144,
        now: Date = Date()
    ) -> [RateLimitEvent] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var events: [RateLimitEvent] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                if Self.prunedDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension == "jsonl" else { continue }
            guard let mtime = values?.contentModificationDate,
                  mtime >= since else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(),
                  let tail = String(data: data, encoding: .utf8) else { continue }
            for line in tail.split(separator: "\n") {
                guard line.contains("\"rate_limit\"") else { continue }
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      obj["error"] as? String == "rate_limit",
                      let timestamp = obj["timestamp"] as? String,
                      let at = ISO8601DateFormatter.withFractional.date(from: timestamp)
                          ?? ISO8601DateFormatter.plain.date(from: timestamp),
                      at >= since else { continue }
                let text = messageText(of: obj)
                events.append(RateLimitEvent(at: at, resetsAt: parseResetTime(from: text, eventTime: at),
                                             window: classifyWindow(text)))
            }
        }
        return events.sorted { $0.at < $1.at }
    }

    private static func messageText(of obj: [String: Any]) -> String {
        guard let message = obj["message"] as? [String: Any] else { return "" }
        if let content = message["content"] as? String { return content }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return ""
    }

    /// Which window the message names — see `LimitWindow` for the catalogue.
    /// Fable is tested first: its texts never say "session", and a model
    /// name may carry a version ("Fable 5 limit").
    static func classifyWindow(_ text: String) -> LimitWindow {
        let lower = text.lowercased()
        func names(_ pattern: String) -> Bool {
            lower.range(of: pattern, options: .regularExpression) != nil
        }
        if names(#"\bfable(\s+[\d.]+)?\s+limit\b"#) { return .fableWeekly }
        if names(#"\bweekly(\s+usage)?\s+limit\b"#) { return .weekly }
        if names(#"\bsession\s+limit\b"#) { return .session }
        return .unknown
    }

    /// Parses "… resets 10:50pm (America/Los_Angeles)" (also "resets 3pm")
    /// and the dated form the weekly and Fable texts use when the boundary
    /// is not today, "resets Aug 22 at 3pm (America/Denver)". Returns the
    /// next occurrence of that wall clock in the named zone at/after the
    /// event time; nil when the text carries no reset.
    static func parseResetTime(from text: String, eventTime: Date) -> Date? {
        if let g = firstMatch(#"resets\s+([A-Za-z]{3,9})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#, in: text) {
            guard let month = monthNumber(g[1]), let day = Int(g[2]), let hour = Int(g[3]) else { return nil }
            return wallClock(month: month, day: day, hour: hour, minute: Int(g[4]) ?? 0,
                             meridiem: g[5], zoneName: g[6], eventTime: eventTime)
        }
        if let g = firstMatch(#"resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#, in: text) {
            guard let hour = Int(g[1]) else { return nil }
            return wallClock(month: nil, day: nil, hour: hour, minute: Int(g[2]) ?? 0,
                             meridiem: g[3], zoneName: g[4], eventTime: eventTime)
        }
        return nil
    }

    /// Capture groups of the first case-insensitive match ("" for an
    /// unmatched optional group), or nil.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static let monthAbbreviations = ["jan", "feb", "mar", "apr", "may", "jun",
                                             "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func monthNumber(_ name: String) -> Int? {
        monthAbbreviations.firstIndex(of: String(name.lowercased().prefix(3))).map { $0 + 1 }
    }

    /// The reset is always in the event's future: a wall clock earlier than
    /// the event means tomorrow; a dated one earlier means next year.
    private static func wallClock(
        month: Int?, day: Int?, hour hourRaw: Int, minute: Int,
        meridiem: String, zoneName: String, eventTime: Date
    ) -> Date? {
        guard let zone = TimeZone(identifier: zoneName) else { return nil }
        var hour = hourRaw % 12
        if meridiem.lowercased() == "pm" { hour += 12 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = calendar.dateComponents([.year, .month, .day], from: eventTime)
        if let month, let day {
            components.month = month
            components.day = day
        }
        components.hour = hour
        components.minute = minute
        guard let candidate = calendar.date(from: components) else { return nil }
        if candidate >= eventTime { return candidate }
        return calendar.date(byAdding: month == nil ? .day : .year, value: 1, to: candidate)
    }

    // MARK: - CLI cached usage bars

    struct CLICachedUsage: Sendable {
        let accountUuid: String
        let fetchedAt: Date
        let sessionPercent: Double?
        let sessionResetsAt: Date?
        let weeklyPercent: Double?
        let weeklyResetsAt: Date?
        let fablePercent: Double?
        let fableResetsAt: Date?
    }

    private static let claudeConfigPath = NSString(string: "~/.claude.json").expandingTildeInPath

    /// Reads the CLI's own cached usage bars — a free, already-paid-for
    /// measurement for whichever account the CLI is logged into.
    static func readCLICachedUsage(path: String = claudeConfigPath) -> CLICachedUsage? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let accountUuid = cached["accountUuid"] as? String,
              let fetchedAtMs = cached["fetchedAtMs"] as? Double,
              let utilization = cached["utilization"] as? [String: Any],
              let limits = utilization["limits"] as? [[String: Any]] else { return nil }

        func limit(kind: String, scopeDisplayName: String? = nil) -> (Double, Date?)? {
            for entry in limits where entry["kind"] as? String == kind {
                if let wanted = scopeDisplayName {
                    let scoped = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                    guard scoped == wanted else { continue }
                }
                guard let percent = entry["percent"] as? Double ?? (entry["percent"] as? Int).map(Double.init) else { continue }
                let resets = (entry["resets_at"] as? String).flatMap {
                    ISO8601DateFormatter.withFractional.date(from: $0) ?? ISO8601DateFormatter.plain.date(from: $0)
                }
                return (percent, resets)
            }
            return nil
        }

        let session = limit(kind: "session")
        let weekly = limit(kind: "weekly_all")
        let fable = limit(kind: "weekly_scoped", scopeDisplayName: "Fable")
        return CLICachedUsage(
            accountUuid: accountUuid,
            fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000),
            sessionPercent: session?.0,
            sessionResetsAt: session?.1,
            weeklyPercent: weekly?.0,
            weeklyResetsAt: weekly?.1,
            fablePercent: fable?.0,
            fableResetsAt: fable?.1
        )
    }
}

// Read from the nonisolated scan, i.e. off the main actor. Foundation date
// formatters are documented thread-safe for parsing, and these two are
// configured once and never mutated, so the unchecked annotation states a fact
// rather than waiving one.
private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
}
