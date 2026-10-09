//
//  ClaudeLoginRotationTests.swift
//  Claude UsageTests
//
//  The widget killed the Claude login it had just handed to the CLI.
//
//  Two healthy accounts died within seconds of becoming active, eight hours
//  apart (2026-10-08/09). Each time the switch applied the target's stored
//  token pair to the CLI, and the 90 % candidate preflight — the same reading
//  that fired the switch — then redeemed that pair's refresh token. Redeeming
//  a Claude refresh token revokes the access token issued with it at once, so
//  every running session failed within three seconds, and the CLI's own retry
//  presented the consumed refresh token and wrote its "login expired" marker.
//  The rotated pair existed only in the widget's profile store.
//
//  Isolation: the CLI's credential store, the token endpoint and the identity
//  endpoint are replaced through `ClaudeCodeSyncService`'s test seams, so no
//  test reads or writes the real Keychain item or `~/.claude/.credentials.json`
//  and no refresh token is ever redeemed. Profiles, pointers and the dead-login
//  flags are restored the way `ProfileActivationTests` restores them.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class ClaudeLoginRotationTests: XCTestCase {

    private let profilesKey = "profiles_v3"
    private let activeProfileKey = "activeProfileId"
    private let store = ProfileStore.shared
    private let manager = ProfileManager.shared
    private let sync = ClaudeCodeSyncService.shared
    private var defaults: UserDefaults { ProfileStoreUsagePatchTests.testDefaults }

    private var savedProfilesData: Data?
    private var savedActiveProfileId: String?
    private var savedManagerProfiles: [Profile] = []
    private var savedActiveProfile: Profile?
    private var savedActiveClaudeProfileId: UUID?
    private var savedActiveCodexProfileId: UUID?
    private var savedActiveGrokProfileId: UUID?
    private var testProfileIDs: [UUID] = []

    private var cliStore = FakeCLIStore()
    private var endpoint = FakeTokenEndpoint()

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        // Seams first: everything below, including the app's own passes that
        // the hydration wait lets run, sees the stand-ins and never the real
        // CLI store, token endpoint or identity endpoint.
        cliStore = FakeCLIStore()
        endpoint = FakeTokenEndpoint()
        let cliStore = cliStore
        let endpoint = endpoint
        sync.setCLIStoreForTesting(ClaudeCodeSyncService.CLIStoreSeams(
            readHalves: { cliStore.halves() },
            writeKeychain: { cliStore.writeKeychain($0) },
            writeFile: { cliStore.writeFile($0) }
        ))
        sync.setTokenEndpointForTesting { await endpoint.redeem($0) }
        // Every synthetic token is "<account>-access-…"; the account is its prefix.
        sync.setIdentityFetcherForTesting { token in
            guard let account = token.components(separatedBy: "-access").first, account != token else { return nil }
            return ClaudeCodeSyncService.AccountIdentity(
                accountUUID: "acct-\(account)", organizationUUID: "", email: ""
            )
        }

        // The launch Keychain warm-up finishing mid-test re-runs the owner
        // inference (a pointer on a credential-less profile is cleared and the
        // sole credentialed profile claims the login), which would move
        // ownership under these tests. Let it settle first.
        let deadline = Date().addingTimeInterval(10)
        while store.credentialHydrationState == .loading, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        savedProfilesData = defaults.data(forKey: profilesKey)
        savedActiveProfileId = defaults.string(forKey: activeProfileKey)
        savedManagerProfiles = manager.profiles
        savedActiveProfile = manager.activeProfile
        savedActiveClaudeProfileId = manager.activeClaudeProfileId
        savedActiveCodexProfileId = manager.activeCodexProfileId
        savedActiveGrokProfileId = manager.activeGrokProfileId
        manager.flushPendingUsage()
        testProfileIDs = []
    }

    override func tearDown() async throws {
        // Let the identity stamp the apply spawns finish against the seams.
        for _ in 0..<5 { await Task.yield() }
        manager.flushPendingUsage()
        for id in testProfileIDs {
            sync.markLoginRevived(id)
            store.deleteProfileCredentials(profileId: id)
        }
        if let savedProfilesData {
            defaults.set(savedProfilesData, forKey: profilesKey)
        } else {
            defaults.removeObject(forKey: profilesKey)
        }
        if let savedActiveProfileId {
            defaults.set(savedActiveProfileId, forKey: activeProfileKey)
        } else {
            defaults.removeObject(forKey: activeProfileKey)
        }
        store.saveActiveClaudeProfileId(savedActiveClaudeProfileId)
        store.saveActiveCodexProfileId(savedActiveCodexProfileId)
        store.saveActiveGrokProfileId(savedActiveGrokProfileId)
        if savedProfilesData != nil {
            manager.loadProfiles()
        } else {
            manager.profiles = savedManagerProfiles
            manager.activeProfile = savedActiveProfile
        }
        testProfileIDs = []
        // A fresh empty CLI stand-in, and endpoints that answer "unavailable"
        // rather than nil: an identity stamp still in flight from this test
        // must not land on the default refusal and fail whichever test runs
        // next (RealStoreTouchObserver).
        sync.setCLIStoreForTesting(nil)
        sync.setTokenEndpointForTesting { _ in (503, nil) }
        sync.setIdentityFetcherForTesting { _ in nil }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A synthetic Claude Code login. `account` names the account (the
    /// identity seam reads it back out of the access token); `generation`
    /// tells two pairs of one account apart.
    private func login(
        _ account: String,
        generation: Int = 1,
        expiresIn: TimeInterval,
        deadlineIn: TimeInterval? = nil,
        refreshToken: Bool = true
    ) -> String {
        var oauth: [String: Any] = [
            "accessToken": "\(account)-access-\(generation)",
            "expiresAt": Int((Date().timeIntervalSince1970 + expiresIn) * 1000),
            "subscriptionType": "max"
        ]
        if refreshToken { oauth["refreshToken"] = "\(account)-refresh-\(generation)" }
        if let deadlineIn {
            oauth["refreshTokenExpiresAt"] = Int((Date().timeIntervalSince1970 + deadlineIn) * 1000)
        }
        let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func profile(_ name: String, login json: String?) -> Profile {
        var profile = Profile(id: UUID(), name: name)
        profile.cliCredentialsJSON = json
        return profile
    }

    private func seed(_ profiles: [Profile], focused: UUID) {
        testProfileIDs = profiles.map(\.id)
        store.saveProfiles(profiles)
        manager.profiles = store.loadProfiles()
        manager.activeProfile = manager.profiles.first(where: { $0.id == focused })
        store.saveActiveProfileId(focused)
    }

    private func storedLogin(_ id: UUID) -> String? {
        store.loadProfiles().first(where: { $0.id == id })?.cliCredentialsJSON
    }

    private func refreshToken(_ json: String?) -> String? {
        json.flatMap(sync.extractRefreshToken(from:))
    }

    // MARK: - Regression: apply, then a preflight on the same profile

    /// The 2026-10-08/09 ordering, replayed. The target's access token has 40 minutes
    /// left: above the old 2-minute pre-apply window (so the switch applied the
    /// pair as stored) and below the preflight's one-hour window (so the
    /// preflight redeemed it right after). Before the fix the CLI ended up
    /// holding a refresh token the widget had already redeemed, with the only
    /// live pair stored in the widget's profile.
    func testAPreflightRightAfterTheSwitchNeverRotatesTheLoginTheCLIWasHanded() async {
        let outgoing = profile("outgoing", login: login("outgoing", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400))
        let target = profile("target", login: login("target", expiresIn: 40 * 60, deadlineIn: 20 * 86_400))
        seed([outgoing, target], focused: outgoing.id)
        cliStore.set(keychain: outgoing.cliCredentialsJSON, file: outgoing.cliCredentialsJSON)
        manager.claimActiveClaudeOwnership(outgoing.id)

        let outcome = await manager.activateProfileDetailed(target.id, userInitiated: false)
        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(manager.activeClaudeProfileId, target.id)

        // The preflight's own call, exactly as `preflightCandidates` makes it.
        _ = await sync.ensureFreshCredentials(
            for: target.id, adoptSystemKeychain: false, freshFor: 3600
        )

        let cliRefresh = refreshToken(cliStore.keychain)
        XCTAssertNotNil(cliRefresh)
        XCTAssertFalse(endpoint.redeemed.contains(cliRefresh ?? ""),
                       "the CLI holds a refresh token the widget already redeemed — every session dies at its next request")
        XCTAssertEqual(cliRefresh, refreshToken(storedLogin(target.id)),
                       "the CLI and the profile must hold the same live pair")
    }

    // MARK: - Invariant 1: renew before the hand-off, never after

    /// Under an hour left: the switch renews FIRST, and the pair written to the
    /// CLI is the renewed one. The consumed pair never reaches the CLI.
    func testASwitchRenewsALoginWithUnderAnHourLeftBeforeApplyingIt() async {
        let outgoing = profile("outgoing", login: nil)
        let target = profile("target", login: login("target", expiresIn: 50 * 60, deadlineIn: 20 * 86_400))
        seed([outgoing, target], focused: outgoing.id)
        manager.claimActiveClaudeOwnership(outgoing.id)

        let outcome = await manager.activateProfileDetailed(target.id, userInitiated: false)

        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(endpoint.redeemed, ["target-refresh-1"], "renewed once, before the apply")
        XCTAssertEqual(cliStore.writes.map { refreshToken($0) }, ["target-refresh-2"],
                       "the CLI is written once, with the renewed pair — never the one just redeemed")
        XCTAssertEqual(refreshToken(storedLogin(target.id)), "target-refresh-2")
    }

    /// Over an hour left: nothing to renew, the stored pair is applied as is.
    func testASwitchAppliesALoginWithOverAnHourLeftWithoutRenewingIt() async {
        let outgoing = profile("outgoing", login: nil)
        let target = profile("target", login: login("target", expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
        seed([outgoing, target], focused: outgoing.id)
        manager.claimActiveClaudeOwnership(outgoing.id)

        let outcome = await manager.activateProfileDetailed(target.id, userInitiated: false)

        XCTAssertEqual(outcome, .activated)
        XCTAssertTrue(endpoint.redeemed.isEmpty)
        XCTAssertEqual(refreshToken(cliStore.keychain), "target-refresh-1")
    }

    /// The other interleaving of the same race (2026-10-02): the preflight is
    /// already redeeming when the switch reaches its renewal step. The switch
    /// must WAIT for that redemption and apply its result — it used to find the
    /// mutex taken, treat that as "nothing to do", and apply the pair being
    /// consumed.
    func testAHandOffWaitsForARedemptionInFlightAndAppliesItsResult() async {
        let outgoing = profile("outgoing", login: nil)
        let target = profile("target", login: login("target", expiresIn: 30 * 60, deadlineIn: 20 * 86_400))
        seed([outgoing, target], focused: outgoing.id)
        manager.claimActiveClaudeOwnership(outgoing.id)

        var activation: Task<ProfileManager.ActivationOutcome, Never>?
        var parked = false
        var appliedWhileParked = true
        let manager = manager
        let sync = sync
        let cliStore = cliStore
        endpoint.onRedeem = {
            guard activation == nil else { return }
            activation = Task { await manager.activateProfileDetailed(target.id, userInitiated: false) }
            // Hand the main actor to the switch until it is observably parked
            // on this redemption (bounded, so a regression fails, not hangs).
            for _ in 0..<1_000 where !sync.isHandoffParkedForTesting(target.id) { await Task.yield() }
            parked = sync.isHandoffParkedForTesting(target.id)
            appliedWhileParked = !cliStore.writes.isEmpty
        }

        // The preflight starts redeeming first …
        _ = await sync.ensureFreshCredentials(
            for: target.id, adoptSystemKeychain: false,
            freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        // … and the switch lands only after it.
        let outcome = await activation?.value

        XCTAssertEqual(outcome, .activated)
        XCTAssertTrue(parked, "the switch parks on the redemption in flight instead of skipping it")
        XCTAssertFalse(appliedWhileParked, "and applies nothing while it is parked")
        XCTAssertEqual(endpoint.redeemed, ["target-refresh-1"], "one redemption; the switch reused its result")
        XCTAssertFalse(cliStore.writes.isEmpty)
        XCTAssertTrue(cliStore.writes.allSatisfy { refreshToken($0) == "target-refresh-2" },
                      "the CLI only ever receives the rotated pair, never the one being consumed")
    }

    /// The preflight never redeems the provider owner's login, even when the
    /// owner is the candidate it was asked to validate and has under an hour.
    func testThePreflightDoesNotRedeemTheOwnersLogin() async {
        let owner = profile("owner", login: login("owner", expiresIn: 30 * 60, deadlineIn: 20 * 86_400))
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        seed([owner, other], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        cliStore.set(keychain: owner.cliCredentialsJSON, file: owner.cliCredentialsJSON)

        let changed = await sync.ensureFreshCredentials(
            for: owner.id, adoptSystemKeychain: false,
            freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertFalse(changed)
        XCTAssertTrue(endpoint.redeemed.isEmpty, "redeeming the owner revokes the access token every session is using")
        XCTAssertEqual(storedLogin(owner.id), owner.cliCredentialsJSON)
    }

    /// Nor the login an activation is handing over right now.
    func testThePreflightDoesNotRedeemALoginBeingHandedOver() async {
        let target = profile("target", login: login("target", expiresIn: 30 * 60, deadlineIn: 20 * 86_400))
        let owner = profile("owner", login: login("owner", expiresIn: 6 * 3600))
        seed([owner, target], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)

        sync.beginHandoff(target.id)
        defer { sync.endHandoff(target.id) }
        let changed = await sync.ensureFreshCredentials(
            for: target.id, adoptSystemKeychain: false,
            freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertFalse(changed)
        XCTAssertTrue(endpoint.redeemed.isEmpty)
    }

    /// THE INVARIANT: never redeem a refresh token the CLI's store holds,
    /// whoever the pointer names. It covers a profile that shares the owner's
    /// login, a stale pointer, and ownership that moved after any other check,
    /// and either half of the store counts (the CLI falls back to the file).
    func testNoProfileRedeemsARefreshTokenTheCLIStoreHolds() async {
        let shared = login("shared", expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let pointerOwner = profile("pointer-owner", login: login("pointer", expiresIn: 6 * 3600))
        let holder = profile("holder", login: shared)
        seed([pointerOwner, holder], focused: pointerOwner.id)
        manager.claimActiveClaudeOwnership(pointerOwner.id)

        for (keychain, file) in [(shared, nil), (nil, shared), (pointerOwner.cliCredentialsJSON, shared)] as [(String?, String?)] {
            cliStore.set(keychain: keychain, file: file)
            let changed = await sync.ensureFreshCredentials(
                for: holder.id, adoptSystemKeychain: false,
                freshFor: ClaudeRefreshPolicy.handoffFreshness
            )
            XCTAssertFalse(changed)
        }
        XCTAssertTrue(endpoint.redeemed.isEmpty, "the pointer names someone else, but the CLI holds this token")

        cliStore.set(keychain: pointerOwner.cliCredentialsJSON, file: pointerOwner.cliCredentialsJSON)
        let changed = await sync.ensureFreshCredentials(
            for: holder.id, adoptSystemKeychain: false,
            freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        XCTAssertTrue(changed, "once the CLI no longer holds it, it is an ordinary background login")
        XCTAssertEqual(endpoint.redeemed, ["shared-refresh-1"])
    }

    /// The repair: if the CLI's store ends up holding the very token a
    /// redemption just consumed (a hand-over that did not wait), the CLI is
    /// handed the rotated successor of its own login.
    func testARefreshThatFinishesAfterTheCLIWasHandedItsLoginRepairsTheCLI() async {
        let target = profile("target", login: login("target", expiresIn: 30 * 60, deadlineIn: 20 * 86_400))
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        seed([other, target], focused: other.id)
        manager.claimActiveClaudeOwnership(other.id)
        cliStore.set(keychain: other.cliCredentialsJSON, file: other.cliCredentialsJSON)
        let manager = manager
        let cliStore = cliStore
        endpoint.onRedeem = {
            // A switch lands while the request is in flight.
            cliStore.write(target.cliCredentialsJSON!)
            manager.claimActiveClaudeOwnership(target.id)
        }

        let changed = await sync.ensureFreshCredentials(
            for: target.id, adoptSystemKeychain: false,
            freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(refreshToken(cliStore.keychain), "target-refresh-2",
                       "the CLI held the consumed token, so it gets that login's rotated pair")
    }

    /// And never otherwise: a redemption that finishes after the CLI moved to
    /// another login leaves that login alone.
    func testARefreshNeverWritesOverAnotherLoginInTheCLI() async {
        let target = profile("target", login: login("target", expiresIn: 30 * 60, deadlineIn: 20 * 86_400))
        let next = profile("next", login: login("next", expiresIn: 6 * 3600))
        seed([next, target], focused: next.id)
        cliStore.set(keychain: nil, file: nil)
        let manager = manager
        let cliStore = cliStore
        endpoint.onRedeem = {
            cliStore.write(next.cliCredentialsJSON!)
            manager.claimActiveClaudeOwnership(next.id)
        }

        let changed = await sync.ensureFreshCredentials(
            for: target.id, adoptSystemKeychain: false,
            freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(refreshToken(cliStore.keychain), "next-refresh-1", "the CLI's own login stays")
        XCTAssertEqual(refreshToken(storedLogin(target.id)), "target-refresh-2", "the rotated pair is kept in its profile")
    }

    /// The sweep never redeems the owner, not even in its last two minutes:
    /// the CLI process may be redeeming the same token right then. It adopts
    /// the CLI's own rotation instead; with none yet, usage goes stale.
    func testTheSweepNeverRedeemsTheOwnerAndAdoptsTheCLIsRotation() async {
        let owner = profile("owner", login: login("owner", expiresIn: 60, deadlineIn: 20 * 86_400))
        seed([owner], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        cliStore.set(keychain: owner.cliCredentialsJSON, file: owner.cliCredentialsJSON)

        let untouched = await sync.ensureFreshCredentials(for: owner.id, adoptSystemKeychain: true)
        XCTAssertFalse(untouched)
        XCTAssertTrue(endpoint.redeemed.isEmpty)
        XCTAssertEqual(storedLogin(owner.id), owner.cliCredentialsJSON)

        // The CLI refreshes its own login …
        let rotated = login("owner", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        cliStore.set(keychain: rotated, file: owner.cliCredentialsJSON)
        let adopted = await sync.ensureFreshCredentials(for: owner.id, adoptSystemKeychain: true)
        XCTAssertTrue(adopted, "… and the profile adopts the newer pair")
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "owner-refresh-2")
        XCTAssertTrue(endpoint.redeemed.isEmpty)
    }

    /// The redemption's own save is an explicit replacement: it just consumed
    /// the stored pair, so the rotated one is kept even when the server
    /// returns a SHORTER lifetime than the pair it replaced.
    func testARotationIsStoredEvenWhenTheServerShortensTheLifetime() async {
        let account = profile("account", login: login("account", expiresIn: 40 * 60, deadlineIn: 20 * 86_400))
        seed([account], focused: account.id)
        endpoint.extraPayload = ["expires_in": 600.0]

        let changed = await sync.ensureFreshCredentials(
            for: account.id, adoptSystemKeychain: false,
            freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-2",
                       "keeping the cached pair would keep a consumed refresh token")
    }

    func testRedemptionPolicy() {
        typealias P = ClaudeRefreshPolicy
        func decide(_ timeLeft: TimeInterval, freshFor: TimeInterval = P.handoffFreshness, canRedeem: Bool = true,
                    held: Bool? = false, owns: Bool = false, handoff: Bool = false,
                    role: P.Role = .maintenance) -> P.Decision {
            P.decide(timeLeft: timeLeft, freshFor: freshFor, canRedeem: canRedeem, cliHoldsThisLogin: held,
                     ownsCLILogin: owns, handoffInFlight: handoff, role: role)
        }
        XCTAssertEqual(decide(2 * 3600), .notNeeded)
        XCTAssertEqual(decide(30 * 60, canRedeem: false), .notNeeded, "no refresh token, or flagged dead")
        XCTAssertEqual(decide(30 * 60), .redeem, "an idle login the CLI does not hold")
        XCTAssertEqual(decide(30 * 60, held: true), .refuseHandedOff, "the CLI's store holds this token")
        XCTAssertEqual(decide(30 * 60, held: nil), .refuseHandedOff, "the store could not be read: fail closed")
        XCTAssertEqual(decide(30 * 60, owns: true), .refuseHandedOff, "the pointer's owner")
        XCTAssertEqual(decide(60, freshFor: P.healWindow, owns: true), .refuseHandedOff,
                       "not even in the owner's last two minutes")
        XCTAssertEqual(decide(30 * 60, handoff: true), .refuseHandedOff, "a maintenance caller during a hand-off")
        XCTAssertEqual(decide(30 * 60, handoff: true, role: .handoff), .redeem, "the hand-off renewing its own login")
        XCTAssertEqual(decide(30 * 60, held: true, handoff: true, role: .handoff), .refuseHandedOff,
                       "a hand-off of a login the CLI already holds")
        XCTAssertEqual(decide(30 * 60, owns: true, handoff: true, role: .handoff), .refuseHandedOff,
                       "re-applying the owner")
    }

    // MARK: - Invariant 2: the newest login wins

    func testNewerOrdering() {
        let now = Date()
        let older = login("acct", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let newer = login("acct", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        XCTAssertTrue(ClaudeLoginLifetime.isNewer(newer, than: older, now: now))
        XCTAssertFalse(ClaudeLoginLifetime.isNewer(older, than: newer, now: now))
        XCTAssertFalse(ClaudeLoginLifetime.isNewer(newer, than: newer, now: now), "a tie is not newer")

        let marker = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        XCTAssertTrue(ClaudeLoginLifetime.isDeadMarker(marker))
        XCTAssertFalse(ClaudeLoginLifetime.isDeadMarker(older))
        XCTAssertFalse(ClaudeLoginLifetime.isNewer(marker, than: older, now: now), "the marker is never newer")
        XCTAssertTrue(ClaudeLoginLifetime.isNewer(older, than: marker, now: now), "anything live beats it")

        // A login past its deadline loses whatever its access token says.
        let lapsed = login("acct", generation: 3, expiresIn: 8 * 3600, deadlineIn: -3600)
        let freshLogin = login("acct", generation: 1, expiresIn: 7 * 3600, deadlineIn: 30 * 86_400)
        XCTAssertTrue(ClaudeLoginLifetime.isNewer(freshLogin, than: lapsed, now: now))
        XCTAssertFalse(ClaudeLoginLifetime.isNewer(lapsed, than: freshLogin, now: now))

        // Two live logins: the deadline is fixed at /login and never extended,
        // so the later deadline is the later /login — it wins even though the
        // older login's pair was refreshed after it.
        let earlierLoginRefreshedLater = login("acct", generation: 7, expiresIn: 8 * 3600, deadlineIn: 5 * 86_400)
        let laterLogin = login("acct", generation: 1, expiresIn: 7 * 3600, deadlineIn: 28 * 86_400)
        XCTAssertTrue(ClaudeLoginLifetime.isNewer(laterLogin, than: earlierLoginRefreshedLater, now: now))
        XCTAssertFalse(ClaudeLoginLifetime.isNewer(earlierLoginRefreshedLater, than: laterLogin, now: now))

        // One login (deadlines within the tolerance — recorded a few seconds
        // apart): the access-token expiry decides.
        let sameLoginLater = login("acct", generation: 2, expiresIn: 8 * 3600,
                                   deadlineIn: 20 * 86_400 + ClaudeLoginLifetime.sameLoginDeadlineTolerance / 2)
        XCTAssertTrue(ClaudeLoginLifetime.isNewer(sameLoginLater, than: older, now: now))
        XCTAssertFalse(ClaudeLoginLifetime.isNewer(older, than: sameLoginLater, now: now))

        // A deadline missing on either side: the access-token expiry, as before.
        let noDeadline = login("acct", generation: 4, expiresIn: 9 * 3600)
        XCTAssertTrue(ClaudeLoginLifetime.isNewer(noDeadline, than: laterLogin, now: now))
        XCTAssertFalse(ClaudeLoginLifetime.isNewer(laterLogin, than: noDeadline, now: now))
    }

    func testTheStoreReadNeverServesTheFileOverTheCLIsDeadMarker() {
        let now = Date()
        let older = login("acct", generation: 1, expiresIn: 30 * 60)
        let newer = login("acct", generation: 2, expiresIn: 8 * 3600)
        let marker = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        typealias S = ClaudeCodeSyncService
        XCTAssertEqual(S.chooseSystemLogin(keychain: marker, file: older, now: now), .keychainDeadMarker,
                       "the file is the pair the CLI just found consumed")
        XCTAssertEqual(S.chooseSystemLogin(keychain: older, file: newer, now: now), .keychain,
                       "deadlines cannot decide: the Keychain, the CLI's own store, wins")
        XCTAssertEqual(S.chooseSystemLogin(keychain: newer, file: older, now: now), .keychain)
        XCTAssertEqual(S.chooseSystemLogin(keychain: nil, file: older, now: now), .file)
        XCTAssertEqual(S.chooseSystemLogin(keychain: nil, file: nil, now: now), .none)

        // The file wins only as a DIFFERENT, later login.
        let laterLogin = login("acct", generation: 1, expiresIn: 7 * 3600, deadlineIn: 28 * 86_400)
        let earlierLogin = login("acct", generation: 5, expiresIn: 8 * 3600, deadlineIn: 5 * 86_400)
        XCTAssertEqual(S.chooseSystemLogin(keychain: earlierLogin, file: laterLogin, now: now), .file)
        XCTAssertEqual(S.chooseSystemLogin(keychain: laterLogin, file: earlierLogin, now: now), .keychain)

        cliStore.set(keychain: marker, file: older)
        XCTAssertNil(try sync.readSystemCredentials())
    }

    /// The switch-away re-sync keeps the profile's newer pair when the CLI's
    /// copy is the older one it was rotated from (2026-10-02 05:24:10).
    func testTheReSyncNeverReplacesANewerStoredLoginWithAnOlderOne() async throws {
        let stored = login("outgoing", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        let outgoing = profile("outgoing", login: stored)
        seed([outgoing], focused: outgoing.id)
        let cliCopy = login("outgoing", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        cliStore.set(keychain: cliCopy, file: cliCopy)

        try await sync.resyncBeforeSwitching(for: outgoing.id)

        XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2")
    }

    /// … and with the CLI's dead marker in the Keychain and the consumed pair
    /// in the file — the 2026-10-09 05:45:44 re-sync, which saved the consumed pair.
    func testTheReSyncLeavesTheProfileAloneWhenTheCLIHoldsItsDeadMarker() async throws {
        let stored = login("outgoing", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        let outgoing = profile("outgoing", login: stored)
        seed([outgoing], focused: outgoing.id)
        let marker = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        cliStore.set(keychain: marker, file: login("outgoing", generation: 1, expiresIn: 30 * 60))

        try await sync.resyncBeforeSwitching(for: outgoing.id)

        XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2")
    }

    /// The other direction: the CLI refreshed silently, so its pair is newer
    /// and the profile adopts it.
    func testTheReSyncAdoptsANewerLoginFromTheCLI() async throws {
        let outgoing = profile("outgoing", login: login("outgoing", generation: 1, expiresIn: 30 * 60))
        seed([outgoing], focused: outgoing.id)
        let cliCopy = login("outgoing", generation: 2, expiresIn: 8 * 3600)
        cliStore.set(keychain: cliCopy, file: nil)

        try await sync.resyncBeforeSwitching(for: outgoing.id)

        XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2")
    }

    /// The store itself: an ORDINARY save never changes a stored Claude login —
    /// older, newer, tied or unknown. A roster or metadata save carries the
    /// login its array was loaded with, and no comparison can tell a stale copy
    /// from a newer login reliably. Logins change only through the explicit
    /// paths: compare-and-swap, a sync or an import, and removal.
    func testOrdinarySavesNeverChangeAStoredLogin() throws {
        var account = profile("account", login: login("account", generation: 2, expiresIn: 8 * 3600))
        seed([account], focused: account.id)
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-2", "a profile is created with its login")

        for (generation, expiresIn) in [(1, 30.0 * 60), (3, 9.0 * 3600)] {
            account.cliCredentialsJSON = login("account", generation: generation, expiresIn: expiresIn)
            store.saveProfiles([account])
            XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-2",
                           "generation \(generation): an ordinary save keeps the stored login")
        }

        // saveProfileCredentials round-trips are ordinary saves …
        var credentials = try store.loadProfileCredentials(account.id)
        credentials.cliCredentialsJSON = login("account", generation: 6, expiresIn: 9 * 3600)
        try store.saveProfileCredentials(account.id, credentials: credentials)
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-2")
        // … unless the caller says it is replacing the login (an import).
        try store.saveProfileCredentials(account.id, credentials: credentials, replacingCLILogin: true)
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-6")

        // Compare-and-swap: only over the login the writer started from.
        let current = storedLogin(account.id)
        XCTAssertFalse(store.replaceCLILogin(account.id, expected: login("account", generation: 9, expiresIn: 60),
                                             with: login("account", generation: 7, expiresIn: 8 * 3600)))
        XCTAssertEqual(storedLogin(account.id), current)
        XCTAssertTrue(store.replaceCLILogin(account.id, expected: current,
                                            with: login("account", generation: 7, expiresIn: 8 * 3600)))
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-7")

        account.cliCredentialsJSON = login("other", generation: 1, expiresIn: 7 * 3600)
        store.saveProfiles([account], explicitCLILoginWrite: account.id)
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "other-refresh-1",
                       "an explicit sync may bring another account's login, earlier expiry or not")
    }

    // MARK: - Review round 2

    /// A late-completing refresh must not overwrite a `/login` synced in while
    /// its request was in flight: the rotated pair is stored only over the
    /// pair that was redeemed (compare-and-swap) and is otherwise discarded.
    func testALateRotationNeverOverwritesALoginSyncedInWhileItWasInFlight() async {
        let account = profile("account", login: login("account", expiresIn: 30 * 60, deadlineIn: 20 * 86_400))
        seed([account], focused: account.id)
        let synced = login("fresh", expiresIn: 8 * 3600, deadlineIn: 30 * 86_400)
        let store = store
        endpoint.onRedeem = {
            var copy = store.loadProfiles()
            if let index = copy.firstIndex(where: { $0.id == account.id }) {
                copy[index].cliCredentialsJSON = synced
                store.saveProfiles(copy, explicitCLILoginWrite: account.id)  // what syncToProfile does
            }
        }

        let changed = await sync.ensureFreshCredentials(
            for: account.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertFalse(changed)
        XCTAssertEqual(storedLogin(account.id), synced, "the synced login stays; the late successor is discarded")
    }

    /// The "CLI holds this token" check fails CLOSED: an unreadable half, or a
    /// payload that is neither JSON nor carries a complete token, is unknown —
    /// and unknown refuses the redemption.
    func testTheRedemptionIsRefusedWhenTheCLIStoreCannotBeInspected() async {
        let target = profile("target", login: login("target", expiresIn: 30 * 60, deadlineIn: 20 * 86_400))
        let owner = profile("owner", login: login("owner", expiresIn: 6 * 3600))
        seed([owner, target], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        let truncated = String(owner.cliCredentialsJSON!.prefix(40))  // cut before any token

        let cases: [(String, () -> Void)] = [
            ("unreadable Keychain item", { self.cliStore.set(keychain: nil, file: nil); self.cliStore.keychainUnreadable = true }),
            ("unreadable file", { self.cliStore.keychainUnreadable = false; self.cliStore.fileUnreadable = true }),
            ("truncated Keychain payload", { self.cliStore.fileUnreadable = false; self.cliStore.set(keychain: truncated, file: nil) }),
            ("unparseable file", { self.cliStore.set(keychain: nil, file: "{not json") })
        ]
        for (name, arrange) in cases {
            arrange()
            let changed = await sync.ensureFreshCredentials(
                for: target.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
            )
            XCTAssertFalse(changed, name)
            XCTAssertTrue(endpoint.redeemed.isEmpty, "\(name): cannot prove the CLI does not hold it")
        }

        cliStore.set(keychain: owner.cliCredentialsJSON, file: nil)
        let changed = await sync.ensureFreshCredentials(
            for: target.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        XCTAssertTrue(changed, "both halves conclusively read, neither holds it")
    }

    /// The repair writes ONLY the half that holds the consumed token: a
    /// file-only match never authorizes a Keychain write.
    func testTheRepairWritesOnlyTheHalfThatHoldsTheConsumedToken() async {
        let target = profile("target", login: login("target", expiresIn: 30 * 60, deadlineIn: 20 * 86_400))
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        seed([other, target], focused: other.id)
        manager.claimActiveClaudeOwnership(other.id)
        cliStore.set(keychain: other.cliCredentialsJSON, file: other.cliCredentialsJSON)
        let cliStore = cliStore
        endpoint.onRedeem = {
            // While the request is in flight, the FILE (only) is handed the
            // pair being consumed.
            _ = cliStore.writeFile(target.cliCredentialsJSON!)
        }

        let changed = await sync.ensureFreshCredentials(
            for: target.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(refreshToken(cliStore.file), "target-refresh-2", "the file held the consumed token: repaired")
        XCTAssertEqual(refreshToken(cliStore.keychain), "other-refresh-1", "the Keychain did not: untouched")
        XCTAssertTrue(cliStore.writes.isEmpty, "no Keychain write at all")
    }

    /// A repair that does not land is not a success: the call reports false,
    /// the repair is kept, and the retry lands it under the same per-half
    /// check.
    func testAFailedRepairIsReportedAndRetried() async {
        let target = profile("target", login: login("target", expiresIn: 30 * 60, deadlineIn: 20 * 86_400))
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        seed([other, target], focused: other.id)
        manager.claimActiveClaudeOwnership(other.id)
        cliStore.set(keychain: other.cliCredentialsJSON, file: nil)
        let cliStore = cliStore
        endpoint.onRedeem = {
            cliStore.set(keychain: target.cliCredentialsJSON, file: nil)
            cliStore.failKeychainWrites = true
        }

        let changed = await sync.ensureFreshCredentials(
            for: target.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        XCTAssertFalse(changed, "the CLI still holds the consumed token")
        XCTAssertEqual(refreshToken(storedLogin(target.id)), "target-refresh-2", "the profile keeps the rotated pair")
        XCTAssertEqual(refreshToken(cliStore.keychain), "target-refresh-1")

        cliStore.failKeychainWrites = false
        await sync.retryPendingCLIRepairs()
        XCTAssertEqual(refreshToken(cliStore.keychain), "target-refresh-2", "the retry lands it")
    }

    /// Two profiles holding ONE login share one redemption slot and one
    /// hand-off: a hand-off of A blocks a redemption of its alias B, and when
    /// A's login is rotated B gets the successor — the token B held is dead.
    func testProfilesSharingALoginShareTheMutexTheHandOffAndTheRotation() async {
        let shared = login("shared", expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let owner = profile("owner", login: login("owner", expiresIn: 6 * 3600))
        let first = profile("first", login: shared)
        let alias = profile("alias", login: shared)
        seed([owner, first, alias], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        cliStore.set(keychain: owner.cliCredentialsJSON, file: nil)

        sync.beginHandoff(first.id)
        let blocked = await sync.ensureFreshCredentials(
            for: alias.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        sync.endHandoff(first.id)
        XCTAssertFalse(blocked)
        XCTAssertTrue(endpoint.redeemed.isEmpty, "a hand-off of one profile blocks its alias")

        var aliasResult: Bool?
        let sync = sync
        endpoint.onRedeem = {
            // While first's redemption is in flight, the alias tries the same token.
            aliasResult = await sync.ensureFreshCredentials(
                for: alias.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
            )
        }
        let rotated = await sync.ensureFreshCredentials(
            for: first.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertTrue(rotated)
        XCTAssertEqual(aliasResult, false, "the alias found the token's slot taken")
        XCTAssertEqual(endpoint.redeemed, ["shared-refresh-1"], "one redemption for one login")
        XCTAssertEqual(refreshToken(storedLogin(alias.id)), "shared-refresh-2", "the alias got the successor")
    }

    /// An idle owner whose access token expired with no CLI running is
    /// AWAITING CLI RENEWAL — not dead: no redemption, no dead flag, no
    /// `/login` notice, and re-activating it applies nothing and refuses
    /// nothing. Once the CLI renews, the adoption clears the state.
    func testAnIdleOwnersExpiredLoginAwaitsTheCLIInsteadOfDying() async {
        let owner = profile("owner", login: login("owner", expiresIn: -10 * 60, deadlineIn: 20 * 86_400))
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        seed([owner, other], focused: other.id)
        manager.claimActiveClaudeOwnership(owner.id)
        cliStore.set(keychain: owner.cliCredentialsJSON, file: owner.cliCredentialsJSON)

        let changed = await sync.ensureFreshCredentials(for: owner.id, adoptSystemKeychain: true)
        XCTAssertFalse(changed)
        XCTAssertTrue(endpoint.redeemed.isEmpty)
        XCTAssertTrue(sync.isAwaitingCLIRenewal(owner.id))
        XCTAssertFalse(sync.isLoginMarkedDead(owner.id), "awaiting renewal is not a dead login")

        let outcome = await manager.activateProfileDetailed(owner.id, userInitiated: true)
        XCTAssertNotEqual(outcome, .focusedWithoutApplying, "not refused as a dead login")
        XCTAssertFalse(sync.isLoginMarkedDead(owner.id), "and still not flagged")
        XCTAssertEqual(manager.activeClaudeProfileId, owner.id)
        XCTAssertTrue(endpoint.redeemed.isEmpty)

        // The CLI runs and renews its own login.
        cliStore.set(keychain: login("owner", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)
        let adopted = await sync.ensureFreshCredentials(for: owner.id, adoptSystemKeychain: true)
        XCTAssertTrue(adopted)
        XCTAssertFalse(sync.isAwaitingCLIRenewal(owner.id))
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "owner-refresh-2")
    }

    // MARK: - Invariant 3: the login deadline (cause A)

    func testTheDeadlineIsReadInMillisecondsAndSeconds() {
        let deadline = Date(timeIntervalSince1970: 1_800_000_000)
        func json(_ value: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
                "accessToken": "a-access-1", "refreshToken": "a-refresh-1", "refreshTokenExpiresAt": value
            ]])
            return String(data: data, encoding: .utf8)!
        }
        XCTAssertEqual(ClaudeLoginLifetime.deadline(json(1_800_000_000_000)), deadline, "milliseconds (the CLI's unit)")
        XCTAssertEqual(ClaudeLoginLifetime.deadline(json(1_800_000_000)), deadline, "seconds")
        XCTAssertEqual(ClaudeLoginLifetime.deadline(json("1800000000000")), deadline, "a numeric string")
        XCTAssertNil(ClaudeLoginLifetime.deadline(login("a", expiresIn: 3600)), "no field")
    }

    func testTheDeadlineMargin() {
        let now = Date()
        func blocks(_ deadlineIn: TimeInterval?) -> Bool {
            ClaudeLoginLifetime.deadlineBlocksSwitch(login("a", expiresIn: 6 * 3600, deadlineIn: deadlineIn), now: now)
        }
        XCTAssertTrue(blocks(-60), "passed")
        XCTAssertTrue(blocks(30 * 60), "inside the hour")
        XCTAssertFalse(blocks(2 * 3600))
        XCTAssertFalse(blocks(nil), "no field: unchanged behaviour")
        XCTAssertFalse(ClaudeLoginLifetime.deadlineBlocksSwitch(nil, now: now), "no login at all")
    }

    func testALoginAtItsDeadlineIsNotASwitchCandidate() {
        var reading = ClaudeUsage.empty
        reading.sessionPercentage = 10
        reading.sessionResetTime = Date().addingTimeInterval(3600)
        reading.weeklyPercentage = 20
        reading.weeklyResetTime = Date().addingTimeInterval(86_400)
        reading.lastUpdated = Date()
        func candidate(_ name: String, deadlineIn: TimeInterval?, weeklyResetIn: TimeInterval) -> Profile {
            var usage = reading
            usage.weeklyResetTime = Date().addingTimeInterval(weeklyResetIn)
            var p = profile(name, login: login(name, expiresIn: 6 * 3600, deadlineIn: deadlineIn))
            p.claudeUsage = usage
            return p
        }
        let lapsed = candidate("lapsed", deadlineIn: -3600, weeklyResetIn: 1 * 86_400)
        let lapsing = candidate("lapsing", deadlineIn: 20 * 60, weeklyResetIn: 2 * 86_400)
        let unknown = candidate("unknown", deadlineIn: nil, weeklyResetIn: 3 * 86_400)
        let healthy = candidate("healthy", deadlineIn: 10 * 86_400, weeklyResetIn: 4 * 86_400)
        let now = Date()
        func eligible(_ p: Profile) -> Bool {
            MenuBarManager.candidateHasHeadroom(p, sessionThreshold: 95, weeklyThreshold: 99,
                                                ignoreFableWeekly: true, now: now)
        }
        XCTAssertFalse(eligible(lapsed))
        XCTAssertFalse(eligible(lapsing))
        XCTAssertTrue(eligible(unknown), "a credential without the field behaves as before")
        XCTAssertTrue(eligible(healthy))

        // The walk, through the predicates the live walk composes: the two
        // soonest-resetting accounts are skipped for their deadlines.
        let ranked = MenuBarManager.rankAutoSwitchCandidates([lapsed, lapsing, unknown, healthy], customOrder: nil, now: now)
        XCTAssertEqual(ranked.first?.name, "lapsed", "ranking alone would pick the lapsed login")
        XCTAssertEqual(ranked.first(where: eligible)?.name, "unknown")
    }

    func testThePreflightVerdictIsNotLiveAtTheDeadline() {
        let now = Date()
        XCTAssertFalse(MenuBarManager.claudePreflightLoginIsLive(
            login("a", expiresIn: 6 * 3600, deadlineIn: -60), now: now), "passed")
        XCTAssertFalse(MenuBarManager.claudePreflightLoginIsLive(
            login("a", expiresIn: 6 * 3600, deadlineIn: 30 * 60), now: now), "inside the margin")
        XCTAssertTrue(MenuBarManager.claudePreflightLoginIsLive(
            login("a", expiresIn: 6 * 3600), now: now), "no field")
        XCTAssertFalse(MenuBarManager.claudePreflightLoginIsLive(
            login("a", expiresIn: -60), now: now), "an expired access token, as before")
    }

    /// The activation gate refuses a login at its deadline exactly like an
    /// expired one: nothing is written to the CLI, the pointer stays.
    func testTheSwitchRefusesALoginAtItsDeadline() async {
        for (name, deadlineIn) in [("lapsed", -3600.0), ("lapsing", 20.0 * 60)] {
            let outgoing = profile("outgoing", login: nil)
            let target = profile(name, login: login(name, expiresIn: 6 * 3600, deadlineIn: deadlineIn))
            seed([outgoing, target], focused: outgoing.id)
            manager.claimActiveClaudeOwnership(outgoing.id)

            let outcome = await manager.activateProfileDetailed(target.id, userInitiated: false)

            XCTAssertEqual(outcome, .credentialsRefused, name)
            XCTAssertTrue(cliStore.writes.isEmpty, "\(name): nothing reaches the CLI")
            XCTAssertEqual(manager.activeClaudeProfileId, outgoing.id, name)
            XCTAssertTrue(sync.isLoginMarkedDead(target.id), "\(name): the user is told to /login")
            sync.markLoginRevived(target.id)
            store.deleteProfileCredentials(profileId: target.id)
        }
    }

    func testTheSwitchIsUnchangedForALoginWithoutADeadline() async {
        let outgoing = profile("outgoing", login: nil)
        let target = profile("target", login: login("target", expiresIn: 6 * 3600))
        seed([outgoing, target], focused: outgoing.id)
        manager.claimActiveClaudeOwnership(outgoing.id)

        let outcome = await manager.activateProfileDetailed(target.id, userInitiated: false)

        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(refreshToken(cliStore.keychain), "target-refresh-1")
    }

    /// A refresh the widget performs keeps the deadline true: the server's
    /// `refresh_token_expires_in` is stored the way the CLI stores it, and a
    /// response without it keeps the previous value.
    func testARefreshStoresTheServersDeadline() async {
        let previous = login("account", expiresIn: 30 * 60, deadlineIn: 5 * 86_400)
        let account = profile("account", login: previous)
        let owner = profile("owner", login: login("owner", expiresIn: 6 * 3600))
        seed([owner, account], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)

        _ = await sync.ensureFreshCredentials(for: account.id, adoptSystemKeychain: false,
                                              freshFor: ClaudeRefreshPolicy.handoffFreshness)
        XCTAssertEqual(storedLogin(account.id).flatMap(ClaudeLoginLifetime.deadline)?.timeIntervalSince1970 ?? 0,
                       ClaudeLoginLifetime.deadline(previous)?.timeIntervalSince1970 ?? -1, accuracy: 1,
                       "no field in the response: the previous deadline is kept")

        endpoint.extraPayload = ["refresh_token_expires_in": 30.0 * 86_400]
        _ = await sync.ensureFreshCredentials(for: account.id, adoptSystemKeychain: false,
                                              freshFor: 9 * 3600)
        let stored = storedLogin(account.id).flatMap(ClaudeLoginLifetime.deadline)
        XCTAssertEqual(stored?.timeIntervalSinceNow ?? 0, 30 * 86_400, accuracy: 5)
    }
}

// MARK: - Doubles

/// The CLI's two credential stores. Read and written off the main actor (the
/// apply runs on a background queue), hence the lock. Either half can be made
/// unreadable, and either half's writes can be made to fail.
final class FakeCLIStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _keychain: String?
    private var _file: String?
    private var _keychainWrites: [String] = []
    private var _fileWrites: [String] = []
    private var _keychainUnreadable = false
    private var _fileUnreadable = false
    private var _failKeychainWrites = false
    private var _failFileWrites = false

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var keychain: String? { locked { _keychain } }
    var file: String? { locked { _file } }
    /// Every write to the Keychain half — the half the CLI reads first.
    var writes: [String] { locked { _keychainWrites } }
    var fileWrites: [String] { locked { _fileWrites } }

    var keychainUnreadable: Bool {
        get { locked { _keychainUnreadable } }
        set { locked { _keychainUnreadable = newValue } }
    }
    var fileUnreadable: Bool {
        get { locked { _fileUnreadable } }
        set { locked { _fileUnreadable = newValue } }
    }
    var failKeychainWrites: Bool {
        get { locked { _failKeychainWrites } }
        set { locked { _failKeychainWrites = newValue } }
    }
    var failFileWrites: Bool {
        get { locked { _failFileWrites } }
        set { locked { _failFileWrites = newValue } }
    }

    func set(keychain: String?, file: String?) {
        locked {
            _keychain = keychain
            _file = file
        }
    }

    func halves() -> (keychain: ClaudeCodeSyncService.StoreHalf, file: ClaudeCodeSyncService.StoreHalf) {
        locked {
            (_keychainUnreadable ? .unreadable : _keychain.map { .contents($0) } ?? .absent,
             _fileUnreadable ? .unreadable : _file.map { .contents($0) } ?? .absent)
        }
    }

    func writeKeychain(_ json: String) -> Bool {
        locked {
            guard !_failKeychainWrites else { return false }
            _keychain = json
            _keychainWrites.append(json)
            return true
        }
    }

    func writeFile(_ json: String) -> Bool {
        locked {
            guard !_failFileWrites else { return false }
            _file = json
            _fileWrites.append(json)
            return true
        }
    }

    /// What an apply does to the real store: both halves.
    func write(_ json: String) {
        _ = writeFile(json)
        _ = writeKeychain(json)
    }
}

/// The token endpoint. Each refresh token is good exactly once — redeeming it
/// again returns 400, as the real endpoint does for a consumed token.
@MainActor
final class FakeTokenEndpoint {
    private(set) var redeemed: [String] = []
    var refused: Set<String> = []
    /// Extra fields merged into every successful response.
    var extraPayload: [String: Any] = [:]
    /// Called before the response is returned, to interleave other work with
    /// a redemption that is "in flight".
    var onRedeem: (() async -> Void)?

    func redeem(_ refreshToken: String) async -> (status: Int, payload: [String: Any]?) {
        if let onRedeem { await onRedeem() }
        guard !redeemed.contains(refreshToken), !refused.contains(refreshToken) else {
            redeemed.append(refreshToken)
            return (400, ["error": "invalid_grant"])
        }
        redeemed.append(refreshToken)
        // "<account>-refresh-<n>" → generation n + 1 of the same account.
        let parts = refreshToken.components(separatedBy: "-refresh-")
        let account = parts.first ?? "unknown"
        let next = (parts.count == 2 ? Int(parts[1]) ?? 1 : 1) + 1
        var payload: [String: Any] = [
            "access_token": "\(account)-access-\(next)",
            "refresh_token": "\(account)-refresh-\(next)",
            "expires_in": 28_800.0
        ]
        payload.merge(extraPayload) { _, new in new }
        return (200, payload)
    }
}
