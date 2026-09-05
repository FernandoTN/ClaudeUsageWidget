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
struct ProcessRecord: Equatable {
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

enum CodexDaemon {
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

enum CodexTerminals {
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

    private nonisolated static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated static let isoPlain = ISO8601DateFormatter()

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
    nonisolated static func rateLimitStamp(inLine line: String) -> (resetsAt: Date, windowMinutes: Int?)? {
        guard line.contains("\"rate_limits\""), let object = json(line),
              let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any],
              let primary = limits["primary"] as? [String: Any],
              let resets = primary["resets_at"] as? Double else { return nil }
        return (Date(timeIntervalSince1970: resets), primary["window_minutes"] as? Int)
    }

    private nonisolated static func minute(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 60).rounded(.down)) }

    /// The UNIQUE Codex profile whose cached reset equals the stamp to the
    /// minute (the usage API jitters ±1 s across fetches). Claude and Grok
    /// profiles never match; two Codex matches are ambiguous and resolve to nil.
    nonisolated static func profile(matching evidence: Evidence, in profiles: [Profile]) -> Profile? {
        let weekly = (evidence.windowMinutes ?? 10080) >= 6 * 24 * 60
        let target = minute(evidence.resetsAt)
        let matches = profiles.filter { profile in
            guard profile.carriesCodexAccount, let usage = profile.claudeUsage else { return false }
            return minute(weekly ? usage.weeklyResetTime : usage.sessionResetTime) == target
        }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated static func line(from evidence: Evidence?, profiles: [Profile]) -> Line? {
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
    nonisolated static func format(_ line: Line?, clock: DateFormatter = clock) -> String {
        guard let line else { return "codex_daemon.terminals_unknown".localized }
        let who = line.profileName ?? "codex_daemon.terminals_unknown_account".localized
        return "codex_daemon.terminals_line".localized(with: who, clock.string(from: line.since))
    }

    // MARK: Rollout scan (file I/O — call off the main actor)

    /// The newest daemon-written rollout that carries a rate-limit stamp, read
    /// from `<sessionsRoot>/YYYY/MM/DD/*.jsonl`: the two newest day directories,
    /// the newest `maxFiles` files by modification date, first `codex-tui`
    /// rollout with a stamp wins, and the LAST stamp in it is the one reported.
    nonisolated static func newestDaemonEvidence(
        sessionsRoot: URL, fileManager: FileManager = .default, maxFiles: Int = 30
    ) -> Evidence? {
        for url in recentRolloutFiles(sessionsRoot: sessionsRoot, fileManager: fileManager, limit: maxFiles) {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(whereSeparator: \.isNewline)
            guard let first = lines.first.map(String.init),
                  originator(ofSessionMetaLine: first) == daemonOriginator else { continue }
            for line in lines.reversed() where line.contains("\"rate_limits\"") {
                if let stamp = rateLimitStamp(inLine: String(line)) {
                    let started = sessionStart(ofSessionMetaLine: first)
                        ?? (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                        ?? Date()
                    return Evidence(resetsAt: stamp.resetsAt, windowMinutes: stamp.windowMinutes, sessionStartedAt: started)
                }
            }
        }
        return nil
    }

    /// Newest-first rollout files from the two newest day directories.
    nonisolated static func recentRolloutFiles(sessionsRoot: URL, fileManager: FileManager, limit: Int) -> [URL] {
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
        let files = days.flatMap { day -> [(URL, Date)] in
            ((try? fileManager.contentsOfDirectory(at: day, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
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

    /// Re-derives the terminals line from the newest daemon-written rollout.
    /// File reads run off the main actor; the result is cached for the
    /// dashboard and the inspector.
    func refreshTerminalsState(profiles: [Profile]) async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let root = CodexUsageService.defaultCodexHome.appendingPathComponent("sessions")
        let evidence = await Self.offMain { CodexTerminals.newestDaemonEvidence(sessionsRoot: root) }
        let line = CodexTerminals.line(from: evidence, profiles: profiles)
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
