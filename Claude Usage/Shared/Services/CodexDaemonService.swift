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
//  Three things live here, the pure parts as enums so the tests need no
//  process, socket or file:
//
//  1. `CodexDaemon` — a PATH-ANCHORED process match (never the bare name
//     `codex`, which would hit the user's TUIs, the desktop app's embedded
//     codex and every `codex exec`), plus the attached-session count (children
//     named `codex-code-mode-host`).
//  2. `CodexTerminals` — which account the daemon is serving, derived ONLY from
//     the newest daemon-written rollout's `rate_limits.primary.resets_at`
//     matched to the profiles' cached reset stamps. Nothing is inferred beyond
//     the stamp: no match, or two matches, reads "unknown account".
//  3. `CodexDaemonService` — after every Codex activation (observed through
//     `.providerOwnerClaimed`, so no activation seam is edited) it either
//     restarts the daemon (opt-in setting, zero attached sessions) or tells the
//     user that terminals keep the previous login, with a Restart action.
//

import Foundation

// MARK: - Process records

/// One row of `ps -axo pid=,ppid=,command=`.
nonisolated struct ProcessRecord: Equatable {
    var pid: Int32
    var ppid: Int32
    /// The command as `ps` prints it: the executable path, then the arguments.
    var command: String

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

    struct Status: Equatable {
        var daemon: ProcessRecord?
        var attachedSessions: Int
        var controlSocketPresent: Bool
        var isRunning: Bool { daemon != nil }
    }

    /// Parses `ps -axo pid=,ppid=,command=`: two right-aligned integer
    /// columns, then the command to the end of the line.
    nonisolated static func parseProcessList(_ output: String) -> [ProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine -> ProcessRecord? in
            let line = String(rawLine)
            let scanner = Scanner(string: line)
            scanner.charactersToBeSkipped = .whitespaces
            guard let pid = scanner.scanInt32(), let ppid = scanner.scanInt32() else { return nil }
            let rest = String(line[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            return ProcessRecord(pid: pid, ppid: ppid, command: rest)
        }
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
    /// `codex-code-mode-host`. The same host under a `codex exec` process is a
    /// headless run, not a terminal, and is not counted.
    nonisolated static func attachedSessionCount(daemonPid: Int32, in processes: [ProcessRecord]) -> Int {
        processes.filter { $0.ppid == daemonPid && $0.executableName == sessionHostExecutable }.count
    }

    nonisolated static func status(processes: [ProcessRecord], codexHome: URL, controlSocketPresent: Bool) -> Status {
        let daemon = daemon(in: processes, codexHome: codexHome)
        return Status(
            daemon: daemon,
            attachedSessions: daemon.map { attachedSessionCount(daemonPid: $0.pid, in: processes) } ?? 0,
            controlSocketPresent: controlSocketPresent
        )
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
        let files = recentRolloutFiles(sessionsRoot: sessionsRoot, fileManager: fileManager, limit: maxFiles)
        cache.beginScan(retaining: Set(files.map(\.url.path)))
        for file in files {
            guard let entry = examine(file, cache: cache),
                  entry.originator == daemonOriginator, let stamp = entry.stamp else { continue }
            return Evidence(
                resetsAt: stamp.resetsAt, windowMinutes: stamp.windowMinutes,
                sessionStartedAt: entry.sessionStart ?? file.modified
            )
        }
        return nil
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

    private init() {}

    /// Observes Codex activations. `.providerOwnerClaimed` with
    /// `provider == codex` and `cause == activate` is posted by every
    /// activation path — ⇄ menu, dashboard, inspector, auto-switch — exactly
    /// once per real handover, so no activation seam has to know about this.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .providerOwnerClaimed, object: nil, queue: .main
        ) { [weak self] note in
            guard note.userInfo?["provider"] as? String == "codex",
                  note.userInfo?["cause"] as? String == ProfileManager.OwnerClaimCause.activate.rawValue,
                  let newOwnerId = note.object as? UUID else { return }
            MainActor.assumeIsolated { self?.handleCodexSwitch(newOwnerId: newOwnerId) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    // MARK: Detection

    /// One `ps` scan, off the main actor.
    func currentStatus() async -> CodexDaemon.Status {
        let status = await Self.offMain { Self.scanStatus() }
        lastStatus = status
        return status
    }

    nonisolated static func scanStatus() -> CodexDaemon.Status {
        let home = CodexUsageService.defaultCodexHome
        let socket = home.appendingPathComponent(CodexDaemon.controlSocketRelativePath).path
        return CodexDaemon.status(
            processes: listProcesses(),
            codexHome: home,
            controlSocketPresent: FileManager.default.fileExists(atPath: socket)
        )
    }

    /// `/bin/ps -axo pid=,ppid=,command=` — the same subprocess pattern the
    /// Keychain and login services use; never called on the main actor.
    nonisolated static func listProcesses() -> [ProcessRecord] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
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

    /// SIGTERM to the ONE path-anchored daemon process — re-scanned immediately
    /// before the signal so a recycled pid can never be hit. The daemon
    /// respawns on the next `codex` launch with the current auth.json. Returns
    /// false when no daemon is running or the signal was refused.
    @discardableResult
    func restartDaemon(reason: String) async -> Bool {
        let status = await currentStatus()
        guard let daemon = status.daemon else {
            LoggingService.shared.log("CodexDaemon: restart requested (\(reason)) but no daemon is running — nothing to do")
            return false
        }
        let result = kill(daemon.pid, SIGTERM)
        if result == 0 {
            LoggingService.shared.log("CodexDaemon: sent SIGTERM to the Codex daemon (pid \(daemon.pid), \(status.attachedSessions) attached session(s)) — \(reason); it respawns on the next codex launch")
            lastStatus = CodexDaemon.Status(daemon: nil, attachedSessions: 0, controlSocketPresent: false)
        } else {
            LoggingService.shared.logError("CodexDaemon: SIGTERM to pid \(daemon.pid) failed (errno \(errno)) — \(reason)")
        }
        return result == 0
    }

    // MARK: After a Codex switch

    private func handleCodexSwitch(newOwnerId: UUID) {
        Task { @MainActor in
            let status = await currentStatus()
            let name = ProfileManager.shared.profiles.first(where: { $0.id == newOwnerId })?.name ?? "the new account"
            guard let daemon = status.daemon else {
                LoggingService.shared.log("CodexDaemon: no daemon running after the switch to '\(name)' — terminals pick up the new login on the next codex launch")
                return
            }
            if SharedDataStore.shared.loadCodexDaemonRestartOnSwitch(), status.attachedSessions == 0 {
                if await restartDaemon(reason: "restart-on-switch is on and no session is attached; switched to '\(name)'") {
                    NotificationManager.shared.sendCodexDaemonRestartedNotification(profileName: name)
                    return
                }
            }
            LoggingService.shared.log("CodexDaemon: the Codex daemon (pid \(daemon.pid)) still holds the previous login after the switch to '\(name)' — \(status.attachedSessions) attached session(s); interactive codex sessions keep it until the daemon restarts")
            NotificationManager.shared.sendCodexDaemonHoldsPreviousLoginNotification(
                profileName: name, attachedSessions: status.attachedSessions
            )
        }
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
    private(set) var lastRolloutScanAt: Date?
    private var loggedColdScan = false

    /// Re-derives the terminals line from the newest daemon-written rollout.
    /// The rollout tree is scanned at most every `rolloutScanInterval`
    /// (`force` scans now); file reads run off the main actor and only the
    /// head and tail of each file are ever read. The result is cached for the
    /// dashboard and the inspector.
    func refreshTerminalsState(profiles: [Profile], force: Bool = false) async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let scanDue = force || lastRolloutScanAt.map { Date().timeIntervalSince($0) >= Self.rolloutScanInterval } ?? true
        if scanDue {
            let root = CodexUsageService.defaultCodexHome.appendingPathComponent("sessions")
            let cache = RolloutScanCache.shared
            lastEvidence = await Self.offMain { CodexTerminals.newestDaemonEvidence(sessionsRoot: root, cache: cache) }
            lastRolloutScanAt = Date()
            let summary = "CodexDaemon: rollout scan read \(cache.lastScanBytesRead / 1024) KB from \(cache.lastScanFilesOpened) file(s), \(cache.count) cached"
            if loggedColdScan {
                LoggingService.shared.logDebug(summary)
            } else {
                loggedColdScan = true
                LoggingService.shared.log(summary + " (cold scan)")
            }
        }
        let line = CodexTerminals.line(from: lastEvidence, profiles: profiles)
        if line != terminals {
            LoggingService.shared.log("CodexDaemon: \(CodexTerminals.format(line))")
        }
        terminals = line
    }

    private static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}
