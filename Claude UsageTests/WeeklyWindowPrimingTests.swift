//
//  WeeklyWindowPrimingTests.swift
//  Claude UsageTests
//
//  Weekly-window priming (docs/specs/weekly-window-priming.md), the pure
//  parts: the parser's closed / running reading and its healing, the window
//  state, the schedule (exclusions, jitter, episodes, once per window, one
//  retry), the verification of a sent prime by later fetches, the CLI
//  command, and the two settings records' decoding. No test runs `codex`,
//  touches a home directory, the network or the preferences store. Fixture
//  names follow the synthetic roster (Atlas, Cedar). The three real payload
//  shapes live in WeeklyWindowPrimingPayloadTests.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class WeeklyWindowPrimingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let atlas = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let cedar = UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!
    private let week: TimeInterval = 7 * 24 * 3600

    /// A Codex usage as the parser + healer would leave it.
    private func codexUsage(windowOpen: Bool?, reset: Date? = nil, weekly: Double = 0, projected: Bool? = nil,
                            updated: Date? = nil) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = false
        usage.weeklyWindowOpen = windowOpen
        usage.weeklyWindowSeconds = week
        usage.weeklyPercentage = weekly
        usage.weeklyResetTime = reset ?? now.addingTimeInterval(week)
        usage.weeklyResetProjected = projected
        usage.lastUpdated = updated ?? now
        return usage
    }

    private func candidate(_ id: UUID? = nil, name: String = "Atlas", provider: Profile.ProviderKind = .codex,
                           credentials: Bool = true, owner: Bool = false, dead: Bool = false,
                           usage: ClaudeUsage?) -> WeeklyPrimeCandidate {
        WeeklyPrimeCandidate(id: id ?? atlas, name: name, provider: provider, hasCredentials: credentials,
                             isOwner: owner, isDead: dead, usage: usage)
    }

    // MARK: - Parser and healer

    func testCodexParserReadsAPlaceholderAsClosedAndARunningWindowAsOpen() throws {
        let service = CodexUsageService.shared
        let idle = try service.parseUsageResponse(Data(#"{"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_after_seconds":604800},"secondary_window":null},"plan_type":"pro"}"#.utf8))
        XCTAssertEqual(idle.weeklyWindowOpen, false)
        XCTAssertEqual(idle.weeklyResetTime, ClaudeUsage.unknownResetSentinel, "a placeholder's stamp is not a measurement")
        XCTAssertEqual(idle.weeklyWindowSeconds, 604800)
        XCTAssertEqual(idle.weeklyPercentage, 0)

        let resetAt = now.addingTimeInterval(3 * 86400)
        let payload = #"{"rate_limit":{"primary_window":{"used_percent":16,"reset_at":\#(Int(resetAt.timeIntervalSince1970)),"reset_after_seconds":259200,"limit_window_seconds":604800},"secondary_window":null}}"#
        let open = try service.parseUsageResponse(Data(payload.utf8))
        XCTAssertEqual(open.weeklyWindowOpen, true)
        XCTAssertEqual(open.weeklyResetTime.timeIntervalSince1970, resetAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(open.weeklyPercentage, 16)
    }

    func testHealerProjectsAClosedWindowSevenDaysOutAndMarksItProjected() {
        var usage = codexUsage(windowOpen: false, reset: ClaudeUsage.unknownResetSentinel)
        // A previous boundary means nothing to a rolling window.
        let previous = codexUsage(windowOpen: true, reset: now.addingTimeInterval(-2 * 86400))
        usage.healMissingResetStamps(previous: previous, now: now)
        XCTAssertEqual(usage.weeklyResetTime, now.addingTimeInterval(week))
        XCTAssertEqual(usage.weeklyResetProjected, true)
        XCTAssertEqual(usage.weeklyWindowOpen, false, "the flag survives healing — it is the primer's signal")
    }

    // MARK: - Window state

    func testWindowStateReadsClosedOpenExpiredAndUnknown() {
        let reset = now.addingTimeInterval(86400)
        XCTAssertEqual(WeeklyWindowState.of(codexUsage(windowOpen: false, projected: true), provider: .codex, now: now), .closed)
        XCTAssertEqual(WeeklyWindowState.of(codexUsage(windowOpen: true, reset: reset), provider: .codex, now: now), .open(resetAt: reset))
        // Legacy data (no flag): the stamp decides.
        XCTAssertEqual(WeeklyWindowState.of(codexUsage(windowOpen: nil, reset: reset), provider: .codex, now: now), .open(resetAt: reset))
        let passed = now.addingTimeInterval(-60)
        XCTAssertEqual(WeeklyWindowState.of(codexUsage(windowOpen: true, reset: passed), provider: .codex, now: now), .expired(resetAt: passed))
        XCTAssertEqual(WeeklyWindowState.of(nil, provider: .codex, now: now), .unknown)
        XCTAssertEqual(WeeklyWindowState.of(codexUsage(windowOpen: nil, reset: reset, projected: true), provider: .codex, now: now), .unknown,
                       "a projected boundary is not a reported window")
        XCTAssertEqual(WeeklyWindowState.of(codexUsage(windowOpen: false), provider: .claude, now: now), .unknown, "Claude is out of scope")
    }

    // MARK: - Schedule

    func testVerdictExcludesOwnersDeadLoginsUnsupportedProvidersTheNeverListAndTheToggle() {
        let closed = codexUsage(windowOpen: false, projected: true)
        let policy = WeeklyPrimePolicy()
        let record = WeeklyPrimeRecord(episodeObservedAt: now)
        func verdict(_ c: WeeklyPrimeCandidate, _ p: WeeklyPrimePolicy = policy) -> WeeklyPrimeVerdict {
            WeeklyPrimeSchedule.verdict(c, policy: p, record: record, now: now)
        }
        XCTAssertEqual(verdict(candidate(owner: true, usage: closed)), .excluded(.owner))
        XCTAssertEqual(verdict(candidate(dead: true, usage: closed)), .excluded(.deadLogin))
        XCTAssertEqual(verdict(candidate(credentials: false, usage: closed)), .excluded(.noCredentials))
        XCTAssertEqual(verdict(candidate(provider: .claude, usage: closed)), .excluded(.providerUnsupported))
        XCTAssertEqual(verdict(candidate(provider: .grok, usage: closed)), .excluded(.providerUnsupported))
        XCTAssertEqual(verdict(candidate(usage: closed), WeeklyPrimePolicy(codexEnabled: false)), .excluded(.providerOff))
        XCTAssertEqual(verdict(candidate(usage: closed), WeeklyPrimePolicy(neverPrime: [atlas])), .excluded(.neverPrime))
        XCTAssertEqual(verdict(candidate(cedar, usage: closed), WeeklyPrimePolicy(neverPrime: [atlas])).isPending, true,
                       "the never list names profiles, not the provider")
        XCTAssertFalse(WeeklyPrimePolicy.supports(.claude))
        XCTAssertFalse(WeeklyPrimePolicy().isEnabled(for: .grok))
    }

    func testAClosedWindowIsDueInsideTheJitterBoundsAndDeterministically() {
        let closed = codexUsage(windowOpen: false, projected: true)
        let episode = now.addingTimeInterval(-30)
        let record = WeeklyPrimeRecord(episodeObservedAt: episode)
        let first = WeeklyPrimeSchedule.verdict(candidate(usage: closed), policy: WeeklyPrimePolicy(), record: record, now: now)
        let again = WeeklyPrimeSchedule.verdict(candidate(usage: closed), policy: WeeklyPrimePolicy(), record: record, now: now.addingTimeInterval(45))
        guard case .due(let at) = first else { return XCTFail("expected due, got \(first)") }
        XCTAssertEqual(first, again, "the due time never moves between ticks")
        let delay = at.timeIntervalSince(episode)
        XCTAssertGreaterThanOrEqual(delay, WeeklyPrimeSchedule.minDelay)
        XCTAssertLessThanOrEqual(delay, WeeklyPrimeSchedule.maxDelay)

        // Every profile lands inside the bounds, and profiles do not all share one delay.
        var delays: Set<TimeInterval> = []
        for _ in 0..<200 {
            let jitter = WeeklyPrimeSchedule.jitter(profileId: UUID(), episodeObservedAt: episode)
            XCTAssertGreaterThanOrEqual(jitter, WeeklyPrimeSchedule.minDelay)
            XCTAssertLessThanOrEqual(jitter, WeeklyPrimeSchedule.maxDelay)
            delays.insert(jitter)
        }
        XCTAssertGreaterThan(delays.count, 20)
        XCTAssertEqual(WeeklyPrimeSchedule.jitter(profileId: atlas, episodeObservedAt: episode),
                       WeeklyPrimeSchedule.jitter(profileId: atlas, episodeObservedAt: episode))
    }

    func testAnEpisodeOpensWhenTheWindowClosesAndEndsWhenItOpens() {
        var record = WeeklyPrimeRecord(attempts: 1, lastAttemptAt: now.addingTimeInterval(-3600))
        XCTAssertTrue(WeeklyPrimeSchedule.observe(.closed, record: &record, now: now))
        XCTAssertEqual(record.episodeObservedAt, now)
        XCTAssertEqual(record.attempts, 0, "a new episode starts with fresh attempts")
        XCTAssertNil(record.lastAttemptAt)
        XCTAssertFalse(WeeklyPrimeSchedule.observe(.closed, record: &record, now: now.addingTimeInterval(60)), "still the same episode")
        XCTAssertEqual(record.episodeObservedAt, now)
        XCTAssertFalse(WeeklyPrimeSchedule.observe(.expired(resetAt: now), record: &record, now: now), "the next fetch decides")
        XCTAssertFalse(WeeklyPrimeSchedule.observe(.unknown, record: &record, now: now))
        record.attempts = 2
        XCTAssertTrue(WeeklyPrimeSchedule.observe(.open(resetAt: now.addingTimeInterval(week)), record: &record, now: now))
        XCTAssertNil(record.episodeObservedAt)
        XCTAssertEqual(record.attempts, 0)
        XCTAssertFalse(WeeklyPrimeSchedule.observe(.open(resetAt: now), record: &record, now: now))
    }

    func testAPrimedWindowIsNeverPrimedAgainUntilANewOneCloses() {
        let reset = now.addingTimeInterval(week - 600)
        let primed = WeeklyPrimeRecord(lastOutcome: .moved, lastPrimedAt: now.addingTimeInterval(-600),
                                       primedForWindowEndingAt: reset.addingTimeInterval(45))
        let open = codexUsage(windowOpen: true, reset: reset, weekly: 1)
        XCTAssertEqual(WeeklyPrimeSchedule.verdict(candidate(usage: open), policy: WeeklyPrimePolicy(), record: primed, now: now),
                       .waiting(.alreadyPrimed(resetAt: reset)))
        // A different window (somebody used the account after the last prime) is simply open.
        let later = codexUsage(windowOpen: true, reset: reset.addingTimeInterval(3 * 3600))
        XCTAssertEqual(WeeklyPrimeSchedule.verdict(candidate(usage: later), policy: WeeklyPrimePolicy(), record: primed, now: now),
                       .waiting(.windowOpen(resetAt: reset.addingTimeInterval(3 * 3600))))
        let passed = codexUsage(windowOpen: true, reset: now.addingTimeInterval(-10))
        XCTAssertEqual(WeeklyPrimeSchedule.verdict(candidate(usage: passed), policy: WeeklyPrimePolicy(), record: primed, now: now),
                       .waiting(.awaitingFetch(resetAt: now.addingTimeInterval(-10))))
        XCTAssertEqual(WeeklyPrimeSchedule.verdict(candidate(usage: nil), policy: WeeklyPrimePolicy(), record: primed, now: now),
                       .waiting(.unknownWindow))
        // A request in flight outranks the window's reading: it is being verified.
        let sent = WeeklyPrimeRecord(episodeObservedAt: now.addingTimeInterval(-400), attempts: 1,
                                     lastAttemptAt: now.addingTimeInterval(-40), lastOutcome: .sent)
        XCTAssertEqual(WeeklyPrimeSchedule.verdict(candidate(usage: codexUsage(windowOpen: false, projected: true)),
                                                   policy: WeeklyPrimePolicy(), record: sent, now: now),
                       .waiting(.verifying(since: now.addingTimeInterval(-40))))
    }

    func testAFailureIsRetriedOnceAfterThirtyMinutesThenTheEpisodeIsSpent() {
        let closed = codexUsage(windowOpen: false, projected: true)
        let failedOnce = WeeklyPrimeRecord(episodeObservedAt: now.addingTimeInterval(-900), attempts: 1,
                                           lastAttemptAt: now.addingTimeInterval(-60), lastOutcome: .failed)
        XCTAssertEqual(WeeklyPrimeSchedule.verdict(candidate(usage: closed), policy: WeeklyPrimePolicy(), record: failedOnce, now: now),
                       .due(at: now.addingTimeInterval(WeeklyPrimeSchedule.retryDelay - 60)))
        let spent = WeeklyPrimeRecord(episodeObservedAt: now.addingTimeInterval(-3600), attempts: 2,
                                      lastAttemptAt: now.addingTimeInterval(-60), lastOutcome: .noMovement)
        XCTAssertEqual(WeeklyPrimeSchedule.verdict(candidate(usage: closed), policy: WeeklyPrimePolicy(), record: spent, now: now),
                       .waiting(.attemptsExhausted))
        XCTAssertEqual(WeeklyPrimeSchedule.maxAttemptsPerEpisode, 2)
    }

    // MARK: - Verification

    func testASentPrimeIsVerifiedByALaterFetchThatShowsTheClockRunning() {
        let clock = DateFormatter()
        clock.dateFormat = "MMM d HH:mm"
        clock.timeZone = TimeZone(identifier: "UTC")
        let sentAt = now.addingTimeInterval(-150)
        let sent = WeeklyPrimeRecord(episodeObservedAt: now.addingTimeInterval(-600), attempts: 1, lastAttemptAt: sentAt, lastOutcome: .sent)

        // A fetch from before the request proves nothing.
        let stale = codexUsage(windowOpen: false, projected: true, updated: sentAt.addingTimeInterval(-10))
        XCTAssertNil(WeeklyPrimeVerification.resolve(sent: sent, usage: stale, provider: .codex, now: now, clock: clock))
        // A fetch inside the tolerance still reads closed: keep verifying.
        let early = codexUsage(windowOpen: false, projected: true, updated: sentAt.addingTimeInterval(30))
        XCTAssertNil(WeeklyPrimeVerification.resolve(sent: sent, usage: early, provider: .codex, now: now, clock: clock))

        // The clock is running: reset_after dropped below the window length.
        let fetchedAt = sentAt.addingTimeInterval(150)
        let running = codexUsage(windowOpen: true, reset: sentAt.addingTimeInterval(week), weekly: 0, updated: fetchedAt)
        let moved = WeeklyPrimeVerification.resolve(sent: sent, usage: running, provider: .codex, now: now, clock: clock)
        XCTAssertEqual(moved?.outcome, .moved)
        XCTAssertEqual(moved?.resetAt, running.weeklyResetTime)
        XCTAssertEqual(moved?.detail, "window started: reset_after 604800 → 604650 s, resets \(clock.string(from: running.weeklyResetTime)), used 0%")

        // Still closed after the grace: no movement.
        let late = now.addingTimeInterval(WeeklyPrimeVerification.grace)
        let stuck = codexUsage(windowOpen: false, projected: true, updated: late.addingTimeInterval(-5))
        let none = WeeklyPrimeVerification.resolve(sent: sent, usage: stuck, provider: .codex, now: late, clock: clock)
        XCTAssertEqual(none?.outcome, .noMovement)
        XCTAssertTrue(none?.detail.hasPrefix("no window movement 10 min after the request (no window (idle)") == true, none?.detail ?? "nil")
        XCTAssertNil(WeeklyPrimeVerification.resolve(sent: WeeklyPrimeRecord(lastAttemptAt: sentAt, lastOutcome: .moved), usage: running,
                                                     provider: .codex, now: now, clock: clock), "only a sent prime resolves")
    }

    func testBookingTheAttemptsAndTheirResolution() {
        var record = WeeklyPrimeRecord(episodeObservedAt: now.addingTimeInterval(-300))
        WeeklyPrimeVerification.recordFailure("codex exec exited 1", into: &record, now: now)
        XCTAssertEqual(record.attempts, 1)
        XCTAssertEqual(record.lastAttemptAt, now)
        XCTAssertEqual(record.lastOutcome, .failed)
        XCTAssertEqual(record.lastDetail, "codex exec exited 1")
        XCTAssertNil(record.lastPrimedAt)

        let sentAt = now.addingTimeInterval(1800)
        WeeklyPrimeVerification.recordSent(into: &record, now: sentAt)
        XCTAssertEqual(record.attempts, 2)
        XCTAssertEqual(record.lastOutcome, .sent)
        XCTAssertTrue(record.isAwaitingVerification)

        let reset = sentAt.addingTimeInterval(week)
        let move = WeeklyPrimeVerification.Result(outcome: .moved, detail: "window started", resetAt: reset, usedPercent: 0)
        WeeklyPrimeVerification.record(move, into: &record)
        XCTAssertEqual(record.attempts, 2, "a resolution is not a new attempt")
        XCTAssertEqual(record.lastPrimedAt, sentAt, "primed at the request time, not at the fetch")
        XCTAssertEqual(record.primedForWindowEndingAt, reset)
        XCTAssertEqual(record.lastVerifiedUsedPercent, 0)
        XCTAssertEqual(record.lastOutcome, .moved)
        XCTAssertFalse(record.isAwaitingVerification)

        WeeklyPrimeVerification.recordSent(into: &record, now: sentAt.addingTimeInterval(60))
        let none = WeeklyPrimeVerification.Result(outcome: .noMovement, detail: "no window movement", resetAt: nil, usedPercent: 0)
        WeeklyPrimeVerification.record(none, into: &record)
        XCTAssertEqual(record.lastOutcome, .noMovement)
        XCTAssertEqual(record.lastPrimedAt, sentAt, "an unmoved attempt never touches the primed stamps")
        XCTAssertEqual(record.primedForWindowEndingAt, reset)
    }

    // MARK: - The CLI command

    func testCommandArgumentsEnvironmentAndOutputTail() {
        let arguments = CodexPrimeCommand.arguments()
        XCTAssertEqual(arguments.first, "exec")
        XCTAssertEqual(arguments.last, "Reply with exactly OK")
        XCTAssertTrue(arguments.contains("--skip-git-repo-check"))
        XCTAssertEqual(arguments.firstIndex(of: "--sandbox").map { arguments[$0 + 1] }, "read-only")
        XCTAssertEqual(arguments.firstIndex(of: "-c").map { arguments[$0 + 1] }, "model_reasoning_effort=\"low\"")
        XCTAssertFalse(arguments.contains("-m"), "no model by default — the account's own default model charges the window")
        XCTAssertEqual(CodexPrimeCommand.arguments(model: "gpt-6-astra").firstIndex(of: "-m").map { CodexPrimeCommand.arguments(model: "gpt-6-astra")[$0 + 1] }, "gpt-6-astra")

        let home = URL(fileURLWithPath: "/Users/tester/.codex-accounts/atlas")
        let env = CodexPrimeCommand.environment(home: home, inherited: ["PATH": "/usr/bin", "CODEX_HOME": "/Users/tester/.codex"])
        XCTAssertEqual(env["CODEX_HOME"], home.path, "an inherited CODEX_HOME never wins")
        XCTAssertEqual(env["PATH"], "/usr/bin")

        XCTAssertEqual(CodexPrimeCommand.tail(of: "a\nb\n\nc\nd\ne\n  f  \n", lines: 3), "d ⏎ e ⏎ f")
        XCTAssertEqual(CodexPrimeCommand.tail(of: ""), "")
        XCTAssertEqual(CodexPrimeCommand.timeout, 90)
    }

    func testTheHomeIsTheRememberedIsolatedOneOrOneNamedAfterTheProfileNeverTheDefault() {
        let defaultHome = URL(fileURLWithPath: "/Users/tester/.codex")
        let root = URL(fileURLWithPath: "/Users/tester/.codex-accounts")
        XCTAssertEqual(CodexPrimeCommand.home(remembered: "/Users/tester/.codex-accounts/atlas-work", profileName: "Atlas", defaultHome: defaultHome, isolatedRoot: root)?.path,
                       "/Users/tester/.codex-accounts/atlas-work")
        XCTAssertEqual(CodexPrimeCommand.home(remembered: nil, profileName: "Cedar (dev)", defaultHome: defaultHome, isolatedRoot: root)?.path,
                       "/Users/tester/.codex-accounts/cedar-dev")
        XCTAssertEqual(CodexPrimeCommand.home(remembered: "", profileName: "Atlas", defaultHome: defaultHome, isolatedRoot: root)?.path,
                       "/Users/tester/.codex-accounts/atlas")
        XCTAssertNil(CodexPrimeCommand.home(remembered: "/Users/tester/.codex/", profileName: "Atlas", defaultHome: defaultHome, isolatedRoot: root),
                     "the default home is refused, never reused")
        XCTAssertNil(CodexPrimeCommand.home(remembered: nil, profileName: "🙂", defaultHome: defaultHome, isolatedRoot: root))
    }

    func testBinaryCandidatesPutTheStandaloneBuildBeforeHomebrew() {
        let candidates = CodexPrimeCommand.binaryCandidates(codexHome: URL(fileURLWithPath: "/Users/tester/.codex"))
        XCTAssertEqual(candidates.first, "/Users/tester/.codex/packages/standalone/current/bin/codex")
        XCTAssertEqual(Array(candidates.dropFirst()), CodexLoginService.wellKnownBinaryPaths)
        // The resolver honours that order and still falls back to the login shell.
        let found = CodexLoginService.codexBinaryPath(wellKnown: candidates, isExecutable: { $0.hasSuffix("/opt/homebrew/bin/codex") }, loginShellLookup: { nil })
        XCTAssertEqual(found, "/opt/homebrew/bin/codex")
        let shell = CodexLoginService.codexBinaryPath(wellKnown: candidates, isExecutable: { $0 == "/Users/tester/bin/codex" }, loginShellLookup: { "/Users/tester/bin/codex\n" })
        XCTAssertEqual(shell, "/Users/tester/bin/codex")
    }

    func testRunVerdictsNameTheFailure() {
        func run(status: Int32?, timedOut: Bool = false, launchError: String? = nil, output: String = "") -> CodexPrimeCommand.Run {
            CodexPrimeCommand.Run(status: status, timedOut: timedOut, launchError: launchError, output: output, duration: 1)
        }
        XCTAssertNil(CodexPrimeCommand.failure(of: run(status: 0, output: "OK")))
        XCTAssertEqual(CodexPrimeCommand.failure(of: run(status: nil, launchError: "not permitted")), .launchFailed("not permitted"))
        XCTAssertEqual(CodexPrimeCommand.failure(of: run(status: 15, timedOut: true), timeout: 90), .timedOut(after: 90))
        XCTAssertEqual(CodexPrimeCommand.failure(of: run(status: 2, output: "error: model not found\n")), .exit(status: 2, tail: "error: model not found"))
        XCTAssertEqual(CodexPrimeCommand.Failure.exit(status: 2, tail: "boom").description, "codex exec exited 2: boom")
        XCTAssertEqual(CodexPrimeCommand.Failure.timedOut(after: 90).description, "codex exec timed out after 90 s")
    }

    // MARK: - Settings records

    func testPolicyAndLedgerRecordsDecodeWithDefaultsAndRoundTrip() throws {
        let decoder = JSONDecoder()
        let absent = try decoder.decode(WeeklyPrimePolicy.self, from: Data("{}".utf8))
        XCTAssertEqual(absent, WeeklyPrimePolicy(), "an absent field reads as ON with nobody excluded")
        XCTAssertTrue(absent.codexEnabled)
        let policy = WeeklyPrimePolicy(codexEnabled: false, neverPrime: [atlas, cedar])
        XCTAssertEqual(try decoder.decode(WeeklyPrimePolicy.self, from: JSONEncoder().encode(policy)), policy)

        let bare = try decoder.decode(WeeklyPrimeRecord.self, from: Data("{}".utf8))
        XCTAssertEqual(bare, WeeklyPrimeRecord())
        XCTAssertEqual(bare.attempts, 0)
        let record = WeeklyPrimeRecord(episodeObservedAt: now, attempts: 1, lastAttemptAt: now, lastOutcome: .sent,
                                       lastDetail: "request sent", lastPrimedAt: now,
                                       primedForWindowEndingAt: now.addingTimeInterval(week), lastVerifiedUsedPercent: 1)
        XCTAssertEqual(try decoder.decode(WeeklyPrimeRecord.self, from: JSONEncoder().encode(record)), record)
        XCTAssertEqual(SettingsKeyRegistry.lookup("weeklyPrimePolicy_v1")?.status, .live)
        XCTAssertEqual(SettingsKeyRegistry.lookup("weeklyPrimeLedger_v1")?.owner, .sharedDataStore)
    }
}
