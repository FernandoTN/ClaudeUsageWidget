//
//  TelemetryIndexer.swift
//  Claude Usage
//
//  Walks the three providers' local logs in bounded slices and feeds the
//  ledger (spec §2.3). Incremental by per-file cursor (inode + byte offset),
//  bounded per slice by files, bytes and wall time, and idempotent by the
//  ledger's unit key — so a shrink, a move into `archived_sessions`, or a
//  crash mid-slice replays safely. Nothing here touches the main actor: the
//  roots are injected, the class is `nonisolated`, and it runs on
//  TelemetryService's serial utility queue.
//

import Foundation
import os

/// Where the logs are. Built once from the app's own path seams (which honour
/// `CLAUDE_CONFIG_DIR` and `CODEX_HOME`); tests inject temporary directories.
nonisolated struct TelemetrySourceRoots: Sendable {
    var claudeProjects: [URL]
    /// Codex homes: each contributes `sessions/` and `archived_sessions/`.
    var codexHomes: [URL]
    var grokSessions: [URL]
    /// The default Codex home (`$CODEX_HOME` or `~/.codex`); every other home
    /// is isolated and its rollouts carry "<home>/<originator>" as source.
    /// nil = the first of `codexHomes`.
    var defaultCodexHome: URL? = nil

    func isIsolatedCodexHome(_ home: URL) -> Bool {
        guard let defaultHome = defaultCodexHome ?? codexHomes.first else { return false }
        return home.standardizedFileURL.path != defaultHome.standardizedFileURL.path
    }

    static func live() -> TelemetrySourceRoots {
        let fm = FileManager.default
        var homes = [CodexUsageService.defaultCodexHome]
        if let isolated = try? fm.contentsOfDirectory(at: CodexUsageService.isolatedHomesRoot,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) {
            homes += isolated.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return TelemetrySourceRoots(
            claudeProjects: [Constants.ClaudePaths.projectsDirectory],
            codexHomes: homes,
            grokSessions: [Constants.ClaudePaths.homeDirectory.appendingPathComponent(".grok/sessions")],
            defaultCodexHome: CodexUsageService.defaultCodexHome)
    }
}

nonisolated struct IndexerBounds: Sendable {
    var maxFiles = 200
    /// 32 MB: the first deploy's 64 MB slices peaked the process at 450 MB RSS
    /// during catch-up (framed lines + parsed objects + SQLite cache); half the
    /// budget halves the working set at ~the same throughput.
    var maxBytes = 32 << 20
    var maxSeconds: TimeInterval = 2.0
}

nonisolated struct IndexerPassReport: Sendable, Equatable {
    var filesScanned = 0
    var bytesRead: Int64 = 0
    var eventsUpserted = 0
    var markersInserted = 0
    var backlogFiles = 0
    var backlogBytes: Int64 = 0
    var unreadableFiles = 0
    var hitBound = false
    var duration: TimeInterval = 0
}

nonisolated final class TelemetryIndexer: @unchecked Sendable {

    private struct Candidate {
        let provider: TelemetryProvider
        let fileId: String
        let url: URL
        let inode: UInt64
        let size: Int64
        let mtime: Date
        let cursor: TelemetryCursor?
        /// Grok: the session's decoded working directory.
        let source: String?
        /// Codex: the slug of an isolated home, prefixed onto every event's
        /// source ("xfenrir-dev/exec"); nil for the default home.
        var isolatedCodexHome: String? = nil
        /// Stage 4d one-time re-index: this file's rows were written under the
        /// old source rule — delete them and re-derive from offset 0 in one
        /// transaction. Never set on a resumed candidate.
        var replace = false
        var unreadBytes: Int64 { max(0, size - (cursor?.offset ?? 0)) }

        func resuming(from cursor: TelemetryCursor) -> Candidate {
            Candidate(provider: provider, fileId: fileId, url: url, inode: inode, size: size, mtime: mtime,
                      cursor: cursor, source: source, isolatedCodexHome: isolatedCodexHome, replace: false)
        }
    }

    private struct FileOutcome {
        var bytes: Int64
        var events: Int
        var markers: Int
        var finished: Bool
        var dataThrough: Date?
        var cursor: TelemetryCursor
    }

    private struct ProviderTally {
        var filesSeen = 0, unreadable = 0, malformed = 0, unknown = 0
        var dataThrough: Date?
    }

    private let ledger: TelemetryLedger
    private let roots: TelemetrySourceRoots
    private let bounds: IndexerBounds
    /// Candidates left over from the last enumeration during catch-up, so a
    /// slice does not re-walk 12,000 files it already knows are pending.
    private var pendingCandidates: [Candidate] = []

    init(ledger: TelemetryLedger, roots: TelemetrySourceRoots, bounds: IndexerBounds = IndexerBounds()) {
        self.ledger = ledger
        self.roots = roots
        self.bounds = bounds
    }

    /// One bounded slice. Returns what it did and whether a bound stopped it
    /// (the caller schedules the next slice promptly while it did).
    func runSlice(now: Date = Date()) -> IndexerPassReport {
        let start = Date()
        var report = IndexerPassReport()
        var tallies: [TelemetryProvider: ProviderTally] = [:]

        if pendingCandidates.isEmpty {
            pendingCandidates = enumerateCandidates(tallies: &tallies)
        }
        var bytesBudget = Int64(bounds.maxBytes)

        while !pendingCandidates.isEmpty {
            if report.filesScanned >= bounds.maxFiles || bytesBudget <= 0
                || Date().timeIntervalSince(start) >= bounds.maxSeconds {
                report.hitBound = true
                break
            }
            let candidate = pendingCandidates.removeFirst()
            report.filesScanned += 1
            var tally = tallies[candidate.provider] ?? ProviderTally()
            do {
                // Per-file pool: the framed lines and parsed objects die here.
                let outcome = try autoreleasepool { try index(candidate, byteBudget: bytesBudget, tally: &tally) }
                bytesBudget -= outcome.bytes
                report.bytesRead += outcome.bytes
                report.eventsUpserted += outcome.events
                report.markersInserted += outcome.markers
                if let through = outcome.dataThrough, tally.dataThrough.map({ through > $0 }) ?? true { tally.dataThrough = through }
                if !outcome.finished {
                    // Re-queue with the ADVANCED cursor so the next slice resumes
                    // where this one stopped instead of re-reading the same bytes.
                    pendingCandidates.insert(candidate.resuming(from: outcome.cursor), at: 0)
                    report.hitBound = true
                }
            } catch {
                // Cursor untouched: the bytes are retried next slice, and the
                // failure is counted rather than rendered as zero consumption.
                tally.unreadable += 1
                report.unreadableFiles += 1
                telemetryLog.error("index failed for \(candidate.fileId, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            tallies[candidate.provider] = tally
            if !pendingCandidates.isEmpty, pendingCandidates[0].fileId == candidate.fileId { break }
        }

        report.backlogFiles = pendingCandidates.count
        report.backlogBytes = pendingCandidates.reduce(0) { $0 + $1.unreadBytes }
        report.duration = Date().timeIntervalSince(start)
        recordHealth(tallies: tallies, report: report, now: now)
        return report
    }

    // MARK: - Enumeration

    private func enumerateCandidates(tallies: inout [TelemetryProvider: ProviderTally]) -> [Candidate] {
        reindexPending = 0
        let cursors = Dictionary(uniqueKeysWithValues: ((try? ledger.allCursors()) ?? []).map { ($0.fileId, $0) })
        var candidates: [Candidate] = []
        var seenFileIds = Set<String>()
        func consider(_ provider: TelemetryProvider, fileId: String, url: URL, source: String?, tally: inout ProviderTally,
                      isolatedCodexHome: String? = nil) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  let mtime = attributes[.modificationDate] as? Date else { return }
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            tally.filesSeen += 1
            seenFileIds.insert(fileId)
            let cursor = cursors[fileId]
            // mtime tolerance: the Date → REAL → Date round trip can drift by an ulp.
            let changed = cursor == nil || cursor!.inode != inode || size != cursor!.offset
                || mtime.timeIntervalSince(cursor!.mtime) > 0.001
            // Stage 4d: an isolated home's rollout indexed under the old source
            // rule is re-derived once, whether or not the file changed.
            let replace = isolatedCodexHome != nil && cursor != nil
                && Self.codexSourceVersion(of: cursor!) < CodexRolloutReader.sourceVersion
            if replace { reindexPending += 1 }
            guard changed || replace else { return }
            candidates.append(Candidate(provider: provider, fileId: fileId, url: url, inode: inode, size: size,
                                        mtime: mtime, cursor: replace ? nil : cursor, source: source,
                                        isolatedCodexHome: isolatedCodexHome, replace: replace))
        }

        var claude = tallies[.claude] ?? ProviderTally()
        for root in roots.claudeProjects {
            // Resolve both sides: the enumerator hands back /private/var/… for a
            // /var/… root, and the relative path is the file's identity.
            let rootPath = root.resolvingSymlinksInPath().path
            walk(root, prune: ["tool-results"]) { url in
                guard url.pathExtension == "jsonl" else { return }
                let resolved = url.resolvingSymlinksInPath().path
                let relative = resolved.hasPrefix(rootPath)
                    ? String(resolved.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    : url.lastPathComponent
                consider(.claude, fileId: "claude:" + relative, url: url, source: nil, tally: &claude)
            }
        }
        tallies[.claude] = claude

        var codex = tallies[.codex] ?? ProviderTally()
        for home in roots.codexHomes {
            for sub in ["sessions", "archived_sessions"] {
                walk(home.appendingPathComponent(sub), prune: []) { url in
                    guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { return }
                    // The basename carries the rollout uuid; a move into
                    // archived_sessions is the same file, not a new one.
                    consider(.codex, fileId: "codex:" + url.lastPathComponent, url: url,
                             source: home.lastPathComponent, tally: &codex,
                             isolatedCodexHome: roots.isIsolatedCodexHome(home) ? home.lastPathComponent : nil)
                }
            }
        }
        tallies[.codex] = codex

        var grok = tallies[.grok] ?? ProviderTally()
        for root in roots.grokSessions {
            walk(root, prune: []) { url in
                guard url.lastPathComponent == "updates.jsonl" else { return }
                let sessionDir = url.deletingLastPathComponent()
                let cwd = sessionDir.deletingLastPathComponent().lastPathComponent.removingPercentEncoding
                consider(.grok, fileId: "grok:" + sessionDir.lastPathComponent, url: url,
                         source: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, tally: &grok)
            }
        }
        tallies[.grok] = grok

        // Vanished files lose only their cursor — never their events.
        for (fileId, _) in cursors where !seenFileIds.contains(fileId) {
            try? ledger.deleteCursor(fileId: fileId)
        }
        // Newest first: recent activity shows up in the window before the backlog.
        return candidates.sorted { $0.mtime > $1.mtime }
    }

    private func walk(_ root: URL, prune: Set<String>, visit: (URL) -> Void) {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if prune.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            visit(url)
        }
    }

    // MARK: - One file

    private func index(_ candidate: Candidate, byteBudget: Int64, tally: inout ProviderTally) throws -> FileOutcome {
        var offset = candidate.cursor?.offset ?? 0
        var state = candidate.cursor?.state
        if let cursor = candidate.cursor, cursor.inode != candidate.inode || candidate.size < cursor.offset
            || (candidate.size == cursor.offset && candidate.mtime.timeIntervalSince(cursor.mtime) > 0.001) {
            // Replaced, truncated or rewritten in place: start over. The unit
            // key makes the replay idempotent.
            offset = 0
            state = nil
        }
        let needles: [[UInt8]]
        switch candidate.provider {
        case .claude: needles = ClaudeTranscriptReader.needles
        case .codex: needles = CodexRolloutReader.needles
        case .grok: needles = GrokUpdatesReader.needles
        }
        var framed = try JSONLFraming.readLines(url: candidate.url, from: offset, limit: candidate.size,
                                                maxBytes: Int(min(byteBudget, Int64(bounds.maxBytes))), needles: needles)
        if framed.hitByteBound && framed.nextOffset == offset {
            // A single line longer than the budget: it can only be consumed
            // whole, so read to the end of the snapshot rather than stall here
            // forever (the budget is a pacing hint, not a correctness bound).
            framed = try JSONLFraming.readLines(url: candidate.url, from: offset, limit: candidate.size,
                                                maxBytes: Int(candidate.size - offset), needles: needles)
        }
        var events: [TelemetryEvent] = []
        var markers: [TelemetryMarker] = []
        var newState: Data?
        var dataThrough: Date?
        var reassignModel: String?
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        switch candidate.provider {
        case .claude:
            let previous = state.flatMap { try? decoder.decode(ClaudeTranscriptReader.State.self, from: $0) } ?? .init()
            let out = ClaudeTranscriptReader.parse(lines: framed.lines, fileId: candidate.fileId, state: previous)
            events = out.events; markers = out.markers; dataThrough = out.dataThrough
            tally.malformed += out.malformed; tally.unknown += out.unknownShapes
            newState = try encoder.encode(out.state)
        case .codex:
            let previous = state.flatMap { try? decoder.decode(CodexRolloutReader.State.self, from: $0) } ?? .init()
            var out = CodexRolloutReader.parse(lines: framed.lines, fileId: candidate.fileId, state: previous)
            if let home = candidate.isolatedCodexHome {
                // "<home>/<originator>": the home is what attributes by path; the
                // originator stays readable after the slash (stage 4d).
                for index in out.events.indices { out.events[index].source = "\(home)/\(out.events[index].source ?? "unknown")" }
            }
            out.state.sourceVersion = CodexRolloutReader.sourceVersion
            events = out.events; dataThrough = out.dataThrough; reassignModel = out.firstModel
            tally.malformed += out.malformed; tally.unknown += out.unknownShapes
            newState = try encoder.encode(out.state)
        case .grok:
            let out = GrokUpdatesReader.parse(lines: framed.lines, fileId: candidate.fileId, source: candidate.source)
            events = out.events; dataThrough = out.dataThrough
            tally.malformed += out.malformed; tally.unknown += out.unknownShapes
        }
        // Events, markers and the cursor advance commit together, or not at all.
        let cursor = TelemetryCursor(fileId: candidate.fileId, path: candidate.url.path, inode: candidate.inode,
                                     size: candidate.size, mtime: candidate.mtime, offset: framed.nextOffset, state: newState)
        try ledger.transaction {
            // Replace, never append: the old rows go in the same transaction
            // that writes the re-derived ones and the cursor that marks the
            // file done, so a crash leaves either the old file or the new.
            if candidate.replace { try ledger.deleteEvents(fileId: candidate.fileId) }
            if let reassignModel { try ledger.reassignUnknownModel(fileId: candidate.fileId, to: reassignModel) }
            try ledger.upsert(events)
            try ledger.insert(markers)
            try ledger.save(cursor)
        }
        if candidate.replace { reindexPending = max(0, reindexPending - 1) }
        // Done with this file for now when the snapshot is consumed, or when
        // only a trailing fragment (no newline yet) remains.
        let finished = !framed.hitByteBound
        return FileOutcome(bytes: framed.bytesRead, events: events.count, markers: markers.count,
                           finished: finished, dataThrough: dataThrough, cursor: cursor)
    }

    /// Files still to re-derive under the current Codex source rule, counted
    /// at scan time and decremented as each completes; published through meta
    /// so the window's notes can say "N files to go".
    static let codexReindexPendingKey = "codexReindexPending_v1"
    private var reindexPending = 0

    private static func codexSourceVersion(of cursor: TelemetryCursor) -> Int {
        guard let data = cursor.state,
              let state = try? JSONDecoder().decode(CodexRolloutReader.State.self, from: data) else { return 0 }
        return state.sourceVersion ?? 0
    }

    private func recordHealth(tallies: [TelemetryProvider: ProviderTally], report: IndexerPassReport, now: Date) {
        try? ledger.setMeta(Self.codexReindexPendingKey, String(reindexPending))
        for (provider, tally) in tallies {
            guard var health = try? ledger.health(provider: provider) else { continue }
            health.scannedAt = now
            if let through = tally.dataThrough, health.dataThrough.map({ through > $0 }) ?? true { health.dataThrough = through }
            if tally.filesSeen > 0 { health.filesSeen = tally.filesSeen }
            health.filesUnreadable += tally.unreadable
            health.linesMalformed += tally.malformed
            health.unknownShapes += tally.unknown
            health.backlogFiles = pendingCandidates.filter { $0.provider == provider }.count
            health.backlogBytes = pendingCandidates.filter { $0.provider == provider }.reduce(0) { $0 + $1.unreadBytes }
            try? ledger.save(health)
        }
    }
}
