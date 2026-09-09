//
//  WeeklyWindowPrimer.swift
//  Claude Usage
//
//  Runs weekly-window priming (docs/specs/weekly-window-priming.md). The
//  rules live in WeeklyWindowPriming.swift; this file is the two impure parts:
//
//  1. `CodexPrimeCommand` — the one tiny headless request, `codex exec` in the
//     profile's OWN isolated CODEX_HOME, so auth refresh, rollout writing and
//     the primary bucket all behave exactly like real use. Never the shared
//     daemon, never the default `~/.codex` for a non-owner: the profile's
//     stored login is written to `<isolated home>/auth.json` first (the copy
//     there may hold a refresh token the widget has since rotated), the CLI
//     runs there with stdin closed and a hard timeout, and a rotation the CLI
//     makes is adopted back with the switch path's same-account rule.
//  2. `WeeklyWindowPrimer` — the scheduler the sweep ticks: one profile at a
//     time, never mid-switch, verified by a forced fetch, booked in the ledger,
//     logged with the moved stamps, one INFO notice when an episode's two
//     attempts both fail.
//

import Foundation
import os

// MARK: - The CLI command

nonisolated enum CodexPrimeCommand {
    /// A hard ceiling on the run: a reply to "OK" takes seconds; anything
    /// longer is a hung CLI (a prompt it cannot answer, a network stall).
    static let timeout: TimeInterval = 90
    /// After SIGTERM, how long before SIGKILL.
    static let killGrace: TimeInterval = 5
    static let prompt = "Reply with exactly OK"
    static let reasoningEffort = "low"
    /// How much of the CLI's output is kept for the log (the tail).
    static let outputLimit = 16 * 1024

    /// `codex exec --skip-git-repo-check --sandbox read-only --color never
    /// -c model_reasoning_effort="low" [-m <model>] "Reply with exactly OK"`.
    /// No model by default: the account's own default model is the one every
    /// real request charges the weekly window with.
    static func arguments(model: String? = nil) -> [String] {
        var arguments = [
            "exec", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
            "-c", "model_reasoning_effort=\"\(reasoningEffort)\"",
        ]
        if let model, !model.isEmpty { arguments += ["-m", model] }
        arguments.append(prompt)
        return arguments
    }

    /// The child's environment: everything this process has plus `CODEX_HOME`
    /// pointing at the isolated home (overriding an inherited one).
    static func environment(home: URL, inherited: [String: String]) -> [String: String] {
        CodexLoginService.loginEnvironment(home: home, inherited: inherited)
    }

    /// Where the prime runs: the profile's remembered isolated home, else one
    /// named after the profile under the isolated-homes root. NEVER the
    /// default home — a remembered path equal to it is refused, not reused.
    static func home(remembered: String?, profileName: String, defaultHome: URL, isolatedRoot: URL) -> URL? {
        if let remembered, !remembered.isEmpty {
            let url = URL(fileURLWithPath: remembered)
            // Paths, not URLs: a trailing slash must not make the default home
            // look like somewhere else.
            return url.standardizedFileURL.path == defaultHome.standardizedFileURL.path ? nil : url
        }
        guard let slug = CodexLoginService.slug(for: profileName) else { return nil }
        return isolatedRoot.appendingPathComponent(slug)
    }

    /// The binaries to try, in order: the standalone build inside the Codex
    /// home (the one the daemon and the user's terminals run), then Homebrew's.
    static func binaryCandidates(codexHome: URL) -> [String] {
        [codexHome.appendingPathComponent("packages/standalone/current/bin/codex").path]
            + CodexLoginService.wellKnownBinaryPaths
    }

    /// Why a prime could not run, or did not run cleanly.
    enum Failure: Error, Equatable, CustomStringConvertible {
        case noCredentials
        case noIsolatedHome
        case binaryNotFound
        case homeNotWritable(String)
        case launchFailed(String)
        case timedOut(after: TimeInterval)
        case exit(status: Int32, tail: String)

        var description: String {
            switch self {
            case .noCredentials: return "no Codex credentials stored"
            case .noIsolatedHome: return "no isolated CODEX_HOME to run in"
            case .binaryNotFound: return "codex binary not found"
            case .homeNotWritable(let why): return "could not write auth.json to the isolated home: \(why)"
            case .launchFailed(let why): return "codex exec could not start: \(why)"
            case .timedOut(let after): return "codex exec timed out after \(Int(after)) s"
            case .exit(let status, let tail): return "codex exec exited \(status)" + (tail.isEmpty ? "" : ": \(tail)")
            }
        }
    }

    /// One finished (or abandoned) run.
    struct Run: Equatable {
        var status: Int32?
        var timedOut: Bool
        var launchError: String?
        var output: String
        var duration: TimeInterval
    }

    /// The verdict on a run: nil is a clean exit.
    static func failure(of run: Run, timeout: TimeInterval = timeout) -> Failure? {
        if let launchError = run.launchError { return .launchFailed(launchError) }
        if run.timedOut { return .timedOut(after: timeout) }
        guard let status = run.status, status == 0 else {
            return .exit(status: run.status ?? -1, tail: tail(of: run.output))
        }
        return nil
    }

    /// The last few lines of the CLI's output, for a log line or a failure.
    static func tail(of output: String, lines count: Int = 4) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(count)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ⏎ ")
    }

    /// Runs the CLI to completion. Blocking — call it off the main actor.
    /// stdin is closed (an open pipe makes the CLI wait for input forever),
    /// stdout and stderr are drained as they arrive and capped at
    /// `outputLimit`, and a run past `timeout` gets SIGTERM then SIGKILL.
    static func run(binary: String, arguments: [String], environment: [String: String],
                    currentDirectory: URL, timeout: TimeInterval = timeout) -> Run {
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let buffer = OutputTail(limit: outputLimit)
        let drained = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                drained.signal()
                return
            }
            buffer.append(data)
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return Run(status: nil, timedOut: false, launchError: error.localizedDescription, output: "", duration: 0)
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + killGrace)
            }
        }
        // Give the reader a moment to see EOF; a child that kept the pipe open
        // (a helper the CLI left behind) must not hang the sweep here.
        _ = drained.wait(timeout: .now() + 1)
        output.fileHandleForReading.readabilityHandler = nil
        return Run(status: process.terminationStatus, timedOut: timedOut, launchError: nil,
                   output: buffer.text, duration: Date().timeIntervalSince(start))
    }

    /// The CLI's output, capped to its tail — filled from the pipe's reader
    /// queue, read once after the exit.
    final class OutputTail: @unchecked Sendable {
        private let limit: Int
        private var data = Data()
        private let lock = NSLock()

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
            if data.count > limit { data = data.suffix(limit) }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

// MARK: - Priming one Codex profile

enum CodexWindowPrimer {
    /// Freshen the token, write it to the isolated home, run the CLI there,
    /// adopt whatever the CLI rotated. Blocking work runs off the main actor;
    /// the store reads and writes stay on it.
    static func prime(_ profile: Profile, timeout: TimeInterval = CodexPrimeCommand.timeout) async -> Result<CodexPrimeCommand.Run, CodexPrimeCommand.Failure> {
        let service = CodexUsageService.shared
        // A token fresh for a day: the CLI must never have to refresh with a
        // token the widget is about to rotate anyway, and a refresh the widget
        // does here is persisted through the usual path.
        _ = await service.ensureFreshCredentials(for: profile.id, freshFor: 24 * 3600)
        guard let json = ProfileStore.shared.loadProfiles().first(where: { $0.id == profile.id })?.codexCredentialsJSON else {
            return .failure(.noCredentials)
        }
        let defaultHome = CodexUsageService.defaultCodexHome
        guard let home = CodexPrimeCommand.home(
            remembered: profile.codexHomePath, profileName: profile.name,
            defaultHome: defaultHome, isolatedRoot: CodexUsageService.isolatedHomesRoot
        ) else {
            return .failure(.noIsolatedHome)
        }
        let environment = CodexPrimeCommand.environment(home: home, inherited: ProcessInfo.processInfo.environment)

        let outcome: Result<CodexPrimeCommand.Run, CodexPrimeCommand.Failure> = await offMain {
            do {
                try CodexUsageService.writeAuthFile(json, inHome: home)
            } catch {
                return .failure(.homeNotWritable(error.localizedDescription))
            }
            guard let binary = CodexLoginService.locateCodexBinary(
                wellKnown: CodexPrimeCommand.binaryCandidates(codexHome: defaultHome)
            ) else {
                return .failure(.binaryNotFound)
            }
            let run = CodexPrimeCommand.run(
                binary: binary, arguments: CodexPrimeCommand.arguments(), environment: environment,
                currentDirectory: home, timeout: timeout
            )
            if let failure = CodexPrimeCommand.failure(of: run, timeout: timeout) { return .failure(failure) }
            return .success(run)
        }

        // The CLI may have rotated the tokens in the isolated home: adopt them
        // with the same account_id + fresher rule the switch path uses, or the
        // profile keeps a consumed refresh token ("refresh token was revoked").
        if service.adoptAuthFileIfSameAccount(for: profile.id, inHome: home) {
            LoggingService.shared.log("Prime: codex '\(profile.name)' — adopted the tokens codex exec rotated in \(home.lastPathComponent)")
        }
        if profile.codexHomePath == nil || profile.codexHomePath?.isEmpty == true {
            rememberHome(home, for: profile.id)
        }
        return outcome
    }

    /// A profile synced from the default home now has an isolated home of its
    /// own; remember it so a re-login and the next prime land there.
    private static func rememberHome(_ home: URL, for profileId: UUID) {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[index].codexHomePath = home.path
        ProfileStore.shared.saveProfiles(profiles)
    }

    private static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}

// MARK: - The scheduler

final class WeeklyWindowPrimer {
    static let shared = WeeklyWindowPrimer()

    /// What one tick reads. The switch flag is a closure because a switch can
    /// start while a prime's fetch is awaiting.
    struct Context {
        var profiles: [Profile]
        /// The provider owners (`ProfileManager.activeAccountIds`) — being used
        /// anyway, never primed automatically.
        var ownerIds: Set<UUID>
        var isLoginDead: (Profile) -> Bool
        var isSwitching: () -> Bool
        /// A fetch with the profile's own credentials that stages, publishes
        /// and returns the healed usage — the verifying read after a prime.
        var fetch: (Profile) async throws -> ClaudeUsage
        var now: Date = Date()
    }

    private let store: SharedDataStore
    private(set) var ledger: [UUID: WeeklyPrimeRecord]
    /// Every profile's verdict from the last tick — what the dashboard row
    /// and the inspector read ("prime pending", "primed HH:MM").
    private(set) var verdicts: [UUID: WeeklyPrimeVerdict] = [:]
    private(set) var inFlight: UUID?

    init(store: SharedDataStore = .shared) {
        self.store = store
        ledger = store.loadWeeklyPrimeLedger()
    }

    func record(for profileId: UUID) -> WeeklyPrimeRecord? { ledger[profileId] }
    func verdict(for profileId: UUID) -> WeeklyPrimeVerdict? { verdicts[profileId] }

    /// One sweep's worth of priming: re-read every window, open or end its
    /// episode, and run the ONE most overdue prime. Nothing runs mid-switch or
    /// while a prime is already in flight.
    func tick(_ context: Context) async {
        guard inFlight == nil, !context.isSwitching() else { return }
        let policy = store.loadWeeklyPrimePolicy()
        let now = context.now
        var changed = pruneDeleted(context.profiles)
        var due: [(profile: Profile, at: Date)] = []

        for profile in context.profiles {
            let candidate = makeCandidate(profile, context: context)
            var record = ledger[profile.id] ?? WeeklyPrimeRecord()
            let state = WeeklyWindowState.of(profile.claudeUsage, provider: profile.providerKind, now: now)
            if WeeklyPrimeSchedule.observe(state, record: &record, now: now) {
                ledger[profile.id] = record
                changed = true
                if state == .closed {
                    LoggingService.shared.log("Prime: codex '\(profile.name)' — weekly window seen closed (no window reported)")
                }
            }
            let verdict = WeeklyPrimeSchedule.verdict(candidate, policy: policy, record: record, now: now)
            if verdicts[profile.id] != verdict, case .due(let at) = verdict {
                LoggingService.shared.log("Prime: codex '\(profile.name)' — priming due \(WeeklyPrimeVerification.clock.string(from: at))")
            }
            verdicts[profile.id] = verdict
            if case .due(let at) = verdict, at <= now { due.append((profile, at)) }
        }
        if changed { store.saveWeeklyPrimeLedger(ledger) }

        guard let next = due.min(by: { $0.at < $1.at })?.profile else { return }
        _ = await prime(next, context: context, userInitiated: false)
    }

    /// The inspector's "Prime now": the owner's explicit ask, so the schedule,
    /// the toggle and the never-prime list do not apply — the hard exclusions
    /// (no credentials, dead login, unsupported provider, a switch in flight)
    /// do. Returns the outcome line for the sheet.
    func primeNow(_ profileId: UUID, context: Context) async -> String {
        guard let profile = context.profiles.first(where: { $0.id == profileId }) else { return "prime.outcome_no_profile".localized }
        guard WeeklyPrimePolicy.supports(profile.providerKind) else { return "prime.outcome_unsupported".localized }
        guard profile.hasCodexAccount else { return "prime.outcome_no_credentials".localized }
        guard !context.isLoginDead(profile) else { return "prime.outcome_dead".localized }
        guard !context.isSwitching() else { return "prime.outcome_switching".localized }
        guard inFlight == nil else { return "prime.outcome_busy".localized }
        return await prime(profile, context: context, userInitiated: true)
    }

    // MARK: Running one prime

    private func prime(_ profile: Profile, context: Context, userInitiated: Bool) async -> String {
        inFlight = profile.id
        defer { inFlight = nil }

        var record = ledger[profile.id] ?? WeeklyPrimeRecord()
        let before = profile.claudeUsage
        let beforeState = WeeklyWindowState.of(before, provider: profile.providerKind, now: Date())
        LoggingService.shared.log(
            "Prime: codex '\(profile.name)' — starting attempt \(record.attempts + 1)"
                + " (\(userInitiated ? "Prime now" : "scheduled"); window before: \(WeeklyPrimeVerification.describe(beforeState)))"
        )

        let result: WeeklyPrimeVerification.Result
        switch await CodexWindowPrimer.prime(profile) {
        case .failure(let failure):
            result = WeeklyPrimeVerification.Result(outcome: .failed, detail: failure.description, resetAt: nil, usedPercent: nil)
            LoggingService.shared.logError("Prime: codex '\(profile.name)' — \(failure.description)")
        case .success(let run):
            LoggingService.shared.log(
                "Prime: codex '\(profile.name)' — codex exec exited 0 in \(String(format: "%.1f", run.duration)) s: \(CodexPrimeCommand.tail(of: run.output))",
                type: .info
            )
            do {
                let after = try await context.fetch(profile)
                result = WeeklyPrimeVerification.compare(before: before, after: after, provider: profile.providerKind, now: Date())
            } catch {
                result = WeeklyPrimeVerification.Result(
                    outcome: .noMovement, detail: "request ran; the verifying fetch failed: \(error.localizedDescription)",
                    resetAt: nil, usedPercent: nil
                )
            }
        }

        let now = Date()
        WeeklyPrimeVerification.record(result, into: &record, now: now)
        ledger[profile.id] = record
        store.saveWeeklyPrimeLedger(ledger)

        let line = "Prime: codex '\(profile.name)' — \(result.detail)"
        if result.outcome == .moved { LoggingService.shared.log(line) } else { LoggingService.shared.logWarning(line) }

        if !userInitiated, result.outcome != .moved, record.attempts >= WeeklyPrimeSchedule.maxAttemptsPerEpisode {
            NotificationManager.shared.sendWeeklyPrimeFailedNotification(
                profileName: profile.name, detail: result.detail, episodeStartedAt: record.episodeObservedAt
            )
        }
        NotificationCenter.default.post(name: .weeklyPrimeStateChanged, object: profile.id)
        return result.detail
    }

    private func makeCandidate(_ profile: Profile, context: Context) -> WeeklyPrimeCandidate {
        WeeklyPrimeCandidate(
            id: profile.id, name: profile.name, provider: profile.providerKind,
            hasCredentials: profile.hasCodexAccount,
            isOwner: context.ownerIds.contains(profile.id),
            isDead: context.isLoginDead(profile),
            usage: profile.claudeUsage
        )
    }

    /// Ledger rows of profiles that no longer exist. Returns true when any went.
    private func pruneDeleted(_ profiles: [Profile]) -> Bool {
        let live = Set(profiles.map(\.id))
        let stale = ledger.keys.filter { !live.contains($0) }
        stale.forEach { ledger.removeValue(forKey: $0) }
        return !stale.isEmpty
    }
}
