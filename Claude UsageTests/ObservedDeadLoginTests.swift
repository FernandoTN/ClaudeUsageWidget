//
//  ObservedDeadLoginTests.swift
//  Claude UsageTests
//
//  Server-rejected Claude logins (2026-09-24, 03:31 and 20:31). A login the
//  server had invalidated was structurally perfect, so `hasDeadLogin` never
//  called it dead. It generated no usage, so it never crossed a switch
//  threshold either. The fleet sat on it until the owner ran `/login` by
//  hand. These tests pin the two detectors, the recovery they drive, and
//  above all the dangerous direction: a 429, a network error or a DNS failure
//  must never condemn a login, because that is exactly what both incidents
//  looked like from the widget's side.
//
//  Everything runs on injected clocks and fixtures. No network, no Keychain
//  item, and the only files written live in a per-test temporary directory.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class ObservedDeadLoginTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObservedDeadLoginTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ObservedDeadLogins.shared.resetForTesting()
    }

    override func tearDown() {
        ObservedDeadLogins.shared.resetForTesting()
        ProfileCredentialStatusCache.invalidateAll()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    private var unauthorized: AppError {
        AppError(code: .apiUnauthorized, message: "OAuth fetch failed (status 401)")
    }

    /// Every failure that is NOT evidence about a login. Both real incidents
    /// were a stream of the first two.
    private var nonLoginFailures: [(String, Error)] {
        var retryAfterZero = AppError.apiRateLimited()
        retryAfterZero.retryAfterSeconds = 0
        var retryAfterLong = AppError.apiRateLimited()
        retryAfterLong.retryAfterSeconds = 2918
        return [
            ("429 retry-after 0", retryAfterZero),
            ("429 retry-after 2918", retryAfterLong),
            ("429 bare", AppError.apiRateLimited()),
            ("URLError offline", URLError(.notConnectedToInternet)),
            ("URLError cannot find host", URLError(.cannotFindHost)),
            ("URLError DNS lookup failed", URLError(.dnsLookupFailed)),
            ("URLError timed out", URLError(.timedOut)),
            ("URLError connection lost", URLError(.networkConnectionLost)),
            ("URLError secure connection", URLError(.secureConnectionFailed)),
            ("AppError DNS", AppError(code: .networkDNSFailed, message: "dns")),
            ("AppError offline", AppError(code: .networkUnavailable, message: "offline")),
            ("AppError timeout", AppError(code: .networkTimeout, message: "timeout")),
            ("AppError 5xx", AppError(code: .apiServerError, message: "500")),
            ("AppError 503", AppError(code: .apiServiceUnavailable, message: "503")),
            ("AppError generic", AppError(code: .apiGenericError, message: "418")),
            ("AppError invalid response", AppError(code: .apiInvalidResponse, message: "bad")),
            ("expired stored token", AppError(code: .sessionKeyExpired, message: "expired")),
            ("NSError", NSError(domain: "test", code: 401)),
        ]
    }

    private func usage(session: Double = 20, weekly: Double = 40, weeklyResetIn: TimeInterval = 86_400) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = Date().addingTimeInterval(3600)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = Date().addingTimeInterval(weeklyResetIn)
        u.lastUpdated = Date()
        return u
    }

    private func profile(_ name: String, reading: ClaudeUsage? = nil) -> Profile {
        var p = Profile(id: UUID(), name: name)
        p.claudeUsage = reading
        return p
    }

    /// A structurally healthy stored CLI login: unexpired access token plus a
    /// refresh token. Exactly the shape the old rule can never call dead.
    private var healthyCLICredentials: String {
        let expiresAtMs = Date().addingTimeInterval(4 * 3600).timeIntervalSince1970 * 1000
        let credentials: [String: Any] = ["claudeAiOauth": [
            "accessToken": "fixture-access", "refreshToken": "fixture-refresh", "expiresAt": expiresAtMs,
        ]]
        return String(data: try! JSONSerialization.data(withJSONObject: credentials), encoding: .utf8)!
    }

    private func signedIn(_ name: String, reading: ClaudeUsage) -> Profile {
        var p = profile(name, reading: reading)
        p.cliCredentialsJSON = healthyCLICredentials
        return p
    }

    private func markers(_ sessions: [String], at offsets: [TimeInterval], from base: Date) -> [FleetAuthFailureMarker] {
        zip(sessions, offsets).map { FleetAuthFailureMarker(at: base.addingTimeInterval($1), sessionId: $0) }
    }

    // MARK: - Detector A: two consecutive refusals

    func testOneUnauthorizedReadDoesNotCondemn() {
        let registry = ObservedDeadLogins()
        let id = UUID()
        let verdict = registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                                otherAccountSuccessAt: t0.addingTimeInterval(5), now: t0)
        XCTAssertNil(verdict)
        XCTAssertFalse(registry.isCondemned(id), "one refusal can be a blip racing a token refresh")
    }

    func testTwoConsecutiveUnauthorizedReadsCondemn() {
        let registry = ObservedDeadLogins()
        let id = UUID()
        registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                  otherAccountSuccessAt: nil, now: t0)
        let verdict = registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                                otherAccountSuccessAt: t0.addingTimeInterval(2),
                                                now: t0.addingTimeInterval(300))
        XCTAssertEqual(verdict?.evidence, .unauthorizedReads(2))
        XCTAssertTrue(registry.isCondemned(id))
    }

    func testASuccessBetweenRefusalsResetsTheRun() {
        let registry = ObservedDeadLogins()
        let id = UUID()
        let control = t0.addingTimeInterval(1)
        registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1, otherAccountSuccessAt: control, now: t0)
        registry.recordSuccessfulRead(id)
        XCTAssertNil(registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                               otherAccountSuccessAt: t0.addingTimeInterval(61),
                                               now: t0.addingTimeInterval(60)),
                     "the success ended the first run; this refusal starts a new one")
        XCTAssertFalse(registry.isCondemned(id))
        XCTAssertNotNil(registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                                  otherAccountSuccessAt: t0.addingTimeInterval(61),
                                                  now: t0.addingTimeInterval(120)),
                        "and the next consecutive refusal completes it")
    }

    /// THE dangerous direction. A 429, a DNS failure, a dropped network, a 5xx:
    /// none of them is evidence about a login, at any repetition count, and
    /// even with a control that says the endpoint is otherwise fine.
    func testRateLimitsNetworkAndDNSFailuresNeverCondemn() {
        for (label, error) in nonLoginFailures {
            let registry = ObservedDeadLogins()
            let id = UUID()
            XCTAssertFalse(ObservedDeadLogins.isLoginRefusal(error), label)
            for i in 0..<200 {
                let now = t0.addingTimeInterval(Double(i) * 30)
                XCTAssertNil(registry.recordFailedRead(id, error: error, credentialRevision: 1,
                                                       otherAccountSuccessAt: now.addingTimeInterval(1), now: now),
                             "\(label) #\(i) condemned a login")
            }
            XCTAssertFalse(registry.isCondemned(id), label)
        }
    }

    /// Nor can they complete a run someone else started: one real refusal
    /// followed by any number of 429s is still one refusal.
    func testNonLoginFailuresNeitherCountNorReset() {
        for (label, error) in nonLoginFailures {
            let registry = ObservedDeadLogins()
            let id = UUID()
            registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                      otherAccountSuccessAt: nil, now: t0)
            for i in 1...50 {
                registry.recordFailedRead(id, error: error, credentialRevision: 1,
                                          otherAccountSuccessAt: t0.addingTimeInterval(1),
                                          now: t0.addingTimeInterval(Double(i)))
            }
            XCTAssertFalse(registry.isCondemned(id), "\(label) counted as a refusal")
            XCTAssertNotNil(registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                                      otherAccountSuccessAt: t0.addingTimeInterval(1),
                                                      now: t0.addingTimeInterval(100)),
                            "\(label) reset the run: the second real refusal must still complete it")
        }
    }

    /// Control evidence: a refusal that every account gets (an endpoint
    /// change, a blocked surface) must not condemn any of them, or detector A
    /// would rotate the fleet through all 24 accounts.
    func testARunNeedsAnotherAccountToAnswerAfterItBegan() {
        let registry = ObservedDeadLogins()
        let id = UUID()
        registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                  otherAccountSuccessAt: t0.addingTimeInterval(-600), now: t0)
        XCTAssertNil(registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                               otherAccountSuccessAt: nil, now: t0.addingTimeInterval(300)),
                     "no other account has answered at all")
        XCTAssertNil(registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                               otherAccountSuccessAt: t0.addingTimeInterval(-1),
                                               now: t0.addingTimeInterval(600)),
                     "the last success predates the run, which proves nothing about the endpoint now")
        XCTAssertNotNil(registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                                  otherAccountSuccessAt: t0.addingTimeInterval(30),
                                                  now: t0.addingTimeInterval(900)),
                        "another account answered mid-run: the refusal follows THIS login")
    }

    /// A login that changed underneath the run (refresh, adoption, re-sync) is
    /// a different login: the old token's refusals do not carry over.
    func testANewStoredLoginStartsANewRun() {
        let registry = ObservedDeadLogins()
        let id = UUID()
        registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                  otherAccountSuccessAt: t0.addingTimeInterval(1), now: t0)
        XCTAssertNil(registry.recordFailedRead(id, error: unauthorized, credentialRevision: 2,
                                               otherAccountSuccessAt: t0.addingTimeInterval(1),
                                               now: t0.addingTimeInterval(30)),
                     "the refresh replaced the login: this is its first refusal")
        XCTAssertNotNil(registry.recordFailedRead(id, error: unauthorized, credentialRevision: 2,
                                                  otherAccountSuccessAt: t0.addingTimeInterval(31),
                                                  now: t0.addingTimeInterval(60)))
    }

    /// The caller notifies on a returned verdict, so one condemnation means
    /// one verdict, however many refusals follow it.
    func testACondemnationIsReportedOnceNotPerFailedRead() {
        let registry = ObservedDeadLogins()
        let id = UUID()
        let control = t0.addingTimeInterval(1)
        var verdicts = 0
        for i in 0..<20 {
            if registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                         otherAccountSuccessAt: control, now: t0.addingTimeInterval(Double(i))) != nil {
                verdicts += 1
            }
        }
        XCTAssertEqual(verdicts, 1)
        XCTAssertTrue(registry.isCondemned(id))
    }

    func testACondemnedLoginClearsOnTheNextSuccessfulRead() {
        let registry = ObservedDeadLogins()
        let id = UUID()
        let control = t0.addingTimeInterval(1)
        registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1, otherAccountSuccessAt: control, now: t0)
        registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1, otherAccountSuccessAt: control, now: t0.addingTimeInterval(5))
        XCTAssertTrue(registry.isCondemned(id))
        XCTAssertTrue(registry.recordSuccessfulRead(id), "the read that lifts a verdict says so")
        XCTAssertFalse(registry.isCondemned(id), "a login repaired with /login must return to rotation")
        XCTAssertFalse(registry.recordSuccessfulRead(id), "nothing left to lift")
        XCTAssertNil(registry.recordFailedRead(id, error: unauthorized, credentialRevision: 1,
                                               otherAccountSuccessAt: t0.addingTimeInterval(20),
                                               now: t0.addingTimeInterval(10)),
                     "and a later refusal starts from zero")
    }

    // MARK: - hasDeadLogin: the fingerprint-cache trap

    /// `ProfileCredentialStatusCache.entry(for:)` recomputes from a credentials
    /// fingerprint. A verdict written INTO that memo would be recomputed away.
    /// This one lives outside it and has to survive every recompute.
    func testTheVerdictSurvivesACredentialStatusRecompute() {
        waitForHydrationSettled()
        var atlas = profile("Atlas")
        atlas.cliCredentialsJSON = healthyCLICredentials

        XCTAssertFalse(ProfileCredentialStatusCache.hasDeadLogin(atlas),
                       "structurally perfect: the old rule can never call this login dead")
        guard case .valid = ProfileCredentialStatusCache.claudeTokenStatus(for: atlas) else {
            return XCTFail("fixture must read as a valid stored token")
        }

        let registry = ObservedDeadLogins.shared
        registry.recordFailedRead(atlas.id, error: unauthorized, credentialRevision: 0,
                                  otherAccountSuccessAt: t0.addingTimeInterval(1), now: t0)
        registry.recordFailedRead(atlas.id, error: unauthorized, credentialRevision: 0,
                                  otherAccountSuccessAt: t0.addingTimeInterval(1), now: t0.addingTimeInterval(5))
        XCTAssertTrue(ProfileCredentialStatusCache.hasDeadLogin(atlas), "the memoized entry must not hide the verdict")

        ProfileCredentialStatusCache.invalidateAll()
        XCTAssertTrue(ProfileCredentialStatusCache.hasDeadLogin(atlas), "survives a wholesale invalidation")

        atlas.createdAt = atlas.createdAt.addingTimeInterval(-86_400)  // a fingerprint input
        XCTAssertTrue(ProfileCredentialStatusCache.hasDeadLogin(atlas), "survives a fingerprint change")
        guard case .valid = ProfileCredentialStatusCache.claudeTokenStatus(for: atlas) else {
            return XCTFail("the recomputed entry still reads the token as valid — the verdict is not in it")
        }

        registry.recordSuccessfulRead(atlas.id)
        XCTAssertFalse(ProfileCredentialStatusCache.hasDeadLogin(atlas), "and lifts with the verdict")
    }

    // MARK: - Recovery: the active account moves, the candidate stays out

    func testACondemnedProfileIsNotASwitchCandidate() {
        let birch = profile("Birch", reading: usage(session: 10, weekly: 20))
        XCTAssertTrue(MenuBarManager.candidateHasHeadroom(
            birch, sessionThreshold: 95, weeklyThreshold: 99, ignoreFableWeekly: true, now: Date()))
        XCTAssertFalse(MenuBarManager.candidateHasHeadroom(
            birch, sessionThreshold: 95, weeklyThreshold: 99, ignoreFableWeekly: true,
            loginCondemned: true, now: Date()),
            "plenty of headroom on paper, none the fleet can use")
        XCTAssertFalse(MenuBarManager.candidateHasHeadroom(
            profile("Unmeasured"), sessionThreshold: 95, weeklyThreshold: 99, ignoreFableWeekly: false,
            loginCondemned: true, now: Date()),
            "no cached usage is 'assume available' — but not for a refused login")
    }

    /// The single most important test here: the end-to-end recovery. The
    /// active account reads 20 % (the numbers were never the problem), its
    /// login gets condemned, the trigger calls its turn over, and the walk,
    /// through the same predicates the live walk composes (per-profile
    /// rejection, ranking, `candidateHasHeadroom`), picks another account.
    func testACondemnedActiveAccountIsExhaustedAndTheWalkSelectsAnotherAccount() {
        let registry = ObservedDeadLogins.shared
        let atlas = signedIn("Atlas", reading: usage(session: 20, weekly: 35, weeklyResetIn: 1 * 86_400))
        let birch = signedIn("Birch", reading: usage(session: 10, weekly: 50, weeklyResetIn: 2 * 86_400))
        let cedar = signedIn("Cedar", reading: usage(session: 5, weekly: 10, weeklyResetIn: 3 * 86_400))
        let roster = [atlas, birch, cedar]
        let now = Date()

        func exhausted(_ p: Profile) -> Bool {
            MenuBarManager.isQuotaExhausted(p.claudeUsage!, sessionThreshold: 95, weeklyThreshold: 99,
                                            ignoreFableWeekly: true,
                                            loginCondemned: registry.isCondemned(p.id), now: now)
        }
        func walk(from active: Profile) -> Profile? {
            let eligible = roster.filter {
                $0.id != active.id && MenuBarManager.candidateRejection(
                    $0, provider: .claude, excluding: [active.id]) == nil
            }
            return MenuBarManager.rankAutoSwitchCandidates(eligible, customOrder: nil, now: now)
                .first { MenuBarManager.candidateHasHeadroom(
                    $0, sessionThreshold: 95, weeklyThreshold: 99, ignoreFableWeekly: true,
                    loginCondemned: registry.isCondemned($0.id), now: now) }
        }

        // Before: the trap. Healthy numbers, so no trigger, ever.
        XCTAssertFalse(exhausted(atlas), "a refused login generates no usage and never crosses a threshold")

        // Detector A condemns it (the path the sweep takes on two 401s).
        registry.recordFailedRead(atlas.id, error: unauthorized, credentialRevision: 3,
                                  otherAccountSuccessAt: now.addingTimeInterval(-10), now: now.addingTimeInterval(-60))
        registry.recordFailedRead(atlas.id, error: unauthorized, credentialRevision: 3,
                                  otherAccountSuccessAt: now.addingTimeInterval(-10), now: now)
        XCTAssertTrue(registry.isCondemned(atlas.id))

        XCTAssertTrue(exhausted(atlas), "the condemned active account's turn is over")
        XCTAssertEqual(walk(from: atlas)?.name, "Birch", "the walk moves the fleet to a healthy account")

        // A second condemned account is skipped the same way.
        registry.recordFailedRead(birch.id, error: unauthorized, credentialRevision: 1,
                                  otherAccountSuccessAt: now, now: now.addingTimeInterval(-60))
        registry.recordFailedRead(birch.id, error: unauthorized, credentialRevision: 1,
                                  otherAccountSuccessAt: now, now: now)
        XCTAssertEqual(walk(from: atlas)?.name, "Cedar")

        // And once the owner repairs Atlas with /login, the next read clears it.
        registry.recordSuccessfulRead(atlas.id)
        XCTAssertFalse(exhausted(atlas), "a repaired login is an ordinary account again")
    }

    /// The arm is a parameter defaulting to OFF (the `ignoreFableWeekly`
    /// pattern), so every caller that does not pass it behaves exactly as
    /// before, and a condemned login trips it whatever the numbers say.
    func testTheCondemnedArmDefaultsOffAndOverridesEveryReading() {
        let healthy = usage(session: 0, weekly: 0)
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(healthy, sessionThreshold: 95, weeklyThreshold: 99))
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(healthy, sessionThreshold: 95, weeklyThreshold: 99,
                                                      loginCondemned: true))
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(ClaudeUsage.empty, loginCondemned: true),
                      "no reading at all is still a refused login")
    }

    /// The mirror, over both flag states: the accounts the trigger keeps are
    /// exactly the accounts the walk will take, so a condemned login can
    /// neither strand the fleet nor ping-pong back in.
    func testTriggerAndCandidateFilterAgreeOnCondemnedLogins() {
        for condemned in [false, true] {
            for reading in [usage(session: 20, weekly: 40), usage(session: 96, weekly: 20), usage(session: 20, weekly: 99)] {
                let exhausted = MenuBarManager.isQuotaExhausted(
                    reading, sessionThreshold: 95, weeklyThreshold: 99, loginCondemned: condemned)
                let eligible = MenuBarManager.candidateHasHeadroom(
                    profile("mirror", reading: reading), sessionThreshold: 95, weeklyThreshold: 99,
                    ignoreFableWeekly: false, loginCondemned: condemned, now: Date())
                XCTAssertEqual(exhausted, !eligible, "condemned: \(condemned)")
            }
        }
    }

    // MARK: - Detector B: the fleet's verdict

    /// Establishes the owner epoch at `t0` so markers after the grace count.
    private func primedRegistry(owner: UUID, revision: Int = 1) -> ObservedDeadLogins {
        let registry = ObservedDeadLogins()
        XCTAssertEqual(registry.evaluateFleetMarkers([], ownerId: owner, ownerCredentialRevision: revision, now: t0), .none)
        return registry
    }

    func testThreeDistinctSessionsInsideTheWindowCondemnTheActiveLogin() {
        let owner = UUID()
        let registry = primedRegistry(owner: owner)
        let now = t0.addingTimeInterval(600)
        let outcome = registry.evaluateFleetMarkers(
            markers(["s1", "s2", "s3"], at: [-100, -50, -5], from: now),
            ownerId: owner, ownerCredentialRevision: 1, now: now)
        guard case .condemned(let verdict) = outcome else { return XCTFail("expected a condemnation, got \(outcome)") }
        XCTAssertEqual(verdict.evidence, .fleetAuthFailures(sessions: 3))
        XCTAssertTrue(registry.isCondemned(owner))
    }

    func testThreeLinesFromOneSessionDoNotCondemn() {
        let owner = UUID()
        let registry = primedRegistry(owner: owner)
        let now = t0.addingTimeInterval(600)
        let crashLoop = markers(Array(repeating: "s1", count: 40), at: (0..<40).map { -Double($0) * 2 }, from: now)
        XCTAssertEqual(registry.evaluateFleetMarkers(crashLoop, ownerId: owner, ownerCredentialRevision: 1, now: now), .none)
        XCTAssertEqual(registry.evaluateFleetMarkers(crashLoop + markers(["s2"], at: [-1], from: now),
                                                     ownerId: owner, ownerCredentialRevision: 1, now: now), .none,
                       "two sessions are still two")
        XCTAssertFalse(registry.isCondemned(owner))
    }

    func testMarkersOlderThanTheWindowAreIgnored() {
        let owner = UUID()
        let registry = primedRegistry(owner: owner)
        let now = t0.addingTimeInterval(3600)
        let stale = markers(["s1", "s2", "s3", "s4"], at: [-121, -300, -900, -3000], from: now)
        XCTAssertEqual(registry.evaluateFleetMarkers(stale, ownerId: owner, ownerCredentialRevision: 1, now: now), .none)
        let farFuture = markers(["f1", "f2", "f3"], at: [3600, 7200, 86_400], from: now)
        XCTAssertEqual(registry.evaluateFleetMarkers(farFuture, ownerId: owner, ownerCredentialRevision: 1, now: now), .none,
                       "markers stamped far in the future are junk")
        let anonymous = markers(["", "", ""], at: [-3, -2, -1], from: now)
        XCTAssertEqual(registry.evaluateFleetMarkers(anonymous, ownerId: owner, ownerCredentialRevision: 1, now: now), .none,
                       "no session id, no distinct session")
        XCTAssertFalse(registry.isCondemned(owner))
    }

    /// Running sessions finish their in-flight turns on the login that was
    /// just replaced. Their failures belong to that login, not the new owner.
    func testFailuresRightAfterTheActiveLoginChangesBelongToThePreviousLogin() {
        let atlas = UUID(), birch = UUID()
        let registry = primedRegistry(owner: atlas)
        let switchedAt = t0.addingTimeInterval(1000)
        // First look at the new owner: the epoch starts now.
        XCTAssertEqual(registry.evaluateFleetMarkers([], ownerId: birch, ownerCredentialRevision: 7, now: switchedAt), .none)

        let tail = markers(["s1", "s2", "s3", "s4"], at: [5, 20, 60, 110], from: switchedAt)
        XCTAssertEqual(registry.evaluateFleetMarkers(tail, ownerId: birch, ownerCredentialRevision: 7,
                                                     now: switchedAt.addingTimeInterval(115)), .none)
        XCTAssertFalse(registry.isCondemned(birch), "the grace must hold, or the fleet cascades account to account")

        let fresh = markers(["s5", "s6", "s7"], at: [130, 150, 170], from: switchedAt)
        guard case .condemned = registry.evaluateFleetMarkers(tail + fresh, ownerId: birch, ownerCredentialRevision: 7,
                                                              now: switchedAt.addingTimeInterval(180)) else {
            return XCTFail("failures after the grace belong to the new login")
        }
    }

    /// `/login` on the SAME account writes a new token: its predecessor's
    /// failures must not condemn the login that just repaired it.
    func testANewTokenForTheSameOwnerRestartsTheGrace() {
        let owner = UUID()
        let registry = primedRegistry(owner: owner, revision: 1)
        let repairedAt = t0.addingTimeInterval(1000)
        let beforeRepair = markers(["s1", "s2", "s3"], at: [-60, -30, -10], from: repairedAt)
        XCTAssertEqual(registry.evaluateFleetMarkers(beforeRepair, ownerId: owner, ownerCredentialRevision: 2, now: repairedAt), .none)
        XCTAssertFalse(registry.isCondemned(owner))
    }

    func testTheSameMarkersNeverCondemnTwice() {
        let owner = UUID()
        let registry = primedRegistry(owner: owner)
        let now = t0.addingTimeInterval(600)
        let wave = markers(["s1", "s2", "s3"], at: [-30, -20, -10], from: now)
        guard case .condemned = registry.evaluateFleetMarkers(wave, ownerId: owner, ownerCredentialRevision: 1, now: now) else {
            return XCTFail("the first wave condemns")
        }
        registry.recordSuccessfulRead(owner)
        XCTAssertEqual(registry.evaluateFleetMarkers(wave, ownerId: owner, ownerCredentialRevision: 1,
                                                     now: now.addingTimeInterval(30)), .none,
                       "lines already acted on are not new evidence (one notification per condemnation)")
        let secondWave = markers(["s4", "s5", "s6"], at: [40, 45, 50], from: now)
        guard case .condemned = registry.evaluateFleetMarkers(wave + secondWave, ownerId: owner, ownerCredentialRevision: 1,
                                                              now: now.addingTimeInterval(60)) else {
            return XCTFail("new sessions failing again are new evidence")
        }
    }

    /// If every login the fleet moves to fails the same way, the failures are
    /// not about any one login. Stop after three instead of rotating through
    /// 24 accounts, and say so once.
    func testTheBreakerStopsARotationCascadeAndAnnouncesOnce() {
        let registry = ObservedDeadLogins()
        var clock = t0
        func condemnNewOwner(_ label: String) -> ObservedDeadLogins.FleetOutcome {
            let owner = UUID()
            _ = registry.evaluateFleetMarkers([], ownerId: owner, ownerCredentialRevision: 1, now: clock)
            clock = clock.addingTimeInterval(ObservedDeadLogins.fleetOwnerGrace + 10)
            let wave = markers(["\(label)-1", "\(label)-2", "\(label)-3"], at: [-8, -6, -4], from: clock)
            return registry.evaluateFleetMarkers(wave, ownerId: owner, ownerCredentialRevision: 1, now: clock)
        }
        for label in ["a", "b", "c"] {
            guard case .condemned = condemnNewOwner(label) else { return XCTFail("\(label) should be condemned") }
        }
        XCTAssertEqual(condemnNewOwner("d"), .breakerTripped)
        XCTAssertEqual(condemnNewOwner("e"), .suppressed, "announced once per trip")
        clock = clock.addingTimeInterval(ObservedDeadLogins.fleetBreakerWindow)
        guard case .condemned = condemnNewOwner("f") else {
            return XCTFail("the breaker closes once the window has passed")
        }
    }

    // MARK: - The StopFailure journal

    /// The hook's closed `error` enum, as shipped in the CLI binary.
    private let stopFailureErrors = [
        "authentication_failed", "oauth_org_not_allowed", "account_on_hold", "verification_required",
        "billing_error", "rate_limit", "overloaded", "invalid_request", "model_not_found",
        "server_error", "unknown", "max_output_tokens", "cloud_credential_error",
    ]

    private func journalLine(ts: TimeInterval, session: String, error: String = "authentication_failed") -> String {
        #"{"ts":\#(Int(ts)),"session_id":"\#(session)","cwd":"/Users/x/Personal Projects/repo","error":"\#(error)"}"#
    }

    func testJournalLinesBecomeMarkers() {
        let data = Data([
            journalLine(ts: 1_790_000_100, session: "s1"),
            journalLine(ts: 1_790_000_101, session: "s2"),
            "",
            journalLine(ts: 1_790_000_102, session: "s1"),
        ].joined(separator: "\n").utf8)
        let parsed = StopFailureJournal.parse(data)
        XCTAssertEqual(parsed, [
            FleetAuthFailureMarker(at: Date(timeIntervalSince1970: 1_790_000_100), sessionId: "s1"),
            FleetAuthFailureMarker(at: Date(timeIntervalSince1970: 1_790_000_101), sessionId: "s2"),
            FleetAuthFailureMarker(at: Date(timeIntervalSince1970: 1_790_000_102), sessionId: "s1"),
        ])
    }

    /// Every `StopFailure.error` value but one is ignored, from the journal and
    /// from the transcripts alike. `rate_limit` is normal operation and
    /// `overloaded` is a 529 that wants a retry.
    func testEveryOtherStopFailureErrorIsIgnored() {
        for error in stopFailureErrors {
            let journal = StopFailureJournal.parse(Data(journalLine(ts: 1_790_000_100, session: "s", error: error).utf8))
            let transcript = LocalLimitSignalService.authFailureMarker(
                fromLine: Substring(#"{"type":"assistant","error":"\#(error)","isApiErrorMessage":true,"sessionId":"s","timestamp":"2026-09-24T10:31:45.703Z"}"#),
                since: .distantPast)
            if error == "authentication_failed" {
                XCTAssertEqual(journal.count, 1, error)
                XCTAssertNotNil(transcript, error)
            } else {
                XCTAssertTrue(journal.isEmpty, "\(error) must not be journal evidence")
                XCTAssertNil(transcript, "\(error) must not be transcript evidence")
            }
        }
    }

    func testAMalformedJournalIsIgnoredNotACrash() {
        let valid = journalLine(ts: 1_790_000_100, session: "ok")
        let junk: [String] = [
            "not json at all",
            #"{"ts":1790000100,"session_id":"s","error":"authentication_failed""#,  // truncated
            #"{"ts":"1790000100","session_id":"s","error":"authentication_failed"}"#,  // ts as string
            #"{"ts":1790000100,"session_id":42,"error":"authentication_failed"}"#,  // id as number
            #"{"ts":1790000100,"session_id":"","error":"authentication_failed"}"#,  // empty id
            #"{"ts":1790000100,"error":"authentication_failed"}"#,  // no id
            #"{"session_id":"s","error":"authentication_failed"}"#,  // no ts
            #"{"ts":-5,"session_id":"s","error":"authentication_failed"}"#,  // negative ts
            #"["ts",1790000100,"authentication_failed"]"#,  // not an object
            #"{"ts":1790000100,"session_id":"s","error":"authentication_failed","pad":"\#(String(repeating: "x", count: 5000))"}"#,  // oversized line
        ]
        var bytes = Data(((junk + [valid]).joined(separator: "\n") + "\n").utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0x00, 0x0A, 0xC3, 0x28, 0x0A])  // invalid UTF-8 lines
        let parsed = StopFailureJournal.parse(bytes)
        XCTAssertEqual(parsed.map(\.sessionId), ["ok"], "only the one well-formed line survives")
        XCTAssertTrue(StopFailureJournal.parse(Data(repeating: 0xAB, count: 200_000)).isEmpty)
        XCTAssertTrue(StopFailureJournal.parse(Data()).isEmpty)
    }

    func testAnOversizedJournalIsTailReadAndAMissingOneIsEmpty() throws {
        XCTAssertTrue(StopFailureJournal.read(at: tempDir.appendingPathComponent("absent.jsonl")).isEmpty)

        let url = tempDir.appendingPathComponent("stop-failures.jsonl")
        var body = String(repeating: journalLine(ts: 1_700_000_000, session: "ancient") + "\n", count: 20_000)
        body += "garbage line\n"
        body += journalLine(ts: 1_790_000_100, session: "recent-1") + "\n"
        body += journalLine(ts: 1_790_000_101, session: "recent-2") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int, 1_000_000)

        let parsed = StopFailureJournal.read(at: url, maxBytes: 2_048)
        XCTAssertEqual(parsed.suffix(2).map(\.sessionId), ["recent-1", "recent-2"])
        XCTAssertLessThanOrEqual(parsed.count, 2_048 / 100, "only the tail was read")
        XCTAssertTrue(parsed.allSatisfy { !$0.sessionId.contains("\"") }, "the cut first line was dropped, not misparsed")
    }

    /// The hook script itself, end to end: it appends only for
    /// `authentication_failed`, escapes what it copies, and the reader reads
    /// what it wrote.
    func testTheHookScriptJournalsOnlyAuthenticationFailures() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/hooks/cuw-stop-failure.sh")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script.path), "hook script not found at \(script.path)")
        let journal = tempDir.appendingPathComponent("nested dir/stop-failures.jsonl")

        func run(_ payload: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            process.environment = ["CUW_STOP_FAILURE_JOURNAL": journal.path, "HOME": tempDir.path, "PATH": "/usr/bin:/bin"]
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            stdin.fileHandleForWriting.write(Data(payload.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        for (index, error) in stopFailureErrors.enumerated() {
            try run(#"{"hook_event_name":"StopFailure","session_id":"s-\#(index)","cwd":"/Users/x/a \"q\" b","error":"\#(error)","last_assistant_message":"it said \"error\":\"authentication_failed\""}"#)
        }
        let markers = StopFailureJournal.read(at: journal)
        XCTAssertEqual(markers.map(\.sessionId), ["s-0"], "one line, for the one error that is evidence")
        XCTAssertLessThan(abs(markers.first?.at.timeIntervalSinceNow ?? .infinity), 60)
        let written = try String(contentsOf: journal, encoding: .utf8)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(written.utf8)), "the escaped cwd keeps the line valid JSON")
    }

    // MARK: - The transcript feed

    /// The CLI writes the same failure into the session transcript
    /// (2026-09-24 10:31:45Z: "Login expired · Please run /login"). The
    /// tripwire's single walk returns it next to the rate-limit deaths.
    func testTheTranscriptWalkReturnsAuthFailuresBesideRateLimits() throws {
        let project = tempDir.appendingPathComponent("projects/-Users-x-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"why does it say \"error\":\"authentication_failed\"?"},"sessionId":"quoted","timestamp":"2026-09-24T10:31:40.000Z"}"#,
            #"{"type":"assistant","error":"authentication_failed","isApiErrorMessage":true,"sessionId":"s-a","timestamp":"2026-09-24T10:31:45.703Z","message":{"content":[{"type":"text","text":"Login expired · Please run /login"}]}}"#,
            #"{"type":"assistant","error":"authentication_failed","isApiErrorMessage":true,"session_id":"s-b","timestamp":"2026-09-24T10:31:50Z","message":{"content":[{"type":"text","text":"Login expired · Please run /login"}]}}"#,
            #"{"type":"assistant","error":"rate_limit","apiErrorStatus":429,"sessionId":"s-c","timestamp":"2026-09-24T10:32:00.000Z","message":{"content":[{"type":"text","text":"You've hit your session limit · resets 1:50pm (America/Los_Angeles)"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: project.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let signals = LocalLimitSignalService.scanTranscriptSignals(
            since: ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z")!,
            root: tempDir.appendingPathComponent("projects").path)
        XCTAssertEqual(signals.authFailures.map(\.sessionId), ["s-a", "s-b"],
                       "the CLI's own top-level error only, never a quoted phrase")
        XCTAssertEqual(signals.rateLimits.count, 1, "rate-limit deaths still come back from the same walk")
    }

    // MARK: - Notification

    func testTheCondemnationNoticeIsOneDeliveryPerSend() {
        let manager = NotificationManager.shared
        manager.resetDeliveryRecordsForTesting()
        manager.sendClaudeLoginRejectedNotification(profileName: "Atlas", isActive: true)
        XCTAssertEqual(manager.recentDeliveries.map(\.identifier), ["claude_login_rejected_Atlas"])
        manager.resetDeliveryRecordsForTesting()
    }

    // MARK: - Helpers

    private func waitForHydrationSettled(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while ProfileStore.shared.credentialHydrationState == .loading, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
