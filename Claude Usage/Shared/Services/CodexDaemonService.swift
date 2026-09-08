//
//  CodexDaemonService.swift
//  Claude Usage
//
//  Awareness of the one Codex process a profile switch cannot reach.
//
//  The Codex standalone build runs interactive `codex` sessions through a
//  shared, detached daemon (`…/packages/standalone/current/codex app-server
//  --listen unix://…`, parent launchd). The daemon loads `~/.codex/auth.json`
//  ONCE at launch and never reloads it — verified 2026-09-04: its rate-limit
//  series ran unbroken across a rewrite — while `codex exec` runs in-process
//  and reads the file fresh. So a widget switch reaches headless runs and the
//  ChatGPT desktop app, but NOT terminals until the daemon restarts (it
//  respawns on the next `codex` launch). Design: docs/specs/codex-daemon-awareness.md.
//
//  Four things live here, the pure parts as enums so the tests need no
//  process, socket or file:
//
//  1. `CodexDaemon` — a PATH-ANCHORED process match (never the bare name
//     `codex`, which would hit the user's TUIs, the desktop app's embedded
//     codex and every `codex exec`), plus the attached sessions (children
//     named `codex-code-mode-host`, aged by `ps etime`; the desktop app's
//     helpers under the daemon are not sessions).
//  2. `CodexTerminals` — which account the daemon is serving, derived ONLY from
//     the newest daemon-written rollout's `rate_limits.primary.resets_at`
//     matched to the profiles' cached reset stamps. Nothing is inferred beyond
//     the stamp: no match, or two matches, reads "unknown account".
//  3. `CodexDaemonRestartPolicy` — PURE: whether a switch restarts the daemon.
//     An exhausted or dead outgoing login restarts it regardless of attached
//     sessions (they are all already broken on it — the 2026-09-08 incident,
//     where a stale host from the previous evening blocked the restart while
//     every new terminal inherited the exhausted login); a usable one restarts
//     only with no LIVE interactive session attached.
//  4. `CodexDaemonService` — after every Codex activation (observed through
//     `.providerOwnerClaimed`, so no activation seam is edited) it restarts
//     the daemon per the policy — SIGTERM, verified exit, one SIGKILL
//     escalation — or records a HOLD: the user is told with a Restart action,
//     told once more after ten minutes if the daemon still holds the old
//     login, and the dashboard's Codex block shows it in red until the daemon
//     is seen gone.
//

import Foundation

// MARK: - Process records

/// One row of `ps -axo pid=,ppid=,etime=,command=`.
nonisolated struct ProcessRecord: Equatable {
    var pid: Int32
    var ppid: Int32
    /// The command as `ps` prints it: the executable path, then the arguments.
    var command: String
    /// Seconds since the process started (`ps` `etime`); nil when the column
    /// did not parse. Ages the attached sessions.
    var elapsed: TimeInterval? = nil

    /// The executable — the first whitespace-delimited token. The daemon's
    /// path (`~/.codex/packages/standalone/…`) contains no spaces.
    var executablePath: String {
        command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? command
    }

    var arguments: [String] {
        command.split(separator: " ", omittingEmptySubsequences: true).dropFirst().map(String.init)
    }

    var executableName: String { (executablePath as NSString).lastPathComponent }
}

// MARK: - The daemon

nonisolated enum CodexDaemon {
    /// Where the standalone build lives, relative to the Codex home. The match
    /// is anchored here so nothing outside the standalone package can qualify.
    nonisolated static let standalonePackagesComponent = "packages/standalone/"
    /// The daemon's control socket, relative to the Codex home. Present only
    /// while it runs; corroboration, never the evidence.
    nonisolated static let controlSocketRelativePath = "app-server-control/app-server-control.sock"
    /// The per-session host the daemon (or a `codex exec`) spawns.
    nonisolated static let sessionHostExecutable = "codex-code-mode-host"

    /// One `codex-code-mode-host` under the daemon: an interactive session.
    nonisolated struct AttachedSession: Equatable {
        var pid: Int32
        /// Seconds since the host started; nil when `ps` gave none.
        var age: TimeInterval?
        /// Older than `staleSessionAge` while no terminal rollout has been
        /// written for `terminalActivityWindow`: an abandoned TUI nobody is
        /// typing into, which must not block a restart.
        var isStale: Bool
    }

    nonisolated struct Status: Equatable {
        var daemon: ProcessRecord?
        var sessions: [AttachedSession]
        var controlSocketPresent: Bool
        var isRunning: Bool { daemon != nil }
        /// The sessions that block a headroom-based restart: live, not stale.
        var attachedSessions: Int { sessions.filter { !$0.isStale }.count }
        var staleSessions: Int { sessions.filter(\.isStale).count }
    }

    /// A code-mode host older than this, with no terminal rollout written
    /// recently, is an abandoned TUI. The 2026-09-08 incident's blocker had
    /// started the previous evening, 15 h before the switch.
    nonisolated static let staleSessionAge: TimeInterval = 12 * 3600
    /// A terminal rollout written this recently means SOME TUI is in use —
    /// which host it belongs to is unknowable — so no host counts as stale.
    nonisolated static let terminalActivityWindow: TimeInterval = 30 * 60

    /// Parses `ps -axo pid=,ppid=,etime=,command=`: two right-aligned integer
    /// columns, the elapsed-time column, then the command to the end of the
    /// line.
    nonisolated static func parseProcessList(_ output: String) -> [ProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine -> ProcessRecord? in
            let line = String(rawLine)
            let scanner = Scanner(string: line)
            scanner.charactersToBeSkipped = .whitespaces
            guard let pid = scanner.scanInt32(), let ppid = scanner.scanInt32(),
                  let etime = scanner.scanUpToCharacters(from: .whitespaces) else { return nil }
            let rest = String(line[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            return ProcessRecord(pid: pid, ppid: ppid, command: rest, elapsed: parseElapsed(etime))
        }
    }

    /// `ps` `etime`: `[[dd-]hh:]mm:ss`. Nil for anything else.
    nonisolated static func parseElapsed(_ text: String) -> TimeInterval? {
        var days = 0
        var clock = Substring(text)
        if let dash = clock.firstIndex(of: "-") {
            guard let parsed = Int(clock[..<dash]) else { return nil }
            days = parsed
            clock = clock[clock.index(after: dash)...]
        }
        let fields = clock.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(fields.count), fields.allSatisfy({ $0 != nil }) else { return nil }
        let seconds = fields.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return TimeInterval(days * 86_400 + seconds)
    }

    /// Path-anchored: `<codexHome>/packages/standalone/…/codex` invoked as
    /// `app-server`. A bare `codex`, the desktop app's embedded codex, a
    /// standalone `codex exec`, and the code-mode host all fail this.
    nonisolated static func isDaemonCommand(_ command: String, codexHome: URL) -> Bool {
        let record = ProcessRecord(pid: 0, ppid: 0, command: command)
        let anchor = codexHome.standardizedFileURL.path + "/" + standalonePackagesComponent
        guard record.executablePath.hasPrefix(anchor), record.executableName == "codex" else { return false }
        return record.arguments.first == "app-server"
    }

    nonisolated static func daemon(in processes: [ProcessRecord], codexHome: URL) -> ProcessRecord? {
        processes.first { isDaemonCommand($0.command, codexHome: codexHome) }
    }

    /// Interactive sessions attached to the daemon: its children named
    /// `codex-code-mode-host`, and ONLY those. The same host under a `codex
    /// exec` process is a headless run, not a terminal. The ChatGPT desktop
    /// app parks its own helpers under the daemon too (`Codex Computer
    /// Use.app`, `cua_node` — some thirty of them on 2026-09-08); none is a
    /// terminal and none counts. A host older than `staleAfter` is stale
    /// unless terminals are active (`terminalsActive(newestTerminalWrite:)`).
    nonisolated static func attachedSessions(
        daemonPid: Int32, in processes: [ProcessRecord],
        staleAfter: TimeInterval = staleSessionAge, terminalsActive: Bool = true
    ) -> [AttachedSession] {
        processes
            .filter { $0.ppid == daemonPid && $0.executableName == sessionHostExecutable }
            .map { host in
                AttachedSession(
                    pid: host.pid, age: host.elapsed,
                    isStale: !terminalsActive && (host.elapsed ?? 0) >= staleAfter
                )
            }
    }

    /// True when a daemon-written rollout was modified within `window` of
    /// `now`. Nil — no terminal rollout among the newest files — is inactive.
    nonisolated static func terminalsActive(
        newestTerminalWrite: Date?, now: Date, window: TimeInterval = terminalActivityWindow
    ) -> Bool {
        guard let newestTerminalWrite else { return false }
        return now.timeIntervalSince(newestTerminalWrite) < window
    }

    nonisolated static func status(
        processes: [ProcessRecord], codexHome: URL, controlSocketPresent: Bool, terminalsActive: Bool = true
    ) -> Status {
        let daemon = daemon(in: processes, codexHome: codexHome)
        return Status(
            daemon: daemon,
            sessions: daemon.map { attachedSessions(daemonPid: $0.pid, in: processes, terminalsActive: terminalsActive) } ?? [],
            controlSocketPresent: controlSocketPresent
        )
    }

    /// "pid 55300 (15h 25m, stale), pid 55402 (40s)" — or "none".
    nonisolated static func describe(_ sessions: [AttachedSession]) -> String {
        guard !sessions.isEmpty else { return "none" }
        return sessions.map { session in
            var parts: [String] = []
            if let age = session.age { parts.append(describeAge(age)) }
            if session.isStale { parts.append("stale") }
            return "pid \(session.pid)" + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
        }.joined(separator: ", ")
    }

    nonisolated static func describeAge(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 3600 { return "\(total / 3600)h \(total % 3600 / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }
}

// MARK: - Restart policy

/// Whether a Codex switch restarts the daemon. PURE: the service feeds it
/// the toggle, the outgoing login's state and the live session count.
///
/// The 2026-09-08 rule: when the switch left the previous owner because of a
/// limit, every session attached to the daemon is already broken on that
/// login (they 429, and every NEW terminal inherits it), so a restart costs
/// nothing and waiting costs the user their terminals. A login that still
/// works keeps the older rule — restart only when no live session would lose
/// its context.
enum CodexDaemonRestartPolicy {
    enum Verdict: Equatable {
        /// The outgoing login is exhausted or dead: restart regardless of
        /// attached sessions.
        case restartExhaustedLogin
        /// The outgoing login works, and no live session is on it.
        case restartIdle
        case holdToggleOff
        /// The outgoing login works and this many live sessions use it.
        case holdLiveSessions(Int)

        var restarts: Bool {
            switch self {
            case .restartExhaustedLogin, .restartIdle: return true
            case .holdToggleOff, .holdLiveSessions: return false
            }
        }
    }

    static func verdict(restartOnSwitch: Bool, outgoingLoginExhausted: Bool, liveSessions: Int) -> Verdict {
        guard restartOnSwitch else { return .holdToggleOff }
        if outgoingLoginExhausted { return .restartExhaustedLogin }
        return liveSessions == 0 ? .restartIdle : .holdLiveSessions(liveSessions)
    }

    /// The outgoing login is exhausted when the auto-switch would have left
    /// it for a limit: a SERVER-AFFIRMED throttle stamp, a session or weekly
    /// window at or over its switch threshold (only while that window is
    /// still open — a cache whose window already reset proves nothing), or
    /// the dead-login flag. An inferred stamp is suspicion, never proof, and
    /// does not count: restarting under live sessions on a guess is exactly
    /// the cost the inference rules exist to avoid.
    static func outgoingLoginIsExhausted(
        usage: ClaudeUsage?, loginMarkedDead: Bool,
        sessionThreshold: Double, weeklyThreshold: Double, now: Date = Date()
    ) -> Bool {
        if loginMarkedDead { return true }
        guard let usage else { return false }
        if let until = usage.rateLimitedUntil, until > now, usage.rateLimitedInferred != true { return true }
        if usage.providesSessionWindow, usage.sessionResetTime > now, usage.sessionPercentage >= sessionThreshold { return true }
        if usage.weeklyResetTime > now, usage.weeklyPercentage >= weeklyThreshold { return true }
        return false
    }
}

// MARK: - Which account the terminals are on

nonisolated enum CodexTerminals {
    /// The `session_meta.payload.originator` of a daemon-hosted (TUI) session.
    /// `codex_exec` rollouts are written by the in-process run and say nothing
    /// about terminals.
    nonisolated static let daemonOriginator = "codex-tui"

    /// What the newest daemon-written rollout says.
    struct Evidence: Equatable {
        /// `rate_limits.primary.resets_at`.
        var resetsAt: Date
        /// `rate_limits.primary.window_minutes` — decides which cached reset to
        /// compare against (≥ 6 days: weekly; else the 5-hour session).
        var windowMinutes: Int?
        /// The session's `session_meta` timestamp: the daemon has served this
        /// account at least since then.
        var sessionStartedAt: Date
    }

    /// The resolved line. `profileName` nil = the stamp matched no single
    /// Codex profile.
    struct Line: Equatable {
        var profileName: String?
        var since: Date
    }

    private nonisolated static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private nonisolated(unsafe) static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()

    nonisolated static func originator(ofSessionMetaLine line: String) -> String? {
        guard let object = json(line), object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else { return nil }
        return payload["originator"] as? String
    }

    nonisolated static func sessionStart(ofSessionMetaLine line: String) -> Date? {
        guard let object = json(line) else { return nil }
        let payload = object["payload"] as? [String: Any]
        guard let stamp = (payload?["timestamp"] as? String) ?? (object["timestamp"] as? String) else { return nil }
        return isoWithFraction.date(from: stamp) ?? isoPlain.date(from: stamp)
    }

    /// `payload.rate_limits.primary.resets_at` (+ `window_minutes`) of a
    /// `token_count` line, or nil for any other line.
    nonisolated static func rateLimitStamp(inLine line: String) -> RateLimitStamp? {
        guard line.contains("\"rate_limits\""), let object = json(line),
              let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any],
              let primary = limits["primary"] as? [String: Any],
              let resets = primary["resets_at"] as? Double else { return nil }
        return RateLimitStamp(resetsAt: Date(timeIntervalSince1970: resets), windowMinutes: primary["window_minutes"] as? Int)
    }

    private nonisolated static func minute(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 60).rounded(.down)) }

    /// The UNIQUE Codex profile whose cached reset equals the stamp to the
    /// minute (the usage API jitters ±1 s across fetches). Claude and Grok
    /// profiles never match; two Codex matches are ambiguous and resolve to nil.
    @MainActor static func profile(matching evidence: Evidence, in profiles: [Profile]) -> Profile? {
        let weekly = (evidence.windowMinutes ?? 10080) >= 6 * 24 * 60
        let target = minute(evidence.resetsAt)
        let matches = profiles.filter { profile in
            guard profile.carriesCodexAccount, let usage = profile.claudeUsage else { return false }
            return minute(weekly ? usage.weeklyResetTime : usage.sessionResetTime) == target
        }
        return matches.count == 1 ? matches[0] : nil
    }

    @MainActor static func line(from evidence: Evidence?, profiles: [Profile]) -> Line? {
        guard let evidence else { return nil }
        return Line(profileName: profile(matching: evidence, in: profiles)?.name, since: evidence.sessionStartedAt)
    }

    nonisolated static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "Terminals: Cedar since 17:31" / "Terminals: unknown account since
    /// 17:31" / "Terminals: unknown".
    @MainActor static func format(_ line: Line?, clock: DateFormatter = clock) -> String {
        guard let line else { return "codex_daemon.terminals_unknown".localized }
        let who = line.profileName ?? "codex_daemon.terminals_unknown_account".localized
        return "codex_daemon.terminals_line".localized(with: who, clock.string(from: line.since))
    }

    // MARK: Rollout scan (file I/O — call off the main actor)

    /// One rollout as the day directory lists it. Size and modification date
    /// are the identity the per-file cache keys on: an append-only file that
    /// reports the same pair has nothing new to read.
    struct RolloutFile: Equatable {
        var url: URL
        var size: Int
        var modified: Date
    }

    /// `rate_limits.primary` of one `token_count` line.
    struct RateLimitStamp: Equatable {
        var resetsAt: Date
        var windowMinutes: Int?
    }

    /// What one rollout's head says: its originator and session start.
    /// `complete` is true when the first line was read to its newline, or the
    /// fields were found closed inside the chunk — only then is the verdict
    /// cached, so a file caught mid-creation is re-read on the next scan
    /// instead of being filed as "not a terminal" forever.
    struct HeadInfo: Equatable {
        var originator: String?
        var sessionStart: Date?
        var complete: Bool
    }

    /// Byte budget of the bounded read. A rollout is needed for exactly two
    /// lines — the `session_meta` first line and the LAST `rate_limits` line —
    /// and the files are megabytes (2026-09-05: the newest 30 totalled 55 MB,
    /// the largest 6 MB; reading them whole every 30 s sweep cost the app 10%
    /// of a core), so the head and the tail are read with seeks and the middle
    /// never is. Measured on those 30 files: the first line is ~22 KB (the
    /// session's instructions ride in it) with the originator in its first few
    /// hundred bytes, and the last stamp sits ≤ 14 KB from the end. Worst case
    /// per file is `headMax + tailMax` = 320 KB.
    nonisolated enum ReadBudget {
        /// First attempt at the head; grown to `headMax` only when the chunk
        /// neither ends the line nor closes the fields the scan needs.
        nonisolated static let headInitial = 4 * 1024
        nonisolated static let headMax = 64 * 1024
        /// The tail; grown ONCE to `tailMax` when no stamp parses in it. The
        /// growth reads only the bytes in front of the first chunk.
        nonisolated static let tailInitial = 64 * 1024
        nonisolated static let tailMax = 256 * 1024
        nonisolated static var perFileMax: Int { headMax + tailMax }
    }

    /// The newest daemon-written rollout that carries a rate-limit stamp, read
    /// from `<sessionsRoot>/YYYY/MM/DD/*.jsonl`: the two newest day directories,
    /// the newest `maxFiles` files by modification date, first `codex-tui`
    /// rollout with a stamp wins, and the LAST stamp in it is the one reported.
    /// Every file costs one stat; an unchanged file costs nothing more, a
    /// non-terminal file only ever costs its head once, and a terminal file
    /// that grew costs its tail (`RolloutScanCache`).
    nonisolated static func newestDaemonEvidence(
        sessionsRoot: URL, fileManager: FileManager = .default, maxFiles: Int = 30,
        cache: RolloutScanCache = .shared
    ) -> Evidence? {
        scanRollouts(sessionsRoot: sessionsRoot, fileManager: fileManager, maxFiles: maxFiles, cache: cache).evidence
    }

    /// One pass over the newest rollouts: the terminals-line evidence plus
    /// the modification date of the newest daemon-written rollout, stamped or
    /// not — the last time ANY terminal session wrote, which is what decides
    /// whether an old code-mode host is stale.
    nonisolated struct Scan: Equatable {
        var evidence: Evidence?
        var newestTerminalWrite: Date?
    }

    nonisolated static func scanRollouts(
        sessionsRoot: URL, fileManager: FileManager = .default, maxFiles: Int = 30,
        cache: RolloutScanCache = .shared
    ) -> Scan {
        let files = recentRolloutFiles(sessionsRoot: sessionsRoot, fileManager: fileManager, limit: maxFiles)
        cache.beginScan(retaining: Set(files.map(\.url.path)))
        var scan = Scan()
        // Newest first, so the first terminal rollout IS the newest write and
        // the first stamped one is the evidence; both found, nothing else is
        // opened.
        for file in files {
            guard let entry = examine(file, cache: cache), entry.originator == daemonOriginator else { continue }
            if scan.newestTerminalWrite == nil { scan.newestTerminalWrite = file.modified }
            guard let stamp = entry.stamp else { continue }
            scan.evidence = Evidence(
                resetsAt: stamp.resetsAt, windowMinutes: stamp.windowMinutes,
                sessionStartedAt: entry.sessionStart ?? file.modified
            )
            break
        }
        return scan
    }

    /// Newest-first rollout files from the two newest day directories.
    nonisolated static func recentRolloutFiles(sessionsRoot: URL, fileManager: FileManager, limit: Int) -> [RolloutFile] {
        func subdirectories(_ url: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        // sessions/YYYY/MM/DD — date-named, so lexical order is date order.
        var days: [URL] = []
        for year in subdirectories(sessionsRoot) where days.count < 2 {
            for month in subdirectories(year) where days.count < 2 {
                for day in subdirectories(month) where days.count < 2 { days.append(day) }
            }
        }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = days.flatMap { day -> [RolloutFile] in
            ((try? fileManager.contentsOfDirectory(at: day, includingPropertiesForKeys: Array(keys))) ?? [])
                .filter { $0.pathExtension == "jsonl" }
                .map { url in
                    let values = try? url.resourceValues(forKeys: keys)
                    return RolloutFile(
                        url: url, size: values?.fileSize ?? 0,
                        modified: values?.contentModificationDate ?? .distantPast
                    )
                }
        }
        return files.sorted { $0.modified > $1.modified }.prefix(limit).map { $0 }
    }

    /// One file through the cache: a known non-terminal costs nothing, an
    /// unchanged terminal costs nothing, a terminal that grew costs its tail.
    /// Nil = the file is empty or could not be opened.
    nonisolated static func examine(_ file: RolloutFile, cache: RolloutScanCache) -> RolloutScanCache.Entry? {
        let path = file.url.path
        let cached = cache.entry(for: path)
        if let cached {
            if cached.originator != daemonOriginator { return cached }
            if cached.size == file.size && cached.modified == file.modified { return cached }
        }
        guard file.size > 0, let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        cache.recordFileOpened()

        let head = cached.map { HeadInfo(originator: $0.originator, sessionStart: $0.sessionStart, complete: true) }
            ?? readHead(handle, cache: cache)
        var entry = RolloutScanCache.Entry(
            originator: head.originator, sessionStart: head.sessionStart,
            size: file.size, modified: file.modified, stamp: nil
        )
        if head.originator == daemonOriginator {
            entry.stamp = readTailStamp(handle, fileSize: file.size, cache: cache)
        }
        if head.complete { cache.store(entry, for: path) }
        return entry
    }

    /// The head, from the start of the file: `headInitial` bytes, then the
    /// rest of `headMax` only if the first chunk settled nothing.
    nonisolated static func readHead(_ handle: FileHandle, cache: RolloutScanCache) -> HeadInfo {
        guard (try? handle.seek(toOffset: 0)) != nil,
              var data = try? handle.read(upToCount: ReadBudget.headInitial) else {
            return HeadInfo(originator: nil, sessionStart: nil, complete: false)
        }
        cache.record(bytesRead: data.count)
        var info = Self.head(fromBytes: data)
        if !info.complete, data.count == ReadBudget.headInitial,
           let more = try? handle.read(upToCount: ReadBudget.headMax - ReadBudget.headInitial) {
            cache.record(bytesRead: more.count)
            data.append(more)
            info = Self.head(fromBytes: data)
        }
        return info
    }

    /// Parses the first line out of the head bytes. A line closed by a newline
    /// is parsed as JSON; a chunk that cuts the line short is searched for the
    /// closed `"type"` / `"originator"` / `"timestamp"` fields instead — they
    /// sit in the line's first few hundred bytes, ahead of the instructions
    /// text that makes it ~22 KB.
    nonisolated static func head(fromBytes data: Data) -> HeadInfo {
        if let newline = data.firstIndex(of: 0x0A) {
            let line = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
            return HeadInfo(
                originator: originator(ofSessionMetaLine: line),
                sessionStart: sessionStart(ofSessionMetaLine: line),
                complete: true
            )
        }
        let text = String(decoding: data, as: UTF8.self)
        guard quotedValue(forKey: "type", in: text) == "session_meta",
              let originator = quotedValue(forKey: "originator", in: text) else {
            return HeadInfo(originator: nil, sessionStart: nil, complete: false)
        }
        let start = quotedValue(forKey: "timestamp", in: text)
            .flatMap { isoWithFraction.date(from: $0) ?? isoPlain.date(from: $0) }
        return HeadInfo(originator: originator, sessionStart: start, complete: true)
    }

    /// `"key":"value"` → value, for the flat string fields of a cut-short line.
    private nonisolated static func quotedValue(forKey key: String, in text: String) -> String? {
        guard let range = text.range(of: "\"\(key)\":\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// The LAST parsable stamp in the file's tail: `tailInitial` bytes from the
    /// end, then the bytes in front of them up to `tailMax` if none parsed.
    nonisolated static func readTailStamp(_ handle: FileHandle, fileSize: Int, cache: RolloutScanCache) -> RateLimitStamp? {
        var data = Data()
        var chunkStart = fileSize
        for target in [ReadBudget.tailInitial, ReadBudget.tailMax] {
            let newStart = max(0, fileSize - target)
            if newStart < chunkStart {
                guard (try? handle.seek(toOffset: UInt64(newStart))) != nil,
                      let front = try? handle.read(upToCount: chunkStart - newStart) else { return nil }
                cache.record(bytesRead: front.count)
                data = front + data
                chunkStart = newStart
            }
            if let stamp = lastStamp(inTailBytes: data, chunkStartsAtFileStart: chunkStart == 0) { return stamp }
            if chunkStart == 0 { return nil }
        }
        return nil
    }

    /// Walks the `"rate_limits"` lines of a tail chunk backwards and returns the
    /// first that parses. A line that begins before the chunk is cut short and
    /// stops the walk — the caller grows the chunk or gives up.
    nonisolated static func lastStamp(inTailBytes data: Data, chunkStartsAtFileStart: Bool) -> RateLimitStamp? {
        let needle = Data("\"rate_limits\"".utf8)
        var searchEnd = data.endIndex
        while searchEnd > data.startIndex,
              let hit = data.range(of: needle, options: .backwards, in: data.startIndex..<searchEnd) {
            let lineStart: Data.Index
            if let newline = data[data.startIndex..<hit.lowerBound].lastIndex(of: 0x0A) {
                lineStart = data.index(after: newline)
            } else if chunkStartsAtFileStart {
                lineStart = data.startIndex
            } else {
                return nil
            }
            let lineEnd = data[hit.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = String(decoding: data[lineStart..<lineEnd], as: UTF8.self)
            if let stamp = rateLimitStamp(inLine: line) { return stamp }
            searchEnd = lineStart
        }
        return nil
    }
}

/// Per-file memory of what the bounded read found, so a scan re-reads only
/// what changed. The head verdict (originator, session start) is learned once
/// per path — an append-only file's first line never changes — and the stamp
/// is tied to the (size, modification date) pair it was read at. Entries for
/// files that drop out of the newest set are pruned at the start of each scan.
/// Lock-protected: the scan runs on a utility queue, the tests on the main one.
nonisolated final class RolloutScanCache: @unchecked Sendable {
    nonisolated static let shared = RolloutScanCache()

    struct Entry: Equatable {
        var originator: String?
        var sessionStart: Date?
        var size: Int
        var modified: Date
        var stamp: CodexTerminals.RateLimitStamp?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var scanBytes = 0
    private var scanFilesOpened = 0
    private var scans = 0

    init() {}

    var count: Int { lock.withLock { entries.count } }
    /// Bytes read from disk by the most recent scan (stats excluded).
    var lastScanBytesRead: Int { lock.withLock { scanBytes } }
    /// Files the most recent scan opened.
    var lastScanFilesOpened: Int { lock.withLock { scanFilesOpened } }
    var scanCount: Int { lock.withLock { scans } }

    func entry(for path: String) -> Entry? { lock.withLock { entries[path] } }

    func store(_ entry: Entry, for path: String) { lock.withLock { entries[path] = entry } }

    func beginScan(retaining paths: Set<String>) {
        lock.withLock {
            entries = entries.filter { paths.contains($0.key) }
            scanBytes = 0
            scanFilesOpened = 0
            scans += 1
        }
    }

    func recordFileOpened() { lock.withLock { scanFilesOpened += 1 } }

    func record(bytesRead: Int) { lock.withLock { scanBytes += bytesRead } }
}

// MARK: - Service

final class CodexDaemonService {
    static let shared = CodexDaemonService()

    private var observer: NSObjectProtocol?
    private var refreshInFlight = false

    /// What the terminals line last resolved to (nil = no daemon rollout with a
    /// stamp was found). Refreshed at the end of every sweep.
    private(set) var terminals: CodexTerminals.Line?
    /// The last daemon scan, for the Settings card.
    private(set) var lastStatus: CodexDaemon.Status?

    /// The dashboard / inspector text.
    var terminalsText: String { CodexTerminals.format(terminals) }

    /// A daemon still holding the previous login after a switch, until it is
    /// seen gone. The dashboard's Codex block shows it in red with a Restart
    /// button, and the notification is re-posted once after `reminderDelay`
    /// while it stands. Superseded by the next Codex switch.
    struct Hold: Equatable {
        var daemonPid: Int32
        var previousOwnerName: String?
        var newOwnerName: String
        var since: Date
        var reminded = false
    }

    /// How long after a hold the user is told again, if the daemon still
    /// holds the old login. The 2026-09-08 notice went unanswered for an hour
    /// while every new terminal inherited the exhausted login.
    static let reminderDelay: TimeInterval = 10 * 60

    private(set) var hold: Hold? {
        didSet {
            guard hold != oldValue else { return }
            NotificationCenter.default.post(name: .codexDaemonStateChanged, object: nil)
        }
    }
    private var reminderTask: Task<Void, Never>?

    /// The dashboard's red line while a hold stands.
    var holdText: String? { hold.map { Self.holdText($0) } }

    static func holdText(_ hold: Hold) -> String {
        "codex_daemon.hold_line".localized(with: hold.previousOwnerName ?? "codex_daemon.terminals_unknown_account".localized)
    }

    private init() {}

    /// Observes Codex activations. `.providerOwnerClaimed` with
    /// `provider == codex` and `cause == activate` is posted by every
    /// activation path — ⇄ menu, dashboard, inspector, auto-switch — exactly
    /// once per real handover, so no activation seam has to know about this.
    /// `previousOwnerId` names the login the daemon still holds.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .providerOwnerClaimed, object: nil, queue: .main
        ) { [weak self] note in
            guard note.userInfo?["provider"] as? String == "codex",
                  note.userInfo?["cause"] as? String == ProfileManager.OwnerClaimCause.activate.rawValue,
                  let newOwnerId = note.object as? UUID else { return }
            let previousOwnerId = (note.userInfo?["previousOwnerId"] as? String).flatMap(UUID.init(uuidString:))
            MainActor.assumeIsolated { self?.handleCodexSwitch(newOwnerId: newOwnerId, previousOwnerId: previousOwnerId) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    // MARK: Detection

    /// One `ps` scan, off the main actor. Hosts are aged against the newest
    /// terminal rollout write the last scan saw.
    func currentStatus() async -> CodexDaemon.Status {
        let active = CodexDaemon.terminalsActive(newestTerminalWrite: lastTerminalWriteAt, now: Date())
        let status = await Self.offMain { Self.scanStatus(terminalsActive: active) }
        lastStatus = status
        return status
    }

    nonisolated static func scanStatus(terminalsActive: Bool = true) -> CodexDaemon.Status {
        let home = CodexUsageService.defaultCodexHome
        return CodexDaemon.status(
            processes: listProcesses(),
            codexHome: home,
            controlSocketPresent: FileManager.default.fileExists(atPath: controlSocketPath(codexHome: home)),
            terminalsActive: terminalsActive
        )
    }

    nonisolated static func controlSocketPath(codexHome: URL) -> String {
        codexHome.appendingPathComponent(CodexDaemon.controlSocketRelativePath).path
    }

    /// `/bin/ps -axo pid=,ppid=,etime=,command=` — the same subprocess
    /// pattern the Keychain and login services use; never called on the main
    /// actor.
    nonisolated static func listProcesses() -> [ProcessRecord] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,etime=,command="]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        return CodexDaemon.parseProcessList(text)
    }

    // MARK: Restart

    enum RestartOutcome: Equatable {
        case notRunning
        /// The daemon exited after SIGTERM — or, `forced`, after the one
        /// SIGKILL escalation.
        case restarted(pid: Int32, forced: Bool)
        /// Still running after SIGTERM and SIGKILL. Logged as an error; the
        /// hold stays so the dashboard keeps saying so.
        case survived(pid: Int32)
        case signalFailed(pid: Int32, errno: Int32)

        var succeeded: Bool {
            if case .restarted = self { return true }
            return false
        }
    }

    /// How long the daemon gets to exit after SIGTERM before SIGKILL, and
    /// after SIGKILL before the restart is reported as failed.
    static let exitTimeout: TimeInterval = 10
    static let killTimeout: TimeInterval = 3

    /// SIGTERM to the ONE path-anchored daemon process — re-scanned immediately
    /// before the signal so a recycled pid can never be hit — then VERIFIED:
    /// the wait (off the main actor) ends when the process is gone or
    /// `exitTimeout` passes; a survivor is re-scanned (still the daemon, same
    /// pid) and sent SIGKILL once. Every outcome is logged; a half-state is
    /// never silent. The daemon respawns on the next `codex` launch with the
    /// current auth.json.
    @discardableResult
    func restartDaemon(reason: String, nextOwnerName: String? = nil) async -> RestartOutcome {
        let status = await currentStatus()
        guard let daemon = status.daemon else {
            LoggingService.shared.log("CodexDaemon: restart requested (\(reason)) but no daemon is running — nothing to do")
            return .notRunning
        }
        let pid = daemon.pid
        let next = nextOwnerName ?? currentCodexOwnerName() ?? "the current auth.json"
        let sessions = CodexDaemon.describe(status.sessions)
        if kill(pid, SIGTERM) != 0 {
            let code = errno
            LoggingService.shared.logError("CodexDaemon: SIGTERM to pid \(pid) failed (errno \(code)) — \(reason)")
            return .signalFailed(pid: pid, errno: code)
        }
        LoggingService.shared.log("CodexDaemon: sent SIGTERM to the Codex daemon (pid \(pid)) — \(reason); attached: \(sessions)")

        let socket = Self.controlSocketPath(codexHome: CodexUsageService.defaultCodexHome)
        var wait = await Self.offMain { Self.waitForExit(pid: pid, socketPath: socket, timeout: Self.exitTimeout) }
        var forced = false
        if !wait.exited {
            // Only the daemon at that pid, confirmed path-anchored again.
            let again = await Self.offMain { Self.scanStatus() }
            guard let survivor = again.daemon, survivor.pid == pid else {
                LoggingService.shared.log("CodexDaemon: pid \(pid) is no longer the daemon after \(Self.exitTimeout) s — treating the restart as done")
                wait.exited = true
                return finishRestart(pid: pid, forced: false, wait: wait, next: next)
            }
            LoggingService.shared.logError("CodexDaemon: pid \(pid) survived SIGTERM for \(Int(Self.exitTimeout)) s — sending SIGKILL")
            if kill(pid, SIGKILL) != 0 {
                let code = errno
                LoggingService.shared.logError("CodexDaemon: SIGKILL to pid \(pid) failed (errno \(code)) — the daemon still holds the previous login")
                return .signalFailed(pid: pid, errno: code)
            }
            forced = true
            wait = await Self.offMain { Self.waitForExit(pid: pid, socketPath: socket, timeout: Self.killTimeout) }
        }
        guard wait.exited else {
            LoggingService.shared.logError("CodexDaemon: pid \(pid) survived SIGTERM and SIGKILL — the daemon still holds the previous login; kill -9 \(pid) by hand")
            return .survived(pid: pid)
        }
        return finishRestart(pid: pid, forced: forced, wait: wait, next: next)
    }

    private func finishRestart(pid: Int32, forced: Bool, wait: ExitWait, next: String) -> RestartOutcome {
        let socket = wait.socketGone ? "control socket gone" : "control socket still present"
        LoggingService.shared.log("CodexDaemon: restarted (pid \(pid) → gone\(forced ? " after SIGKILL" : "") in \(String(format: "%.1f", wait.waited)) s, \(socket)); next codex launch loads '\(next)'")
        lastStatus = CodexDaemon.Status(daemon: nil, sessions: [], controlSocketPresent: !wait.socketGone)
        clearHold(because: "the daemon was restarted")
        return .restarted(pid: pid, forced: forced)
    }

    nonisolated struct ExitWait: Equatable {
        var exited: Bool
        var socketGone: Bool
        var waited: TimeInterval
    }

    /// Polls `kill(pid, 0)` every 200 ms until the process is gone or the
    /// timeout passes; the control socket's absence is reported beside it
    /// (the daemon removes it on a clean exit). Blocking — off the main actor.
    nonisolated static func waitForExit(pid: Int32, socketPath: String, timeout: TimeInterval) -> ExitWait {
        let start = Date()
        while true {
            let alive = kill(pid, 0) == 0 || errno == EPERM
            let socketGone = !FileManager.default.fileExists(atPath: socketPath)
            let waited = Date().timeIntervalSince(start)
            if !alive { return ExitWait(exited: true, socketGone: socketGone, waited: waited) }
            if waited >= timeout { return ExitWait(exited: false, socketGone: socketGone, waited: waited) }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func currentCodexOwnerName() -> String? {
        let manager = ProfileManager.shared
        guard let id = manager.activeCodexProfileId else { return nil }
        return manager.profiles.first(where: { $0.id == id })?.name
    }

    // MARK: After a Codex switch

    private func handleCodexSwitch(newOwnerId: UUID, previousOwnerId: UUID?) {
        Task { @MainActor in
            let profiles = ProfileManager.shared.profiles
            let name = profiles.first(where: { $0.id == newOwnerId })?.name ?? "the new account"
            let previous = previousOwnerId.flatMap { id in profiles.first(where: { $0.id == id }) }
            // The staleness rule reads the newest terminal rollout write. The
            // sweep keeps it fresh; a switch right after launch must not read
            // "no activity" and file every host as stale.
            if lastRolloutScanAt == nil { await scanRolloutsNow() }
            let status = await currentStatus()
            // A new switch supersedes an older hold: the daemon now holds a
            // different previous login, or none.
            reminderTask?.cancel()
            hold = nil
            guard let daemon = status.daemon else {
                LoggingService.shared.log("CodexDaemon: no daemon running after the switch to '\(name)' — terminals pick up the new login on the next codex launch")
                return
            }
            let store = SharedDataStore.shared
            let exhausted = previous.map { outgoing in
                CodexDaemonRestartPolicy.outgoingLoginIsExhausted(
                    usage: outgoing.claudeUsage,
                    loginMarkedDead: CodexUsageService.shared.isLoginMarkedDead(outgoing.id),
                    sessionThreshold: store.loadAutoSwitchThreshold(),
                    weeklyThreshold: store.loadAutoSwitchWeeklyThreshold()
                )
            } ?? false
            let verdict = CodexDaemonRestartPolicy.verdict(
                restartOnSwitch: store.loadCodexDaemonRestartOnSwitch(),
                outgoingLoginExhausted: exhausted,
                liveSessions: status.attachedSessions
            )
            let previousName = previous?.name ?? "the previous owner"
            let attached = CodexDaemon.describe(status.sessions)

            if verdict.restarts {
                let why = verdict == .restartExhaustedLogin
                    ? "'\(previousName)' is exhausted — every attached session is already broken on it"
                    : "no live session is attached"
                LoggingService.shared.log("CodexDaemon: restarting the Codex daemon (pid \(daemon.pid)) after the switch to '\(name)' — \(why); attached: \(attached)")
                if await restartDaemon(reason: "switched to '\(name)'", nextOwnerName: name).succeeded {
                    NotificationManager.shared.sendCodexDaemonRestartedNotification(profileName: name)
                    return
                }
            }

            let why: String
            switch verdict {
            case .holdToggleOff: why = "restart-on-switch is off"
            case .holdLiveSessions(let count): why = "\(count) live session(s) still use it and it still works"
            case .restartExhaustedLogin, .restartIdle: why = "the restart failed"
            }
            LoggingService.shared.log("CodexDaemon: the Codex daemon (pid \(daemon.pid)) still holds the previous login ('\(previousName)') after the switch to '\(name)' — \(why); attached: \(attached); interactive codex sessions keep it until the daemon restarts")
            hold = Hold(daemonPid: daemon.pid, previousOwnerName: previous?.name, newOwnerName: name, since: Date())
            NotificationManager.shared.sendCodexDaemonHoldsPreviousLoginNotification(
                profileName: name, previousOwnerName: previous?.name, attachedSessions: status.attachedSessions
            )
            scheduleReminder()
        }
    }

    /// Ten minutes after a hold, if the SAME daemon still runs, the user is
    /// told once more — with the Restart action.
    private func scheduleReminder() {
        reminderTask?.cancel()
        reminderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.reminderDelay * 1_000_000_000))
            guard !Task.isCancelled, let self, var hold = self.hold, !hold.reminded else { return }
            let status = await self.currentStatus()
            guard let daemon = status.daemon, daemon.pid == hold.daemonPid else {
                self.clearHold(because: "pid \(hold.daemonPid) is gone")
                return
            }
            hold.reminded = true
            self.hold = hold
            LoggingService.shared.log("CodexDaemon: the Codex daemon (pid \(daemon.pid)) still holds '\(hold.previousOwnerName ?? "the previous login")' \(Int(Self.reminderDelay / 60)) min after the switch to '\(hold.newOwnerName)' — reminding; attached: \(CodexDaemon.describe(status.sessions))")
            NotificationManager.shared.sendCodexDaemonHoldsPreviousLoginNotification(
                profileName: hold.newOwnerName, previousOwnerName: hold.previousOwnerName,
                attachedSessions: status.attachedSessions, reminder: true
            )
        }
    }

    /// Every sweep while a hold stands: one `ps` scan, and the hold clears
    /// when the daemon it names is gone (restarted by anyone — the action
    /// button, Settings, a terminal, or its own exit).
    private func resolveHoldIfDaemonGone() async {
        guard let hold else { return }
        let status = await currentStatus()
        if let daemon = status.daemon, daemon.pid == hold.daemonPid { return }
        let successor = status.daemon.map { "a new daemon (pid \($0.pid)) serves '\(hold.newOwnerName)'" }
            ?? "the next codex launch loads '\(hold.newOwnerName)'"
        clearHold(because: "pid \(hold.daemonPid) is gone; \(successor)")
    }

    private func clearHold(because reason: String) {
        reminderTask?.cancel()
        reminderTask = nil
        guard hold != nil else { return }
        LoggingService.shared.log("CodexDaemon: hold resolved — \(reason)")
        hold = nil
    }

    // MARK: Terminals line

    /// How often the rollout tree is re-scanned. The sweep calls
    /// `refreshTerminalsState` every ~30 s; a stamp that is two minutes old
    /// tells the terminals line nothing different, and every scan between
    /// costs only stats once the cache is warm anyway — but a scan is still
    /// 30 stats and a directory walk, and the line is informational.
    static let rolloutScanInterval: TimeInterval = 120

    /// The evidence the last scan produced. It is re-matched against the
    /// CURRENT profiles on every refresh (their cached resets move with every
    /// usage fetch) without touching the disk.
    private(set) var lastEvidence: CodexTerminals.Evidence?
    /// When the newest daemon-written rollout was last modified — the last
    /// time any terminal session wrote. Ages the attached sessions.
    private(set) var lastTerminalWriteAt: Date?
    private(set) var lastRolloutScanAt: Date?
    private var loggedColdScan = false

    /// Re-derives the terminals line from the newest daemon-written rollout.
    /// The rollout tree is scanned at most every `rolloutScanInterval`
    /// (`force` scans now); file reads run off the main actor and only the
    /// head and tail of each file are ever read. The result is cached for the
    /// dashboard and the inspector. While a hold stands, the daemon is also
    /// re-checked so the hold clears the sweep after it is restarted.
    func refreshTerminalsState(profiles: [Profile], force: Bool = false) async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let scanDue = force || lastRolloutScanAt.map { Date().timeIntervalSince($0) >= Self.rolloutScanInterval } ?? true
        if scanDue { await scanRolloutsNow() }
        let line = CodexTerminals.line(from: lastEvidence, profiles: profiles)
        if line != terminals {
            LoggingService.shared.log("CodexDaemon: \(CodexTerminals.format(line))")
        }
        terminals = line
        await resolveHoldIfDaemonGone()
    }

    private func scanRolloutsNow() async {
        let root = CodexUsageService.defaultCodexHome.appendingPathComponent("sessions")
        let cache = RolloutScanCache.shared
        let scan = await Self.offMain { CodexTerminals.scanRollouts(sessionsRoot: root, cache: cache) }
        lastEvidence = scan.evidence
        lastTerminalWriteAt = scan.newestTerminalWrite
        lastRolloutScanAt = Date()
        let summary = "CodexDaemon: rollout scan read \(cache.lastScanBytesRead / 1024) KB from \(cache.lastScanFilesOpened) file(s), \(cache.count) cached"
        if loggedColdScan {
            LoggingService.shared.logDebug(summary)
        } else {
            loggedColdScan = true
            LoggingService.shared.log(summary + " (cold scan)")
        }
    }

    private static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}
