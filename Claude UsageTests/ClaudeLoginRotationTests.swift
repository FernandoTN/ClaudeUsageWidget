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
            readSources: { cliStore.sources() },
            write: { cliStore.write($0) }
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
        sync.setCLIStoreForTesting(nil)
        sync.setTokenEndpointForTesting(nil)
        sync.setIdentityFetcherForTesting(nil)
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
            for: target.id, adoptSystemKeychain: false, syncToSystem: false, freshFor: 3600
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
        var parkedWithNothingApplied = false
        let manager = manager
        let sync = sync
        let cliStore = cliStore
        endpoint.onRedeem = {
            guard activation == nil else { return }
            activation = Task { await manager.activateProfileDetailed(target.id, userInitiated: false) }
            // Hand the main actor to the switch until it parks on this redemption.
            for _ in 0..<20 { await Task.yield() }
            parkedWithNothingApplied = sync.isHandoffInFlight(target.id) && cliStore.writes.isEmpty
        }

        // The preflight starts redeeming first …
        _ = await sync.ensureFreshCredentials(
            for: target.id, adoptSystemKeychain: false, syncToSystem: false,
            freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        // … and the switch lands only after it.
        let outcome = await activation?.value

        XCTAssertEqual(outcome, .activated)
        XCTAssertTrue(parkedWithNothingApplied, "while the redemption is in flight the switch waits and applies nothing")
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
            for: owner.id, adoptSystemKeychain: false, syncToSystem: false,
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
            for: target.id, adoptSystemKeychain: false, syncToSystem: false,
            freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertFalse(changed)
        XCTAssertTrue(endpoint.redeemed.isEmpty)
    }

    /// If a redemption ever finishes after its profile became the owner (a
    /// path that applied without waiting), the rotated pair reaches the CLI.
    func testARefreshThatFinishesAfterItsProfileBecameTheOwnerHandsTheNewPairToTheCLI() async {
        let target = profile("target", login: login("target", expiresIn: 30 * 60, deadlineIn: 20 * 86_400))
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        seed([other, target], focused: other.id)
        manager.claimActiveClaudeOwnership(other.id)
        let manager = manager
        let cliStore = cliStore
        endpoint.onRedeem = {
            // A switch lands while the request is in flight.
            cliStore.write(target.cliCredentialsJSON!)
            manager.claimActiveClaudeOwnership(target.id)
        }

        let changed = await sync.ensureFreshCredentials(
            for: target.id, adoptSystemKeychain: false, syncToSystem: false,
            freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(refreshToken(cliStore.keychain), "target-refresh-2",
                       "decided at completion: the profile owns the CLI login now, so the CLI gets the rotated pair")
    }

    /// And the mirror: an owner refresh that finishes after the CLI moved to
    /// another account must not write over that account's login.
    func testARefreshThatFinishesAfterItsProfileLostTheLoginLeavesTheNewOwnerAlone() async {
        let owner = profile("owner", login: login("owner", expiresIn: 60, deadlineIn: 20 * 86_400))
        let next = profile("next", login: login("next", expiresIn: 6 * 3600))
        seed([owner, next], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        let manager = manager
        let cliStore = cliStore
        endpoint.onRedeem = {
            cliStore.write(next.cliCredentialsJSON!)
            manager.claimActiveClaudeOwnership(next.id)
        }

        let changed = await sync.ensureFreshCredentials(
            for: owner.id, adoptSystemKeychain: false, syncToSystem: true
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(refreshToken(cliStore.keychain), "next-refresh-1", "the new owner's login stays in the CLI")
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "owner-refresh-2", "the rotated pair is kept in its profile")
    }

    /// The one window the owner IS redeemed in: its last two minutes, by the
    /// sweep, with the result written to the CLI in the same step.
    func testTheSweepRenewsTheOwnerInItsLastTwoMinutesAndWritesTheCLI() async {
        let owner = profile("owner", login: login("owner", expiresIn: 60, deadlineIn: 20 * 86_400))
        seed([owner], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        cliStore.set(keychain: owner.cliCredentialsJSON, file: owner.cliCredentialsJSON)

        let changed = await sync.ensureFreshCredentials(
            for: owner.id, adoptSystemKeychain: true, syncToSystem: true
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(endpoint.redeemed, ["owner-refresh-1"])
        XCTAssertEqual(refreshToken(cliStore.keychain), "owner-refresh-2")
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "owner-refresh-2")
    }

    func testRedemptionPolicy() {
        typealias P = ClaudeRefreshPolicy
        func decide(_ timeLeft: TimeInterval, freshFor: TimeInterval = P.handoffFreshness, canRedeem: Bool = true,
                    owns: Bool = false, handoff: Bool = false, role: P.Role = .maintenance,
                    sync: Bool = false) -> P.Decision {
            P.decide(timeLeft: timeLeft, freshFor: freshFor, canRedeem: canRedeem, ownsCLILogin: owns,
                     handoffInFlight: handoff, role: role, syncToSystem: sync)
        }
        XCTAssertEqual(decide(2 * 3600), .notNeeded)
        XCTAssertEqual(decide(30 * 60, canRedeem: false), .notNeeded, "no refresh token, or flagged dead")
        XCTAssertEqual(decide(30 * 60), .redeem, "an idle candidate is renewed into the profile store")
        XCTAssertEqual(decide(30 * 60, sync: true), .redeem, "a login the CLI does not hold is never written to it")
        XCTAssertEqual(decide(30 * 60, owns: true), .refuseHandedOff, "the preflight on the owner")
        XCTAssertEqual(decide(30 * 60, owns: true, sync: true), .refuseHandedOff,
                       "even writing it back: outside the last two minutes the CLI's sessions are mid-use")
        XCTAssertEqual(decide(60, freshFor: P.ownerRefreshHorizon, owns: true, sync: true), .redeemAndHandToCLI)
        XCTAssertEqual(decide(60, freshFor: P.ownerRefreshHorizon, owns: true), .refuseHandedOff)
        XCTAssertEqual(decide(30 * 60, handoff: true), .refuseHandedOff, "a maintenance caller during a hand-off")
        XCTAssertEqual(decide(30 * 60, handoff: true, role: .handoff), .redeem, "the hand-off renewing its own login")
        XCTAssertEqual(decide(30 * 60, owns: true, handoff: true, role: .handoff), .refuseHandedOff,
                       "re-applying the owner gets the owner's rule")
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
    }

    func testTheStoreReadNeverServesTheFileOverTheCLIsDeadMarker() {
        let now = Date()
        let older = login("acct", generation: 1, expiresIn: 30 * 60)
        let newer = login("acct", generation: 2, expiresIn: 8 * 3600)
        let marker = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        typealias S = ClaudeCodeSyncService
        XCTAssertEqual(S.chooseSystemLogin(keychain: marker, file: older, now: now), .keychainDeadMarker,
                       "the file is the pair the CLI just found consumed")
        XCTAssertEqual(S.chooseSystemLogin(keychain: older, file: newer, now: now), .file)
        XCTAssertEqual(S.chooseSystemLogin(keychain: newer, file: older, now: now), .keychain)
        XCTAssertEqual(S.chooseSystemLogin(keychain: newer, file: newer, now: now), .keychain, "ties go to the Keychain")
        XCTAssertEqual(S.chooseSystemLogin(keychain: nil, file: older, now: now), .file)
        XCTAssertEqual(S.chooseSystemLogin(keychain: nil, file: nil, now: now), .none)

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

    /// The store itself: a roster array loaded before a refresh and saved after
    /// it must not put the consumed pair back. Only an explicit sync may move
    /// a login backwards.
    func testTheStoreKeepsTheNewerLoginWhenAStaleCopyIsSaved() {
        var account = profile("account", login: login("account", generation: 2, expiresIn: 8 * 3600))
        seed([account], focused: account.id)

        account.cliCredentialsJSON = login("account", generation: 1, expiresIn: 30 * 60)
        store.saveProfiles([account])
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-2", "older over newer is refused")

        account.cliCredentialsJSON = login("account", generation: 3, expiresIn: 9 * 3600)
        store.saveProfiles([account])
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-3", "newer over older is written")

        account.cliCredentialsJSON = login("other", generation: 1, expiresIn: 7 * 3600)
        store.saveProfiles([account], explicitCLILoginWrite: account.id)
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "other-refresh-1",
                       "an explicit sync may bring another account's login, earlier expiry or not")
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

        _ = await sync.ensureFreshCredentials(for: account.id, adoptSystemKeychain: false, syncToSystem: false,
                                              freshFor: ClaudeRefreshPolicy.handoffFreshness)
        XCTAssertEqual(storedLogin(account.id).flatMap(ClaudeLoginLifetime.deadline)?.timeIntervalSince1970 ?? 0,
                       ClaudeLoginLifetime.deadline(previous)?.timeIntervalSince1970 ?? -1, accuracy: 1,
                       "no field in the response: the previous deadline is kept")

        endpoint.extraPayload = ["refresh_token_expires_in": 30.0 * 86_400]
        _ = await sync.ensureFreshCredentials(for: account.id, adoptSystemKeychain: false, syncToSystem: false,
                                              freshFor: 9 * 3600)
        let stored = storedLogin(account.id).flatMap(ClaudeLoginLifetime.deadline)
        XCTAssertEqual(stored?.timeIntervalSinceNow ?? 0, 30 * 86_400, accuracy: 5)
    }
}

// MARK: - Doubles

/// The CLI's two credential stores. Read and written off the main actor (the
/// apply runs on a background queue), hence the lock.
final class FakeCLIStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _keychain: String?
    private var _file: String?
    private var _writes: [String] = []

    var keychain: String? { lock.lock(); defer { lock.unlock() }; return _keychain }
    var file: String? { lock.lock(); defer { lock.unlock() }; return _file }
    var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }

    func set(keychain: String?, file: String?) {
        lock.lock(); defer { lock.unlock() }
        _keychain = keychain
        _file = file
    }

    func sources() -> (keychain: String?, file: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_keychain, _file)
    }

    /// What `writeSystemCredentials` does to the real store: both halves.
    func write(_ json: String) {
        lock.lock(); defer { lock.unlock() }
        _keychain = json
        _file = json
        _writes.append(json)
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
