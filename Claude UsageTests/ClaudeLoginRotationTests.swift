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
        let endpoint = endpoint
        installCLIStoreSeams()
        store.resetLoginRecordsForTesting()
        sync.setIdentityProbeForTesting(nil)
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
        sync.setIdentityProbeForTesting(nil)
        store.resetLoginRecordsForTesting()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The CLI's store as `cliStore` stands it in: both credential halves and
    /// `~/.claude.json`'s `oauthAccount` record (`cachedAccount`).
    private func installCLIStoreSeams() {
        let cliStore = cliStore
        sync.setCLIStoreForTesting(ClaudeCodeSyncService.CLIStoreSeams(
            readHalves: { cliStore.halves() },
            writeKeychain: { cliStore.writeKeychain($0) },
            writeFile: { cliStore.writeFile($0) },
            cachedAccountUUID: { cliStore.cachedAccount }
        ))
    }

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

    /// A redemption never writes the CLI's store: one that finishes after the
    /// CLI moved to another login leaves that login alone, and the rotated pair
    /// goes to the profile store only. (The CLI's store is written only by an
    /// activation's apply and the sweep's file heal.)
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

    // MARK: - Invariant 2: the login the CLI holds wins

    /// The rule itself (`ClaudeLoginLifetime.cliLoginReplaces`, #186 v3): among
    /// logins of the same account proven live, the CLI's wins; recency and the
    /// deadline never rank them; each side's account comes from its own token.
    func testTheLoginTheCLIHoldsReplacesTheStoredOne() {
        let now = Date()
        typealias L = ClaudeLoginLifetime
        func replaces(_ stored: String?, with cli: String, cli cliEvidence: L.LoginEvidence = .live(account: "acct-acct"),
                      stored storedEvidence: L.LoginEvidence = .live(account: "acct-acct"), stamp: String? = nil) -> Bool {
            L.cliLoginReplaces(stored, with: cli, cli: cliEvidence, stored: storedEvidence, storedStamp: stamp, now: now)
        }
        let logins = threeLoginsOfOneAccount("acct")
        for stored in logins.indices {
            for held in logins.indices where held != stored {
                XCTAssertTrue(replaces(logins[stored], with: logins[held]),
                              "stored \(stored + 1), CLI \(held + 1): the CLI's wins whichever deadline is later")
            }
        }
        // Recency never decides: a shorter-lived CLI pair still wins.
        let refreshedEarlier = login("acct", generation: 5, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let longer = login("acct", generation: 4, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        XCTAssertTrue(replaces(longer, with: refreshedEarlier))
        XCTAssertFalse(replaces(longer, with: longer), "the same login replaces nothing")
        var root = try! JSONSerialization.jsonObject(with: Data(longer.utf8)) as! [String: Any]
        var oauth = root["claudeAiOauth"] as! [String: Any]
        oauth["scopes"] = ["user:inference"]
        root["claudeAiOauth"] = oauth
        let rewritten = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
        XCTAssertNotEqual(rewritten, longer)
        XCTAssertFalse(replaces(longer, with: rewritten), "one token pair is one login, whatever else its JSON says")

        // The CLI's side must be PROVEN live by its own read.
        XCTAssertFalse(replaces(longer, with: refreshedEarlier, cli: .unknown(account: "acct-acct")),
                       "a recorded account is not liveness")
        XCTAssertFalse(replaces(longer, with: refreshedEarlier, cli: .dead(account: "acct-acct")))
        // The stored side: live or dead or unknown, its account must be the CLI's.
        XCTAssertFalse(replaces(longer, with: refreshedEarlier, stored: .live(account: "acct-other")), "contamination")
        XCTAssertTrue(replaces(longer, with: refreshedEarlier, stored: .unknown(account: "acct-acct")), "account known by its record")
        XCTAssertFalse(replaces(longer, with: refreshedEarlier, stored: .unknown(account: nil)), "nothing proves its account")
        XCTAssertFalse(replaces(longer, with: refreshedEarlier, stored: .unknown(account: "acct-other")))
        XCTAssertTrue(replaces(longer, with: refreshedEarlier, stored: .dead(account: nil)), "a dead login gives way")
        XCTAssertTrue(replaces(longer, with: refreshedEarlier, stored: .dead(account: nil), stamp: "acct-acct"))
        XCTAssertFalse(replaces(longer, with: refreshedEarlier, stored: .dead(account: nil), stamp: "acct-other"),
                       "a stamp may refuse, never grant")
        XCTAssertFalse(replaces(longer, with: refreshedEarlier, stored: .dead(account: "acct-other")),
                       "the account fact outlives the refusal")
        XCTAssertFalse(replaces(nil, with: longer), "an empty profile has no evidence: explicit Sync is the path")

        let marker = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        XCTAssertTrue(L.isDeadMarker(marker))
        XCTAssertFalse(L.isDeadMarker(longer))
        XCTAssertFalse(replaces(longer, with: marker), "the marker is never adopted")

        // The deadline only drops a lapsed CLI login.
        let lapsed = login("acct", generation: 3, expiresIn: 8 * 3600, deadlineIn: -3600)
        XCTAssertTrue(L.isLapsed(lapsed, now: now))
        XCTAssertFalse(L.isLapsed(longer, now: now))
        XCTAssertFalse(L.isLapsed(login("acct", expiresIn: 3600), now: now), "no field: never lapsed")
        XCTAssertFalse(replaces(longer, with: lapsed), "a lapsed CLI login replaces nothing")

        // Completeness, checked structurally: no incomplete login is adopted.
        let accessOnly = #"{"claudeAiOauth":{"accessToken":"acct-access-4"}}"#
        let noRefresh = login("acct", generation: 8, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400, refreshToken: false)
        XCTAssertFalse(L.isComplete(accessOnly))
        XCTAssertFalse(L.isComplete(noRefresh), "access token and expiry without a refresh token")
        XCTAssertFalse(L.isComplete(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"b"}}"#), "no expiry")
        XCTAssertTrue(L.isComplete(longer))
        XCTAssertFalse(replaces(longer, with: accessOnly))
        XCTAssertFalse(replaces(longer, with: noRefresh))
    }

    /// The evidence one read produces (`ClaudeLoginLifetime.evidence`): a fresh
    /// 2xx is live; a 401/403 on an UNEXPIRED token is dead; an expired token or
    /// no answer is unknown; a refused grant overrides "live" but never the
    /// account fact, and the account record never establishes liveness.
    func testWhatEachReadProves() {
        let now = Date()
        typealias L = ClaudeLoginLifetime
        let valid = now.addingTimeInterval(3600)
        let expired = now.addingTimeInterval(-60)
        func evidence(_ identified: String? = nil, _ rejected: Int? = nil, expiry: Date? = valid,
                      refused: Bool = false, recorded: String? = nil) -> L.LoginEvidence {
            L.evidence(identifiedAccount: identified, rejectedStatus: rejected, accessExpiry: expiry,
                       grantRefused: refused, recordedAccount: recorded, now: now)
        }
        XCTAssertEqual(evidence("a"), .live(account: "a"))
        XCTAssertEqual(evidence(nil, 401), .dead(account: nil))
        XCTAssertEqual(evidence(nil, 403, recorded: "a"), .dead(account: "a"))
        XCTAssertEqual(evidence(nil, 500), .unknown(account: nil), "a 5xx proves nothing")
        XCTAssertEqual(evidence(nil, 429, recorded: "a"), .unknown(account: "a"))
        XCTAssertEqual(evidence(), .unknown(account: nil), "no answer")
        XCTAssertEqual(evidence(nil, 401, expiry: expired), .unknown(account: nil), "an expired token proves nothing")
        XCTAssertEqual(evidence(expiry: expired, recorded: "a"), .unknown(account: "a"), "the record gives the account only")
        XCTAssertEqual(evidence("a", refused: true), .dead(account: "a"), "a refused grant overrides alive")
        XCTAssertEqual(evidence(refused: true, recorded: "a"), .dead(account: "a"), "and keeps the account fact")
        XCTAssertEqual(evidence(expiry: nil), .unknown(account: nil), "no expiry: nothing to judge")
    }

    func testTheStoreReadNeverServesTheFileOverTheCLIsDeadMarker() {
        let older = login("acct", generation: 1, expiresIn: 30 * 60)
        let newer = login("acct", generation: 2, expiresIn: 8 * 3600)
        let marker = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
        typealias S = ClaudeCodeSyncService
        XCTAssertEqual(S.chooseSystemLogin(keychain: marker, file: older, keychainConfirmedAbsent: false), .keychainDeadMarker,
                       "the file is the pair the CLI just found consumed")
        XCTAssertEqual(S.chooseSystemLogin(keychain: older, file: newer, keychainConfirmedAbsent: false), .keychain,
                       "the Keychain, the CLI's own store, wins")
        XCTAssertEqual(S.chooseSystemLogin(keychain: newer, file: older, keychainConfirmedAbsent: false), .keychain)
        XCTAssertEqual(S.chooseSystemLogin(keychain: nil, file: older, keychainConfirmedAbsent: true), .file)
        XCTAssertEqual(S.chooseSystemLogin(keychain: nil, file: nil, keychainConfirmedAbsent: true), .none)
        XCTAssertEqual(S.chooseSystemLogin(keychain: newer, file: marker, keychainConfirmedAbsent: false), .keychain)
        XCTAssertEqual(S.chooseSystemLogin(keychain: nil, file: marker, keychainConfirmedAbsent: true), .none)

        cliStore.set(keychain: marker, file: older)
        XCTAssertNil(try sync.readSystemCredentials())
    }

    /// The switch-away re-sync keeps the profile's pair when the CLI's copy is
    /// the one that pair was rotated from: a pair this app redeemed, consumed
    /// (2026-10-02 05:24:10). The policy keeps the CLI from ever holding one;
    /// if it did anyway, its access token died with the redemption, so its own
    /// fresh read refuses it and no adoption path takes it.
    func testNoAdoptionTakesAPairThisAppRedeemed() async throws {
        identityEndpoint { token, fresh in token == "outgoing-access-1" && fresh ? .rejected(status: 401) : nil }
        let original = login("outgoing", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        var outgoing = profile("outgoing", login: original)
        outgoing.claudeAccountUUID = "acct-outgoing"
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        seed([other, outgoing], focused: other.id)
        // The profile's login is redeemed while the CLI holds someone else's …
        manager.claimActiveClaudeOwnership(other.id)
        cliStore.set(keychain: other.cliCredentialsJSON, file: nil)
        _ = await sync.ensureFreshCredentials(
            for: outgoing.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        XCTAssertEqual(endpoint.redeemed, ["outgoing-refresh-1"])
        XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2")

        // … and the CLI then shows the consumed pair.
        manager.claimActiveClaudeOwnership(outgoing.id)
        cliStore.set(keychain: original, file: original)
        for path in AdoptionPath.allCases {
            let outcome = try await adopt(path, into: outgoing.id)
            if path == .sweep { XCTAssertEqual(outcome, .noSharedLogin, "the CLI's own login is revoked: nothing to route") }
            XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2",
                           "\(path.rawValue): the consumed pair never replaces its successor")
        }
        XCTAssertEqual(endpoint.redeemed, ["outgoing-refresh-1"], "and nothing is redeemed again")
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

    // MARK: - The login the CLI holds is authoritative (2026-10-12)

    /// Three `/login`s into ONE account seven minutes apart (2026-10-12), with
    /// the refresh deadlines Claude Code's Keychain recorded for each, measured
    /// from just after the third (13:13). The deadlines are not in login order:
    /// the 13:07 login's is the earliest by two and a half days, and the 13:13
    /// login's is three hours earlier than the 13:06 one's. Each access token
    /// runs eight hours from its `/login`. In login order.
    private func threeLoginsOfOneAccount(_ account: String) -> [String] {
        let day: TimeInterval = 86_400
        return [
            // 13:06, deadline 11-11 06:06:06
            login(account, generation: 1, expiresIn: 8 * 3600 - 7 * 60,
                  deadlineIn: 29 * day + 16 * 3600 + 53 * 60 + 6),
            // 13:07, deadline 11-08 15:43:44
            login(account, generation: 2, expiresIn: 8 * 3600 - 6 * 60,
                  deadlineIn: 27 * day + 2 * 3600 + 30 * 60 + 44),
            // 13:13, deadline 11-11 03:07:57
            login(account, generation: 3, expiresIn: 8 * 3600,
                  deadlineIn: 29 * day + 13 * 3600 + 54 * 60 + 57)
        ]
    }

    /// One profile that owns the CLI's login, stamped with its account.
    private func seedOwner(_ account: String, holding json: String) -> Profile {
        var owner = profile("owner", login: json)
        owner.claudeAccountUUID = "acct-\(account)"
        seed([owner], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        return owner
    }

    private func discard(_ profile: Profile) {
        sync.markLoginRevived(profile.id)
        sync.markLoginUncontaminated(profile.id)
        store.deleteProfileCredentials(profileId: profile.id)
    }

    /// The sweep's last step (`adoptSystemLoginByIdentityDetailed`, run at the
    /// end of every sweep). A pass the app itself started is awaited first
    /// (`waitForIdentityAdoption`), so this call is the one that runs; if it
    /// was skipped anyway the test fails rather than passing on a no-op.
    @discardableResult
    private func runSweepAdoption(file: StaticString = #filePath, line: UInt = #line) async
        -> ProfileManager.IdentityAdoptionOutcome {
        for _ in 0..<3 {
            await manager.waitForIdentityAdoption()
            let outcome = await manager.adoptSystemLoginByIdentityDetailed()
            if outcome != .skipped { return outcome }
        }
        XCTFail("the sweep's identity adoption never ran", file: file, line: line)
        return .skipped
    }

    /// The three automatic paths that move the CLI's login into a profile.
    private enum AdoptionPath: String, CaseIterable {
        case sweep = "sweep adoption"
        case reSync = "outgoing re-sync"
        case keychainAdoption = "Keychain adoption"
    }

    /// Runs one path. The sweep's outcome is returned so a test can assert
    /// which branch decided; the other two are direct calls. A re-sync that
    /// throws (an unreadable store) is non-fatal, exactly as the activation
    /// treats it.
    @discardableResult
    private func adopt(_ path: AdoptionPath, into id: UUID,
                       file: StaticString = #filePath, line: UInt = #line) async throws
        -> ProfileManager.IdentityAdoptionOutcome? {
        switch path {
        case .sweep: return await runSweepAdoption(file: file, line: line)
        case .reSync: try? await sync.resyncBeforeSwitching(for: id)
        case .keychainAdoption: _ = await sync.ensureFreshCredentials(for: id, adoptSystemKeychain: true)
        }
        return nil
    }

    /// 2026-10-12, replayed. After the 13:13 `/login` the widget kept the
    /// profile's 13:06 pair because that pair's deadline is the later one, so
    /// the profile no longer held the login Claude Code was using. After a
    /// sweep the profile must hold the CLI's pair: with the file still holding
    /// this app's last write (the 13:06 pair) and without it.
    func testAfterASweepTheProfileHoldsTheLoginTheCLIHoldsThoughItsDeadlineIsEarlier() async {
        let logins = threeLoginsOfOneAccount("account")
        for file in [logins[0], nil] as [String?] {
            let owner = seedOwner("account", holding: logins[0])
            cliStore.set(keychain: logins[2], file: file)

            let outcome = await runSweepAdoption()

            XCTAssertEqual(outcome, .owner(owner.id, adopted: true))
            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-3",
                           "file \(file == nil ? "absent" : "holding the 13:06 pair"): the profile must hold the login Claude Code is using")
            discard(owner)
        }
        XCTAssertTrue(endpoint.redeemed.isEmpty)
    }

    /// Every ordered pair of the three logins, through every automatic path:
    /// the login the CLI holds wins, whichever deadline is later.
    func testTheLoginTheCLIHoldsWinsWhicheverDeadlineIsLater() async throws {
        let logins = threeLoginsOfOneAccount("account")
        for path in AdoptionPath.allCases {
            for stored in logins.indices {
                for held in logins.indices where held != stored {
                    let owner = seedOwner("account", holding: logins[stored])
                    cliStore.set(keychain: logins[held], file: nil)

                    let outcome = try await adopt(path, into: owner.id)

                    if path == .sweep { XCTAssertEqual(outcome, .owner(owner.id, adopted: true)) }
                    XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-\(held + 1)",
                                   "\(path.rawValue): the profile holds login \(stored + 1), the CLI holds \(held + 1)")
                    discard(owner)
                }
            }
        }
        XCTAssertTrue(endpoint.redeemed.isEmpty)
    }

    /// The deadline still drops a login that has lapsed: a lapsed login the CLI
    /// holds never replaces a live stored one, and a live one the CLI holds
    /// always replaces a lapsed stored one.
    func testALapsedLoginAlwaysLosesToALiveOne() async throws {
        let live = login("account", generation: 1, expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let lapsed = login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: -3600)
        for path in AdoptionPath.allCases {
            var owner = seedOwner("account", holding: live)
            cliStore.set(keychain: lapsed, file: nil)
            var outcome = try await adopt(path, into: owner.id)
            if path == .sweep { XCTAssertEqual(outcome, .unverifiedOwner(owner.id), "nothing to adopt, so nothing was read or moved") }
            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-1",
                           "\(path.rawValue): a lapsed CLI login never replaces a live one")
            discard(owner)

            owner = seedOwner("account", holding: lapsed)
            cliStore.set(keychain: live, file: nil)
            outcome = try await adopt(path, into: owner.id)
            if path == .sweep { XCTAssertEqual(outcome, .owner(owner.id, adopted: true)) }
            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-1",
                           "\(path.rawValue): a live CLI login replaces a lapsed one")
            discard(owner)
        }
    }

    /// Another account's login is never adopted, however late its deadline.
    func testAnotherAccountsLoginIsNeverAdopted() async throws {
        let own = login("account", generation: 1, expiresIn: 6 * 3600, deadlineIn: 5 * 86_400)
        let others = login("other", generation: 1, expiresIn: 8 * 3600, deadlineIn: 29 * 86_400)
        for path in AdoptionPath.allCases {
            let owner = seedOwner("account", holding: own)
            cliStore.set(keychain: others, file: nil)

            let outcome = try await adopt(path, into: owner.id)

            if path == .sweep { XCTAssertEqual(outcome, .noOwner, "no profile is the other account's") }
            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-1", path.rawValue)
            discard(owner)
        }
    }

    /// With no identity evidence on either side (no stamp, nothing the identity
    /// endpoint or `~/.claude.json` can tell), nothing is adopted: two live
    /// logins are not reordered either way, and in v3 not even a lapsed stored
    /// login is replaced — the CLI's login is not proven live. Explicit Sync is
    /// the user's path.
    func testWithoutIdentityEvidenceTwoLiveLoginsAreNotReordered() async throws {
        sync.setIdentityFetcherForTesting { _ in nil }
        let logins = threeLoginsOfOneAccount("account")
        let lapsed = login("account", generation: 4, expiresIn: 6 * 3600, deadlineIn: -3600)
        // Re-sync and Keychain adoption only: the sweep's adoption needs the
        // CLI login's identity to do anything at all.
        for path in [AdoptionPath.reSync, .keychainAdoption] {
            for (stored, held) in [(0, 2), (2, 0)] {
                let owner = profile("owner", login: logins[stored])
                seed([owner], focused: owner.id)
                manager.claimActiveClaudeOwnership(owner.id)
                cliStore.set(keychain: logins[held], file: nil)

                try await adopt(path, into: owner.id)

                XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-\(stored + 1)",
                               "\(path.rawValue): unverified, the stored login \(stored + 1) stays")
                discard(owner)
            }
            let owner = profile("owner", login: lapsed)
            seed([owner], focused: owner.id)
            manager.claimActiveClaudeOwnership(owner.id)
            cliStore.set(keychain: logins[2], file: nil)

            try await adopt(path, into: owner.id)

            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-4",
                           "\(path.rawValue): nothing proven live, nothing adopted")
            discard(owner)
        }
    }

    /// The store read: the Keychain item, which the CLI reads first and writes,
    /// holds the CLI's login whatever the deadlines say. The file, this app's
    /// own last write, is used only when the item is CONFIRMED absent.
    func testTheStoreReadPrefersTheKeychainWhicheverDeadlineIsLater() throws {
        typealias S = ClaudeCodeSyncService
        let logins = threeLoginsOfOneAccount("account")
        for keychain in logins.indices {
            for file in logins.indices where file != keychain {
                XCTAssertEqual(S.chooseSystemLogin(keychain: logins[keychain], file: logins[file], keychainConfirmedAbsent: false),
                               .keychain, "Keychain holds login \(keychain + 1), the file \(file + 1)")
            }
        }
        let lapsed = login("account", generation: 4, expiresIn: 6 * 3600, deadlineIn: -3600)
        XCTAssertEqual(S.chooseSystemLogin(keychain: lapsed, file: logins[0], keychainConfirmedAbsent: false), .keychain,
                       "no deadline decides between the two: a lapsed Keychain login still holds the CLI's place")
        XCTAssertEqual(S.chooseSystemLogin(keychain: nil, file: logins[0], keychainConfirmedAbsent: false), .none,
                       "an item that is there but unreadable or undecodable never hands the file its authority")

        cliStore.set(keychain: logins[2], file: logins[0])
        XCTAssertEqual(try refreshToken(sync.readSystemCredentials()), "account-refresh-3")
    }

    // MARK: - Review round 1 (#186): only token-bound evidence proves an account

    /// Item 1, a replay of 2026-10-12. After a `/login` moved the CLI to another
    /// account, `~/.claude.json`'s `oauthAccount` still named the OLD account.
    /// With the new login's identity unavailable, that stale record agreed with
    /// the old account's stamp and "verified" the write, so the new account's
    /// login replaced the old account's live one. Cached metadata may refuse a
    /// mismatch; it never proves a match.
    func testStaleCLIAccountMetadataNeverVerifiesAnotherAccountsLogin() async throws {
        let ownLogin = login("old", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let newAccountsLogin = login("new", expiresIn: 8 * 3600, deadlineIn: 25 * 86_400)
        // The new login's own identity cannot be fetched.
        sync.setIdentityFetcherForTesting { token in
            token.hasPrefix("old-access")
                ? ClaudeCodeSyncService.AccountIdentity(accountUUID: "acct-old", organizationUUID: "", email: "")
                : nil
        }
        for path in [AdoptionPath.reSync, .keychainAdoption] {
            let owner = seedOwner("old", holding: ownLogin)
            cliStore.set(keychain: newAccountsLogin, file: nil)
            cliStore.cachedAccount = "acct-old"  // stale: still the account before the /login

            try await adopt(path, into: owner.id)

            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "old-refresh-1",
                           "\(path.rawValue): a stale account record never lets another account's login in")
            discard(owner)
        }
    }

    /// Item 2, a replay of 2026-10-12: a profile carried account X's stamp
    /// while it held account Y's login. Routed by that stamp, the CLI's X login
    /// replaced the live Y login. A stamp only routes; the stored login's own
    /// fresh read says Y, and that decides.
    func testAMislabeledStampNeverRoutesAnAdoption() async throws {
        let heldLogin = login("y", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let xLogin = login("x", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        for path in AdoptionPath.allCases {
            let mislabeled = seedOwner("x", holding: heldLogin)  // stamped acct-x, holds Y's login
            cliStore.set(keychain: xLogin, file: nil)

            let outcome = try await adopt(path, into: mislabeled.id)

            if path == .sweep {
                XCTAssertEqual(outcome, .notOwner(mislabeled.id), "resolved from its own token before anything changed")
                XCTAssertEqual(manager.activeClaudeProfileId, mislabeled.id, "the pointer was not moved on the stamp's word")
            }
            XCTAssertEqual(refreshToken(storedLogin(mislabeled.id)), "y-refresh-1",
                           "\(path.rawValue): the profile's own live login stays")
            discard(mislabeled)
        }
    }

    /// Item 2: the organization fallback never takes a profile whose stamp
    /// names a different account, even when the organizations match.
    func testTheOrganizationFallbackNeverTakesAProfileStampedWithAnotherAccount() async {
        sync.setIdentityFetcherForTesting { token in
            guard let account = token.components(separatedBy: "-access").first, account != token else { return nil }
            return ClaudeCodeSyncService.AccountIdentity(
                accountUUID: "acct-\(account)", organizationUUID: "org-shared", email: ""
            )
        }
        var other = profile("other", login: login("y", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400))
        other.claudeAccountUUID = "acct-y"
        other.organizationId = "org-shared"
        seed([other], focused: other.id)
        manager.claimActiveClaudeOwnership(other.id)
        cliStore.set(keychain: login("x", expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)

        let outcome = await runSweepAdoption()

        XCTAssertEqual(outcome, .noOwner)
        XCTAssertEqual(refreshToken(storedLogin(other.id)), "y-refresh-1")
    }

    /// Item 3. The CLI rotated its login in the Keychain and the profile adopted
    /// the rotation, while the file still held the predecessor the CLI consumed.
    /// With the Keychain item then unreadable, the file must not stand in for it.
    func testAnUnreadableKeychainNeverHandsItsAuthorityToTheFile() async throws {
        let predecessor = login("account", generation: 1, expiresIn: 2 * 3600, deadlineIn: 20 * 86_400)
        let rotated = login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        for path in AdoptionPath.allCases {
            let owner = seedOwner("account", holding: rotated)
            cliStore.set(keychain: nil, file: predecessor)
            cliStore.keychainUnreadable = true

            let outcome = try await adopt(path, into: owner.id)

            if path == .sweep { XCTAssertEqual(outcome, .noSharedLogin) }
            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-2", path.rawValue)
            cliStore.keychainUnreadable = false
            discard(owner)
        }
    }

    /// Item 3 (v3): the file is used only when the Keychain item is CONFIRMED
    /// absent. A lapsed Keychain login no longer yields to it either: no
    /// deadline decides between the two halves.
    func testTheFileIsUsedOnlyWhenTheKeychainItemIsConfirmedAbsent() {
        typealias S = ClaudeCodeSyncService
        let lapsed = login("account", generation: 1, expiresIn: 6 * 3600, deadlineIn: -3600)
        let dated = login("account", generation: 3, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        XCTAssertEqual(S.chooseSystemLogin(keychain: lapsed, file: dated, keychainConfirmedAbsent: false), .keychain)
        XCTAssertEqual(S.chooseSystemLogin(keychain: nil, file: dated, keychainConfirmedAbsent: false), .none,
                       "unreadable or truncated: unknown")
        XCTAssertEqual(S.chooseSystemLogin(keychain: nil, file: dated, keychainConfirmedAbsent: true), .file)
    }

    /// Item 4. A Keychain payload the `security` tool cut short yields only an
    /// access token. That partial login never replaces a complete stored pair.
    func testATruncatedKeychainLoginNeverReplacesACompleteOne() async throws {
        let complete = login("account", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let cut = String(complete[..<complete.range(of: "\"expiresAt\"")!.lowerBound])
        for path in AdoptionPath.allCases {
            let owner = seedOwner("account", holding: complete)
            cliStore.set(keychain: cut, file: nil)

            let outcome = try await adopt(path, into: owner.id)

            if path == .sweep { XCTAssertEqual(outcome, .noSharedLogin, "a partial login is not the CLI's login") }
            XCTAssertEqual(storedLogin(owner.id), complete, "\(path.rawValue): the refresh token, expiry and deadline stay")
            discard(owner)
        }
    }

    /// Item 4: a partial login is never synced into a profile, and one already
    /// stored is never written to the CLI's store.
    func testAPartialLoginIsNeverSyncedOrApplied() throws {
        let complete = login("account", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let cut = String(complete[..<complete.range(of: "\"expiresAt\"")!.lowerBound])
        let target = profile("target", login: nil)
        let holder = profile("holder", login: #"{"claudeAiOauth":{"accessToken":"holder-access-1"}}"#)
        seed([target, holder], focused: target.id)
        cliStore.set(keychain: cut, file: nil)

        XCTAssertThrowsError(try sync.syncToProfile(target.id), "a partial login is not synced")
        XCTAssertNil(storedLogin(target.id))

        XCTAssertThrowsError(try sync.applyProfileCredentials(holder.id), "a partial login is not applied")
        XCTAssertTrue(cliStore.writes.isEmpty && cliStore.fileWrites.isEmpty, "nothing reaches the CLI's store")
    }

    /// Item 5. A pair this app redeemed stays refused after a relaunch: its
    /// access token died with the redemption, so its own FRESH read refuses it
    /// (v3), with nothing remembered in memory or in the roster. A cached
    /// identity would still name its account.
    func testAPairThisAppRedeemedStaysConsumedAfterARelaunch() async throws {
        identityEndpoint { token, fresh in token == "outgoing-access-1" && fresh ? .rejected(status: 401) : nil }
        let original = login("outgoing", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        var outgoing = profile("outgoing", login: original)
        outgoing.claudeAccountUUID = "acct-outgoing"
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        seed([other, outgoing], focused: other.id)
        manager.claimActiveClaudeOwnership(other.id)
        cliStore.set(keychain: other.cliCredentialsJSON, file: nil)
        _ = await sync.ensureFreshCredentials(
            for: outgoing.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2")

        // A relaunch: the CLI store is read afresh and the credential cache is
        // rebuilt from the Keychain. `~/.claude.json` names the account, as it
        // normally does.
        installCLIStoreSeams()
        await store.flushKeychainWrites()
        store.resetAndRewarmCredentialCacheForTesting()
        let deadline = Date().addingTimeInterval(10)
        while store.credentialHydrationState == .loading, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        cliStore.cachedAccount = "acct-outgoing"
        manager.claimActiveClaudeOwnership(outgoing.id)
        cliStore.set(keychain: original, file: original)
        for path in AdoptionPath.allCases {
            let outcome = try await adopt(path, into: outgoing.id)
            if path == .sweep { XCTAssertEqual(outcome, .noSharedLogin, "the CLI's own login is revoked: nothing to route") }
            XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2",
                           "\(path.rawValue): the consumed pair never replaces its successor")
        }
        XCTAssertEqual(endpoint.redeemed, ["outgoing-refresh-1"])
    }

    /// Item 5: a predecessor consumed before any record existed. Bookkeeping
    /// cannot tell it from a newer login, but its access token died with the
    /// redemption, so its own identity cannot be fetched, and the account
    /// record alone never verifies it. The stored login stays.
    func testALegacyConsumedPredecessorIsNeverAdoptedWithoutTokenBoundEvidence() async throws {
        let predecessor = login("account", generation: 1, expiresIn: 2 * 3600, deadlineIn: 20 * 86_400)
        let successor = login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        sync.setIdentityFetcherForTesting { token in
            token == "account-access-1"
                ? nil  // revoked by the redemption
                : ClaudeCodeSyncService.AccountIdentity(accountUUID: "acct-account", organizationUUID: "", email: "")
        }
        for path in [AdoptionPath.reSync, .keychainAdoption] {
            let owner = seedOwner("account", holding: successor)
            cliStore.set(keychain: predecessor, file: nil)
            cliStore.cachedAccount = "acct-account"

            try await adopt(path, into: owner.id)

            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-2", path.rawValue)
            discard(owner)
        }
    }

    /// A login's tag is one-way and domain-separated: neither the token nor its
    /// in-memory fingerprint. A login without a refresh token has none.
    func testALoginTagIsOneWay() {
        let tag = ClaudeLoginLifetime.loginTag(login("p", expiresIn: 3600))
        XCTAssertEqual(tag?.count, 32)
        XCTAssertFalse(tag?.contains("refresh") ?? true)
        XCTAssertFalse(ClaudeLoginLifetime.fingerprint("p-refresh-1").hasPrefix(tag ?? "-"))
        XCTAssertEqual(tag, ClaudeLoginLifetime.loginTag(login("p", expiresIn: -3600)),
                       "one credential, one tag, whatever its expiry says")
        XCTAssertNil(ClaudeLoginLifetime.loginTag(#"{"claudeAiOauth":{"accessToken":"p-access-1"}}"#))
    }

    /// Items 3 and 4: the store read says where a login came from. The file is
    /// read only when the Keychain item is confirmed absent; a truncated item
    /// gives a partial login, for reads only.
    func testTheStoreReadSaysWhereALoginCameFrom() throws {
        let complete = login("account", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let cut = String(complete[..<complete.range(of: "\"expiresAt\"")!.lowerBound])

        cliStore.set(keychain: complete, file: nil)
        var read = try XCTUnwrap(sync.readSystemLogin())
        XCTAssertEqual(read.source, .keychain)
        XCTAssertTrue(read.isAdoptable)

        cliStore.set(keychain: nil, file: complete)
        read = try XCTUnwrap(sync.readSystemLogin())
        XCTAssertEqual(read.source, .file)
        XCTAssertTrue(read.isAdoptable, "no Keychain item: the CLI reads the file")

        cliStore.keychainUnreadable = true
        XCTAssertThrowsError(try sync.readSystemLogin(), "an unreadable Keychain: the file is not consulted")
        cliStore.keychainUnreadable = false

        cliStore.set(keychain: cut, file: complete)
        read = try XCTUnwrap(sync.readSystemLogin())
        XCTAssertEqual(read.source, .partialKeychain, "a truncated item: never the file")
        XCTAssertFalse(read.isAdoptable)
        XCTAssertFalse(ClaudeLoginLifetime.isComplete(read.json))
        XCTAssertEqual(try sync.readSystemCredentials(), read.json, "a read for a usage fetch still gets the token")
    }

    /// The store-owned records (refused grants, recorded accounts): an ordinary
    /// save of any roster leaves them alone, an entry leaves only once its
    /// credential's deadline has passed, and nothing evicts by count.
    func testTheStoreOwnedRecordsSurviveSavesAndArePrunedOnlyByDeadline() async throws {
        let live = login("account", generation: 1, expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let pastDeadline = login("account", generation: 2, expiresIn: 6 * 3600, deadlineIn: -60)
        let noDeadline = login("account", generation: 3, expiresIn: 6 * 3600)
        store.recordRefusedClaudeLogin(live)
        store.recordRefusedClaudeLogin(pastDeadline)
        store.recordRefusedClaudeLogin(noDeadline)
        store.recordClaudeLoginAccount(live, account: "acct-account")
        store.recordClaudeLoginAccount(pastDeadline, account: "acct-account")

        let roster = [profile("someone", login: nil)]
        seed(roster, focused: roster[0].id)
        store.saveProfiles(roster)  // an ordinary save, of a roster that knows nothing of them

        XCTAssertTrue(store.isRefusedClaudeLogin(live))
        XCTAssertTrue(store.isRefusedClaudeLogin(noDeadline), "no deadline: kept")
        XCTAssertFalse(store.isRefusedClaudeLogin(pastDeadline), "pruned once its deadline passed")
        XCTAssertEqual(store.recordedAccount(ofClaudeLogin: live), "acct-account")
        XCTAssertNil(store.recordedAccount(ofClaudeLogin: pastDeadline))
        XCTAssertNil(store.recordedAccount(ofClaudeLogin: login("account", generation: 9, expiresIn: 3600)),
                     "nothing carries to another credential")

        for i in 0..<400 {
            store.recordRefusedClaudeLogin(login("bulk", generation: i, expiresIn: 3600, deadlineIn: 20 * 86_400))
        }
        XCTAssertTrue(store.isRefusedClaudeLogin(login("bulk", generation: 0, expiresIn: 3600, deadlineIn: 20 * 86_400)),
                      "no count eviction")
        XCTAssertTrue(store.isRefusedClaudeLogin(live))

        // A relaunch rereads both from the preferences store.
        await store.flushKeychainWrites()
        store.resetAndRewarmCredentialCacheForTesting()
        let deadline = Date().addingTimeInterval(10)
        while store.credentialHydrationState == .loading, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(store.isRefusedClaudeLogin(live))
        XCTAssertEqual(store.recordedAccount(ofClaudeLogin: live), "acct-account")
    }

    /// The token endpoint's own refusal is recorded for the exact credential it
    /// refused, never for the profile, and is then death evidence for that
    /// credential wherever it appears.
    func testARefusedGrantIsRecordedForTheExactCredential() async {
        let revoked = login("account", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        let account = profile("account", login: revoked)
        seed([other, account], focused: other.id)
        manager.claimActiveClaudeOwnership(other.id)
        cliStore.set(keychain: other.cliCredentialsJSON, file: nil)
        endpoint.refused = ["account-refresh-1"]

        _ = await sync.ensureFreshCredentials(
            for: account.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertTrue(store.isRefusedClaudeLogin(revoked))
        XCTAssertFalse(store.isRefusedClaudeLogin(login("account", generation: 2, expiresIn: 3600, deadlineIn: 20 * 86_400)))
        let evidence = await sync.loginEvidence(revoked)
        XCTAssertEqual(evidence, .dead(account: nil), "refused: dead, though its access token still has time")
    }

    // MARK: - Review round 2 (#186): v3 — evidence from each side's own token

    /// Every synthetic token "<account>-access-<n>" identifies as "acct-<account>".
    nonisolated private static func syntheticIdentity(_ token: String) -> ClaudeCodeSyncService.IdentityProbe {
        guard let account = token.components(separatedBy: "-access").first, account != token else { return .unavailable }
        return .identified(ClaudeCodeSyncService.AccountIdentity(accountUUID: "acct-\(account)", organizationUUID: "", email: ""))
    }

    /// The identity endpoint, answering per token and per lookup kind
    /// (`fresh`: the identity cache bypassed). `answer` returning nil falls
    /// back to the synthetic identity.
    private func identityEndpoint(_ answer: @escaping (_ token: String, _ fresh: Bool) -> ClaudeCodeSyncService.IdentityProbe?) {
        sync.setIdentityProbeForTesting { token, fresh in answer(token, fresh) ?? Self.syntheticIdentity(token) }
    }

    /// Whether some profile or the CLI's store still holds this login.
    private func preservedAnywhere(_ json: String) -> Bool {
        store.loadProfiles().contains { $0.cliCredentialsJSON.map { ClaudeLoginLifetime.isSamePair($0, json) } ?? false }
            || [cliStore.keychain, cliStore.file].contains { $0.map { ClaudeLoginLifetime.isSamePair($0, json) } ?? false }
    }

    /// Round 2, major 1. The Keychain answers with a payload the `security`
    /// tool truncated while the file still holds the predecessor the CLI has
    /// consumed since. Only a CONFIRMED absent Keychain item hands the file
    /// any authority; truncated output is unknown, so nothing is adopted.
    func testATruncatedKeychainNeverHandsItsAuthorityToTheFile() async throws {
        let predecessor = login("account", generation: 1, expiresIn: 2 * 3600, deadlineIn: 20 * 86_400)
        let rotated = login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        let truncated = String(rotated[..<rotated.range(of: "\"expiresAt\"")!.lowerBound])
        for path in AdoptionPath.allCases {
            let owner = seedOwner("account", holding: rotated)
            cliStore.set(keychain: truncated, file: predecessor)

            try await adopt(path, into: owner.id)

            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-2", path.rawValue)
            discard(owner)
        }
    }

    /// Round 2, major 2. A flag on the PROFILE is not evidence about the login
    /// it holds now: the profile is stamped A while it holds account B's live
    /// login, whose identity cannot be read, and an activation refusal flagged
    /// it. The CLI's A login must not replace B's.
    func testAProfileFlagIsNeverEvidenceThatItsLoginIsDead() async throws {
        identityEndpoint { token, _ in token.hasPrefix("b-access") ? .unavailable : nil }
        let held = login("b", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        for path in AdoptionPath.allCases {
            let mislabeled = seedOwner("a", holding: held)
            sync.notifyReloginNeeded(for: mislabeled.id)
            cliStore.set(keychain: login("a", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)

            try await adopt(path, into: mislabeled.id)

            XCTAssertEqual(refreshToken(storedLogin(mislabeled.id)), "b-refresh-1", "\(path.rawValue): B's live login stays")
            discard(mislabeled)
        }
    }

    /// Round 2, major 3. An ordinary save of a roster loaded before a
    /// redemption must not reopen the pair the redemption consumed. The
    /// consumed pair's access token was revoked by the redemption: a fresh
    /// read refuses it, while a cached identity still names its account.
    func testAStaleRosterSaveCannotReopenAPairThisAppRedeemed() async throws {
        let original = login("outgoing", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        var outgoing = profile("outgoing", login: original)
        outgoing.claudeAccountUUID = "acct-outgoing"
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        seed([other, outgoing], focused: other.id)
        manager.claimActiveClaudeOwnership(other.id)
        cliStore.set(keychain: other.cliCredentialsJSON, file: nil)
        let staleRoster = store.loadProfiles()  // loaded before the redemption
        _ = await sync.ensureFreshCredentials(
            for: outgoing.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2")
        store.saveProfiles(staleRoster)  // an ordinary save, from before the redemption

        identityEndpoint { token, fresh in
            token == "outgoing-access-1" && fresh ? .rejected(status: 401) : nil
        }
        manager.claimActiveClaudeOwnership(outgoing.id)
        cliStore.set(keychain: original, file: original)
        for path in AdoptionPath.allCases {
            try await adopt(path, into: outgoing.id)
            XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2",
                           "\(path.rawValue): the consumed pair never replaces its successor")
        }
    }

    /// Round 2, major 4 — an ACCEPTED RESIDUAL since round 3 (the gate cut
    /// the parking slot). After an upgrade the owner holds an expired pair the
    /// CLI has consumed, whose own token cannot answer, while the CLI holds the
    /// live rotation. Nothing can verify the rotation into the owner; the
    /// switch proceeds and overwrites it, exactly as #185 and earlier did, and
    /// the repair is `/login`. This test pins that behaviour: the follow-up
    /// card "Preserve an unadoptable live CLI login across a switch" flips its
    /// last assertion.
    func testASwitchStillOverwritesACLILoginNoProfileCanAdopt() async {
        let consumed = login("owner", generation: 1, expiresIn: -3600, deadlineIn: 20 * 86_400)
        let live = login("owner", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        identityEndpoint { token, _ in token == "owner-access-1" ? .rejected(status: 401) : nil }
        var owner = profile("owner", login: consumed)
        owner.claudeAccountUUID = "acct-owner"
        let target = profile("target", login: login("target", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400))
        seed([owner, target], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        cliStore.set(keychain: live, file: live)

        let outcome = await manager.activateProfileDetailed(target.id, userInitiated: false)

        XCTAssertEqual(outcome, .activated, "the switch proceeds")
        XCTAssertEqual(refreshToken(cliStore.keychain), "target-refresh-1")
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "owner-refresh-1", "the unverifiable rotation is not adopted")
        XCTAssertFalse(preservedAnywhere(live), "accepted residual: the overwritten login is kept nowhere")
    }

    /// Round 2, major 5. Explicit Sync takes no incomplete login, from any
    /// source: an access token alone, or one with an expiry but no refresh
    /// token, already serialized as valid JSON. Nor does an apply write one.
    func testExplicitSyncAndApplyRefuseAnIncompleteLoginFromAnySource() throws {
        let complete = login("account", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let accessOnly = #"{"claudeAiOauth":{"accessToken":"account-access-9"}}"#
        let noRefresh = login("account", generation: 9, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400, refreshToken: false)
        let target = profile("target", login: complete)
        let holder = profile("holder", login: noRefresh)
        seed([target, holder], focused: target.id)
        for incomplete in [accessOnly, noRefresh] {
            for (keychain, file) in [(incomplete, nil), (nil, incomplete)] as [(String?, String?)] {
                cliStore.set(keychain: keychain, file: file)
                XCTAssertThrowsError(try sync.syncToProfile(target.id), "an incomplete login is not synced")
                XCTAssertEqual(storedLogin(target.id), complete, "the complete login stays")
            }
        }
        cliStore.set(keychain: nil, file: nil)
        XCTAssertThrowsError(try sync.applyProfileCredentials(holder.id), "an incomplete login is not applied")
        XCTAssertTrue(cliStore.writes.isEmpty && cliStore.fileWrites.isEmpty)
    }

    /// Counter-case (a). A non-owner profile holds an independent second chain
    /// of the CLI's account that the widget heals later, so its pair looks the
    /// newest. The CLI's login still wins for the owner, and the non-owner's
    /// chain is left alone.
    func testANonOwnersIndependentChainIsLeftAloneWhileTheCLIsLoginWinsForTheOwner() async throws {
        let cliLogin = login("a", generation: 9, expiresIn: 4 * 3600, deadlineIn: 20 * 86_400)
        for path in AdoptionPath.allCases {
            var owner = profile("owner", login: login("a", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
            owner.claudeAccountUUID = "acct-a"
            var second = profile("second", login: login("a", generation: 5, expiresIn: 8 * 3600, deadlineIn: 25 * 86_400))
            second.claudeAccountUUID = "acct-a"
            seed([second, owner], focused: owner.id)
            manager.claimActiveClaudeOwnership(owner.id)
            cliStore.set(keychain: cliLogin, file: nil)

            try await adopt(path, into: owner.id)

            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "a-refresh-9", "\(path.rawValue): the owner takes the CLI's login")
            XCTAssertEqual(refreshToken(storedLogin(second.id)), "a-refresh-5", "\(path.rawValue): the second chain is untouched")
            discard(owner)
            discard(second)
        }
    }

    /// Counter-case (b). A `/login` repair after a server-side revocation: the
    /// stored access token has not expired and its own read is refused (401),
    /// so it is dead, and the CLI's live login of the account replaces it.
    func testALoginRepairAfterAServerRevocationReplacesTheRevokedLogin() async throws {
        let revoked = login("account", generation: 1, expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let repaired = login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 30 * 86_400)
        identityEndpoint { token, _ in token == "account-access-1" ? .rejected(status: 401) : nil }
        for path in AdoptionPath.allCases {
            let owner = seedOwner("account", holding: revoked)
            cliStore.set(keychain: repaired, file: nil)

            try await adopt(path, into: owner.id)

            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-2", "\(path.rawValue): the repair is taken")
            discard(owner)
        }
    }

    /// Counter-case (c). The CLI's login cannot be identified at the outgoing
    /// re-sync (a transient failure). Nothing is adopted on unknown evidence,
    /// and the switch is neither deferred nor stalled.
    func testATransientIdentityFailureAtTheSwitchAdoptsNothingAndTheSwitchProceeds() async {
        let stored = login("owner", generation: 1, expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let rotated = login("owner", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        identityEndpoint { token, _ in token == "owner-access-2" ? .unavailable : nil }
        var owner = profile("owner", login: stored)
        owner.claudeAccountUUID = "acct-owner"
        let target = profile("target", login: login("target", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400))
        seed([owner, target], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        cliStore.set(keychain: rotated, file: rotated)

        let outcome = await manager.activateProfileDetailed(target.id, userInitiated: false)

        XCTAssertEqual(outcome, .activated, "the switch is not deferred")
        XCTAssertEqual(manager.activeClaudeProfileId, target.id)
        XCTAssertEqual(refreshToken(cliStore.keychain), "target-refresh-1")
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "owner-refresh-1", "nothing adopted on unknown evidence")
    }

    /// Counter-case (d). The CLI's login is verified as account X and the
    /// stored login is live as account Y by its own token: different
    /// accounts, refused on every path, whatever the profile's stamp says.
    func testLoginsTheirOwnTokensPlaceInDifferentAccountsAreNeverMerged() async throws {
        let yLogin = login("y", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let xLogin = login("x", expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        for path in AdoptionPath.allCases {
            var owner = profile("owner", login: yLogin)
            owner.claudeAccountUUID = path == .sweep ? "acct-x" : nil  // the sweep routes by stamp
            seed([owner], focused: owner.id)
            manager.claimActiveClaudeOwnership(owner.id)
            cliStore.set(keychain: xLogin, file: nil)

            try await adopt(path, into: owner.id)

            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "y-refresh-1", path.rawValue)
            discard(owner)
        }
    }

    /// Counter-case (e). The stored access token has expired and nothing
    /// recorded its credential's account: its side is unknown, and it stays.
    func testAnExpiredStoredLoginWithNoRecordedAccountIsUnknownAndStays() async throws {
        let expired = login("account", generation: 1, expiresIn: -10 * 60, deadlineIn: 20 * 86_400)
        let cliLogin = login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        for path in AdoptionPath.allCases {
            let owner = seedOwner("account", holding: expired)
            cliStore.set(keychain: cliLogin, file: nil)

            try await adopt(path, into: owner.id)

            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-1", path.rawValue)
            discard(owner)
        }
    }

    /// The account record (approved option 1). The idle owner: its login was
    /// read live once, and the account its own token reported was recorded
    /// for that credential. It then expired with no CLI running, and the CLI
    /// renewed it on its next run. The expired credential's account is known,
    /// so the CLI's renewal of that account replaces it.
    func testTheIdleOwnerAdoptsTheCLIsRenewalByItsExpiredLoginsRecordedAccount() async throws {
        let renewed = login("owner", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        for path in AdoptionPath.allCases {
            let live = login("owner", generation: 1, expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
            let owner = seedOwner("owner", holding: live)
            store.recordClaudeLoginAccount(live, account: "acct-owner")  // a fresh 2xx while it was live
            // Same credential, now expired.
            let expired = login("owner", generation: 1, expiresIn: -30 * 60, deadlineIn: 20 * 86_400)
            XCTAssertTrue(store.replaceCLILogin(owner.id, expected: live, with: expired))
            cliStore.set(keychain: renewed, file: nil)

            try await adopt(path, into: owner.id)

            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "owner-refresh-2", path.rawValue)
            discard(owner)
            store.resetLoginRecordsForTesting()
        }
    }

    /// The account record never routes a different account's login: a stored
    /// credential recorded as account Y keeps Y's login out whatever the
    /// profile's stamp says, and a refused grant on that credential makes it
    /// dead but leaves its account fact standing.
    func testTheAccountRecordNeverLetsADifferentAccountsLoginIn() async throws {
        let yLogin = login("y", expiresIn: -30 * 60, deadlineIn: 20 * 86_400)
        let xLogin = login("x", expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        for refused in [false, true] {
            for path in AdoptionPath.allCases {
                let owner = seedOwner("x", holding: yLogin)  // stamped acct-x, holds Y's (expired) login
                store.recordClaudeLoginAccount(yLogin, account: "acct-y")
                if refused { store.recordRefusedClaudeLogin(yLogin) }
                cliStore.set(keychain: xLogin, file: nil)

                try await adopt(path, into: owner.id)

                XCTAssertEqual(refreshToken(storedLogin(owner.id)), "y-refresh-1",
                               "\(path.rawValue)\(refused ? ", refused" : ""): Y's credential is not given X's login")
                discard(owner)
                store.resetLoginRecordsForTesting()
            }
        }
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

    // MARK: - Review round 4

    /// Only the VERIFIED existing owner — the pointer names it AND the CLI's
    /// store holds its token — is a no-op activation while it awaits renewal.
    /// A candidate whose renewal cannot be confirmed (here the CLI's Keychain
    /// item cannot be read) is DEFERRED: not dead, nothing applied, the
    /// pointer stays, and the walk retries without consuming its queue entry.
    func testAnUnconfirmedRenewalDefersTheSwitchInsteadOfLandingOrDying() async {
        let owner = profile("owner", login: login("owner", expiresIn: 6 * 3600))
        let candidate = profile("candidate", login: login("candidate", expiresIn: -10 * 60, deadlineIn: 20 * 86_400))
        seed([owner, candidate], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        cliStore.set(keychain: nil, file: nil)
        cliStore.keychainUnreadable = true

        let outcome = await manager.activateProfileDetailed(candidate.id, userInitiated: false)

        XCTAssertEqual(outcome, .handoffDeferred)
        XCTAssertEqual(MenuBarManager.walkReaction(to: outcome), .skipForThisWalk,
                       "the walk skips it for this walk only: queue entry kept, not dead")
        XCTAssertFalse(outcome.didActivate, "no switch is reported")
        XCTAssertEqual(manager.activeClaudeProfileId, owner.id, "nothing was claimed")
        XCTAssertTrue(cliStore.writes.isEmpty && cliStore.fileWrites.isEmpty, "nothing was applied")
        XCTAssertFalse(sync.isLoginMarkedDead(candidate.id), "and it is not a dead login")
        XCTAssertTrue(endpoint.redeemed.isEmpty)

        // The CLI holding the candidate's token under someone else's pointer is
        // not a verified owner either.
        cliStore.keychainUnreadable = false
        cliStore.set(keychain: candidate.cliCredentialsJSON, file: nil)
        let second = await manager.activateProfileDetailed(candidate.id, userInitiated: false)
        XCTAssertEqual(second, .handoffDeferred)
        XCTAssertEqual(manager.activeClaudeProfileId, owner.id)
    }

    /// Pending must not hide a terminal login: past its server deadline, or
    /// with the CLI's login-expired marker in the store for the owner, the
    /// login leaves the pending set and takes the dead path with its notice.
    func testATerminalLoginIsNeverLeftPending() async {
        let lapsed = profile("lapsed", login: login("lapsed", expiresIn: -10 * 60, deadlineIn: -3600))
        let marked = profile("marked", login: login("marked", expiresIn: -10 * 60, deadlineIn: 20 * 86_400))
        seed([lapsed, marked], focused: lapsed.id)

        manager.claimActiveClaudeOwnership(lapsed.id)
        cliStore.set(keychain: lapsed.cliCredentialsJSON, file: nil)
        _ = await sync.ensureFreshCredentials(for: lapsed.id, adoptSystemKeychain: false)
        XCTAssertFalse(sync.isAwaitingCLIRenewal(lapsed.id), "past its deadline: not renewable")
        XCTAssertTrue(sync.isLoginMarkedDead(lapsed.id), "the dead path, with its /login notice")

        manager.claimActiveClaudeOwnership(marked.id)
        cliStore.set(keychain: #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#, file: nil)
        _ = await sync.ensureFreshCredentials(for: marked.id, adoptSystemKeychain: false)
        XCTAssertFalse(sync.isAwaitingCLIRenewal(marked.id), "the CLI marked the owner's login expired")
        XCTAssertTrue(sync.isLoginMarkedDead(marked.id))
        XCTAssertTrue(endpoint.redeemed.isEmpty)
    }

    /// The other two states. A store that holds the login is RENEWABLE and
    /// stays quiet; a store that cannot be inspected is UNVERIFIED, pending
    /// but surfaced once it outlasts the bound.
    func testAnUnconfirmedRenewalIsSurfacedAfterTheBound() async {
        let owner = profile("owner", login: login("owner", expiresIn: -10 * 60, deadlineIn: 20 * 86_400))
        seed([owner], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)

        cliStore.set(keychain: owner.cliCredentialsJSON, file: nil)
        _ = await sync.ensureFreshCredentials(for: owner.id, adoptSystemKeychain: false)
        XCTAssertEqual(sync.cliRenewalState(owner.id), .renewable)
        XCTAssertFalse(sync.isRenewalOverdue(owner.id, now: Date().addingTimeInterval(24 * 3600)),
                       "a renewable login stays quiet however long the CLI is idle")

        cliStore.keychainUnreadable = true
        _ = await sync.ensureFreshCredentials(for: owner.id, adoptSystemKeychain: false)
        guard case .unverified = sync.cliRenewalState(owner.id) else {
            return XCTFail("an unreadable store cannot confirm the renewal")
        }
        XCTAssertFalse(sync.isRenewalOverdue(owner.id))
        sync.backdateUnverifiedRenewalForTesting(owner.id, by: ClaudeCodeSyncService.unverifiedRenewalBound + 1)
        XCTAssertTrue(sync.isRenewalOverdue(owner.id), "surfaced past the bound")
        XCTAssertFalse(sync.isLoginMarkedDead(owner.id), "still not dead")
    }

    /// The cache and the Keychain persist in one order: an import racing a late
    /// rotation leaves the import in memory AND in the Keychain, so a relaunch
    /// restores the same login.
    func testAnImportRacingALateRotationSurvivesARelaunch() async throws {
        let original = login("account", expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let account = profile("account", login: original)
        seed([account], focused: account.id)
        let rotated = login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        let imported = login("imported", expiresIn: 8 * 3600, deadlineIn: 30 * 86_400)

        // The import lands first; the rotation, whose request started before
        // it, completes after it and must lose.
        var credentials = try store.loadProfileCredentials(account.id)
        credentials.cliCredentialsJSON = imported
        try store.saveProfileCredentials(account.id, credentials: credentials, replacingCLILogin: true)
        XCTAssertFalse(store.replaceCLILogin(account.id, expected: original, with: rotated))
        XCTAssertEqual(storedLogin(account.id), imported)

        // Relaunch: drop the cache and hydrate from the (test) Keychain.
        await store.flushKeychainWrites()
        store.resetAndRewarmCredentialCacheForTesting()
        let deadline = Date().addingTimeInterval(10)
        while store.credentialHydrationState == .loading, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(storedLogin(account.id), imported, "the relaunch restores the login memory held")
    }

    /// While another caller is redeeming a token, the owner leaves it alone:
    /// it is never redeemed twice (defense in depth — the fail-closed store
    /// check refuses it too). Since #186 round 3 the owner does not even adopt
    /// it: the redemption record marks the token PENDING before its grant is
    /// sent, and a pending login is never adopted. (Under #185 the owner
    /// adopted it and reserved its fingerprint; the reservation still guards
    /// any login an adoption does take.)
    func testAnAdoptedLoginIsReservedBeforeAnyDecision() async {
        let newer = login("owner", generation: 2, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let owner = profile("owner", login: login("owner", generation: 1, expiresIn: -5 * 60, deadlineIn: 20 * 86_400))
        let alias = profile("alias", login: newer)
        seed([owner, alias], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        // Its account was recorded by a fresh read while its token was live (v3).
        store.recordClaudeLoginAccount(owner.cliCredentialsJSON!, account: "acct-owner")
        cliStore.set(keychain: nil, file: nil)

        var ownerResult: Bool?
        let sync = sync
        let cliStore = cliStore
        endpoint.onRedeem = {
            guard ownerResult == nil else { return }
            // While the alias redeems `newer`, the CLI shows it and the owner adopts it.
            cliStore.set(keychain: newer, file: nil)
            ownerResult = await sync.ensureFreshCredentials(for: owner.id, adoptSystemKeychain: true)
        }
        _ = await sync.ensureFreshCredentials(
            for: alias.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertEqual(ownerResult, false, "a login whose grant is in flight is marked pending: never adopted …")
        XCTAssertEqual(endpoint.redeemed, ["owner-refresh-2"], "… and never redeemed twice")
    }

    // MARK: - Final round

    /// Runs the auto-switch walk's own control flow (`runCandidateWalk`, the
    /// function the live walk calls) with the live walk's candidate order —
    /// the queue first, then the ranking — and REAL activations.
    private func walk(queue: [UUID], ranking: [Profile]) async -> MenuBarManager.CandidateWalkResult {
        let manager = manager
        return await MenuBarManager.runCandidateWalk(
            nextCandidate: { excluded in
                let queued = MenuBarManager.selectQueuedSwitchTarget(
                    queue: queue, profiles: manager.profiles, provider: .claude,
                    excluding: excluded, isEligible: { _ in true }
                ).target
                return queued ?? ranking.first { !excluded.contains($0.id) }
            },
            attempt: { candidate in
                .activated(await manager.activateProfileDetailed(candidate.id, userInitiated: false))
            }
        )
    }

    /// One deferring candidate must not end the walk. A (the owner) is the one
    /// being left, B is first in the queue and defers (its renewal cannot be
    /// confirmed), C is usable: the walk lands on C, and B keeps its queue
    /// entry and is not recorded dead.
    func testADeferringCandidateIsSkippedAndTheWalkLandsOnTheNextOne() async {
        let ownerA = profile("owner", login: login("owner", expiresIn: 6 * 3600))
        let deferringB = profile("deferring", login: login("deferring", expiresIn: -10 * 60, deadlineIn: 20 * 86_400))
        let usableC = profile("usable", login: login("usable", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400))
        seed([ownerA, deferringB, usableC], focused: ownerA.id)
        manager.claimActiveClaudeOwnership(ownerA.id)
        cliStore.keychainUnreadable = true
        let savedQueue = SharedDataStore.shared.loadAutoSwitchQueue()
        defer { SharedDataStore.shared.saveAutoSwitchQueue(savedQueue) }
        SharedDataStore.shared.saveAutoSwitchQueue([deferringB.id])

        let result = await walk(queue: SharedDataStore.shared.loadAutoSwitchQueue(), ranking: [usableC])

        XCTAssertEqual(result, .switched(to: usableC.id))
        XCTAssertEqual(manager.activeClaudeProfileId, usableC.id)
        XCTAssertEqual(SharedDataStore.shared.loadAutoSwitchQueue(), [deferringB.id], "B's queue entry is intact")
        XCTAssertFalse(sync.isLoginMarkedDead(deferringB.id), "B is not dead")
        XCTAssertEqual(refreshToken(cliStore.keychain), "usable-refresh-1", "C's login was applied")
    }

    /// When every remaining candidate defers, nothing switches and the walk
    /// defers to the next sweep.
    func testAWalkWhereEveryCandidateDefersSwitchesNothing() async {
        let ownerA = profile("owner", login: login("owner", expiresIn: 6 * 3600))
        let deferringB = profile("deferringB", login: login("deferringB", expiresIn: -10 * 60, deadlineIn: 20 * 86_400))
        let deferringC = profile("deferringC", login: login("deferringC", expiresIn: -10 * 60, deadlineIn: 20 * 86_400))
        seed([ownerA, deferringB, deferringC], focused: ownerA.id)
        manager.claimActiveClaudeOwnership(ownerA.id)
        cliStore.keychainUnreadable = true

        let result = await walk(queue: [deferringB.id], ranking: [deferringC])

        XCTAssertEqual(result, .deferredToNextSweep)
        XCTAssertEqual(manager.activeClaudeProfileId, ownerA.id, "no switch")
        XCTAssertTrue(cliStore.writes.isEmpty && cliStore.fileWrites.isEmpty)
        XCTAssertFalse(sync.isLoginMarkedDead(deferringB.id))
        XCTAssertFalse(sync.isLoginMarkedDead(deferringC.id))
    }

    /// The walk's stop rules, in isolation: a deferring candidate is skipped,
    /// a dead one excluded, and only a machine-side failure (a write that
    /// failed, a switch in flight) stops the whole walk.
    func testTheWalkStopsEarlyOnlyForAMachineSideFailure() async {
        let b = Profile(id: UUID(), name: "B")
        let c = Profile(id: UUID(), name: "C")
        let d = Profile(id: UUID(), name: "D")
        func run(_ outcomes: [UUID: MenuBarManager.CandidateAttempt]) async -> (MenuBarManager.CandidateWalkResult, [UUID]) {
            var tried: [UUID] = []
            let result = await MenuBarManager.runCandidateWalk(
                nextCandidate: { excluded in [b, c, d].first { !excluded.contains($0.id) } },
                attempt: { candidate in
                    tried.append(candidate.id)
                    return outcomes[candidate.id] ?? .activated(.activated)
                }
            )
            return (result, tried)
        }
        var (result, tried) = await run([b.id: .activated(.handoffDeferred), c.id: .activated(.credentialsRefused)])
        XCTAssertEqual(result, .switched(to: d.id))
        XCTAssertEqual(tried, [b.id, c.id, d.id])

        (result, tried) = await run([b.id: .activated(.handoffDeferred), c.id: .activated(.credentialWriteFailed)])
        XCTAssertEqual(result, .deferredToNextSweep, "a failed write is the machine's: stop the walk")
        XCTAssertEqual(tried, [b.id, c.id], "D is not tried")

        (result, tried) = await run([b.id: .stopWalk])
        XCTAssertEqual(result, .deferredToNextSweep)
        XCTAssertEqual(tried, [b.id])

        (result, _) = await run([b.id: .activated(.handoffDeferred), c.id: .skipped, d.id: .activated(.credentialsRefused)])
        XCTAssertEqual(result, .deferredToNextSweep, "a deferral happened and nothing landed: retry next sweep")

        (result, _) = await run([b.id: .skipped, c.id: .activated(.credentialsRefused), d.id: .skipped])
        XCTAssertEqual(result, .noSwitch)
    }

    /// Containment and renewal are different questions. A token found only in
    /// the fallback file while the authoritative Keychain item could not be
    /// read PROHIBITS the redemption, but its renewal is unverified — with the
    /// timer and the bound — never renewable.
    func testAFileOnlyMatchBehindAnUnreadableKeychainIsHeldButUnverified() async {
        let owner = profile("owner", login: login("owner", expiresIn: -10 * 60, deadlineIn: 20 * 86_400))
        seed([owner], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        cliStore.set(keychain: nil, file: owner.cliCredentialsJSON)
        cliStore.keychainUnreadable = true

        let changed = await sync.ensureFreshCredentials(
            for: owner.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertFalse(changed)
        XCTAssertTrue(endpoint.redeemed.isEmpty, "the file holds the token: no redemption")
        guard case .unverified = sync.cliRenewalState(owner.id) else {
            return XCTFail("an unreadable Keychain item cannot confirm the CLI will renew it")
        }
        sync.backdateUnverifiedRenewalForTesting(owner.id, by: ClaudeCodeSyncService.unverifiedRenewalBound + 1)
        XCTAssertTrue(sync.isRenewalOverdue(owner.id))

        // With NO Keychain item at all, the file is what the CLI reads: renewable.
        cliStore.keychainUnreadable = false
        _ = await sync.ensureFreshCredentials(
            for: owner.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        XCTAssertEqual(sync.cliRenewalState(owner.id), .renewable)
    }

    /// Only a CONFIRMED not-found is absent: a path whose traversal is denied
    /// is unreadable, and unreadable refuses the redemption.
    func testOnlyAConfirmedNotFoundCountsAsAbsent() throws {
        XCTAssertTrue(ClaudeCodeSyncService.isNotFound(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
        XCTAssertTrue(ClaudeCodeSyncService.isNotFound(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        XCTAssertFalse(ClaudeCodeSyncService.isNotFound(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        XCTAssertFalse(ClaudeCodeSyncService.isNotFound(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))

        // A real denied traversal, in a scratch directory: `fileExists` says
        // "no", the attributes call says "not allowed".
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cuw-denied-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".credentials.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the trap: looks absent")
        XCTAssertThrowsError(try FileManager.default.attributesOfItem(atPath: file.path)) { error in
            XCTAssertFalse(ClaudeCodeSyncService.isNotFound(error), "but it is denied, not missing")
        }
        let missing = dir.deletingLastPathComponent().appendingPathComponent("cuw-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try FileManager.default.attributesOfItem(atPath: missing.path)) { error in
            XCTAssertTrue(ClaudeCodeSyncService.isNotFound(error))
        }
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
        // Its account was recorded by a fresh read while its token was live (v3).
        store.recordClaudeLoginAccount(owner.cliCredentialsJSON!, account: "acct-owner")
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

    // MARK: - Review round 3 (#186): the redemption record, the identity-read budget

    /// Identity reads, counted per access token: `fresh` bypassed the identity
    /// cache (a request in production), `cached` did not.
    @MainActor
    private final class IdentityReads {
        var fresh: [String: Int] = [:]
        var cached: [String: Int] = [:]
        func freshCount(_ token: String) -> Int { fresh[token] ?? 0 }
        var freshTotal: Int { fresh.values.reduce(0, +) }
    }

    /// The identity endpoint as `identityEndpoint` stands it in, counting.
    private func countingIdentityEndpoint(
        _ answer: @escaping (_ token: String, _ fresh: Bool) -> ClaudeCodeSyncService.IdentityProbe? = { _, _ in nil }
    ) -> IdentityReads {
        let reads = IdentityReads()
        sync.setIdentityProbeForTesting { token, fresh in
            if fresh { reads.fresh[token, default: 0] += 1 } else { reads.cached[token, default: 0] += 1 }
            return answer(token, fresh) ?? Self.syntheticIdentity(token)
        }
        return reads
    }

    /// One profile of `account` holding `json`, beside the owner of the CLI's
    /// login, which another account holds.
    private func seedBesideAnotherOwner(_ account: String, holding json: String) -> Profile {
        let target = profile(account, login: json)
        let other = profile("other", login: login("other", expiresIn: 6 * 3600))
        seed([other, target], focused: other.id)
        manager.claimActiveClaudeOwnership(other.id)
        cliStore.set(keychain: other.cliCredentialsJSON, file: nil)
        return target
    }

    private func entries(_ backing: InMemoryClaudeRedemptionRecord) -> [String: ProfileStore.ClaudeRedemptionEntry] {
        ((try? backing.read()) ?? nil).flatMap { try? JSONDecoder().decode([String: ProfileStore.ClaudeRedemptionEntry].self, from: $0) } ?? [:]
    }

    /// Codex round 3, major 1. The widget redeems a login while another
    /// account owns the CLI, and the predecessor's access token keeps
    /// answering its identity read (2xx). A stale writer then puts the
    /// predecessor back in the CLI's store. Nothing about the token proves it
    /// spent; the redemption record does, so no path takes it, explicit Sync
    /// included.
    func testAConsumedPredecessorWhoseOwnTokenStillAnswersIsNeverAdopted() async throws {
        let original = login("outgoing", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        var outgoing = seedBesideAnotherOwner("outgoing", holding: original)
        outgoing.claudeAccountUUID = "acct-outgoing"
        store.saveProfiles(store.loadProfiles().map { $0.id == outgoing.id ? outgoing : $0 })
        _ = await sync.ensureFreshCredentials(
            for: outgoing.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2")

        manager.claimActiveClaudeOwnership(outgoing.id)
        cliStore.set(keychain: original, file: original)
        for path in AdoptionPath.allCases {
            try await adopt(path, into: outgoing.id)
            XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2",
                           "\(path.rawValue): the redeemed predecessor never replaces its successor")
        }
        XCTAssertThrowsError(try sync.syncToProfile(outgoing.id), "explicit Sync takes no pair this app redeemed")
        XCTAssertEqual(refreshToken(storedLogin(outgoing.id)), "outgoing-refresh-2")
        XCTAssertEqual(endpoint.redeemed, ["outgoing-refresh-1"], "and it is never redeemed again")
    }

    /// The pending mark is on disk, confirmed, before the grant is sent, and
    /// is promoted to consumed once the endpoint answers with a successor.
    func testARedemptionIsRecordedDurablyBeforeItsGrantIsSent() async {
        let backing = InMemoryClaudeRedemptionRecord()
        store.setClaudeRedemptionRecordForTesting(backing)
        let original = login("account", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: original)
        let tag = ClaudeLoginLifetime.loginTag(original)!
        final class Seen { var stateWhenSent: ProfileStore.ClaudeRedemptionMark? }
        let seen = Seen()
        endpoint.onRedeem = { [unowned self] in seen.stateWhenSent = self.entries(backing)[tag]?.state }

        _ = await sync.ensureFreshCredentials(
            for: account.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertEqual(endpoint.redeemed, ["account-refresh-1"])
        XCTAssertEqual(seen.stateWhenSent, .pending, "written and read back before the grant went out")
        XCTAssertEqual(entries(backing)[tag]?.state, .consumed, "promoted once the successor arrived")
        store.reloadClaudeRedemptionRecordForTesting()
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: original), .consumed, "and it survives a relaunch")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: storedLogin(account.id) ?? ""), .unmarked, "the successor carries no mark")
    }

    /// A pending mark that cannot be confirmed on disk sends nothing: no
    /// record, no grant, and the mark is taken back.
    func testAGrantWhoseRecordCannotBeConfirmedIsNeverSent() async {
        let backing = InMemoryClaudeRedemptionRecord()
        backing.failWrites = true
        store.setClaudeRedemptionRecordForTesting(backing)
        let original = login("account", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: original)

        _ = await sync.ensureFreshCredentials(
            for: account.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertTrue(endpoint.redeemed.isEmpty, "no confirmed record, no grant")
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-1")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: original), .unmarked)
    }

    /// The grant reached the token endpoint (which consumed it) and the answer
    /// was lost: a gateway timeout, then a relaunch. The pending mark is
    /// treated as consumed — never adopted, synced or applied — and the
    /// activation's forced renewal finds the grant spent.
    func testAPendingMarkAfterALostAnswerIsTreatedAsConsumed() async throws {
        let endpoint = endpoint
        sync.setTokenEndpointForTesting { token in
            _ = await endpoint.redeem(token)
            return (504, nil)
        }
        let original = login("account", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: original)
        _ = await sync.ensureFreshCredentials(for: account.id, adoptSystemKeychain: false, freshFor: 4 * 3600)
        XCTAssertEqual(endpoint.redeemed, ["account-refresh-1"])
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-1", "no successor arrived")
        store.reloadClaudeRedemptionRecordForTesting()  // the relaunch
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: original), .pending)
        sync.setTokenEndpointForTesting { await endpoint.redeem($0) }

        // Adoption: the CLI's store holds the pending pair; the account's owner
        // holds a live chain of its own.
        let holding = login("account", generation: 5, expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        for path in AdoptionPath.allCases {
            let owner = seedOwner("account", holding: holding)
            cliStore.set(keychain: original, file: nil)
            try await adopt(path, into: owner.id)
            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-5", "\(path.rawValue): never adopted")
            XCTAssertThrowsError(try sync.syncToProfile(owner.id), "\(path.rawValue): never synced")
            discard(owner)
        }

        // Apply: neither directly nor through an activation.
        let pendingHolder = seedBesideAnotherOwner("account", holding: original)
        XCTAssertThrowsError(try sync.applyProfileCredentials(pendingHolder.id), "never applied")
        let outcome = await manager.activateProfileDetailed(pendingHolder.id, userInitiated: false)
        XCTAssertNotEqual(outcome, .activated)
        XCTAssertFalse(cliStore.writes.contains { ClaudeLoginLifetime.isSamePair($0, original) },
                       "the CLI is never handed the pending pair")
        XCTAssertEqual(endpoint.redeemed, ["account-refresh-1", "account-refresh-1"],
                       "the activation renews a pending pair first, and the endpoint says it is spent")
    }

    /// What each answer to a grant does to its credential's record: a 200
    /// consumes it, a refusal leaves it pending (and records the refusal), a
    /// 429 was never processed so the mark is taken back, and an unreadable
    /// answer (a 5xx) leaves it pending.
    func testEachAnswerToAGrantLeavesItsRecordAsItShould() async {
        let cases: [(status: Int, mark: ProfileStore.ClaudeRedemptionStatus)] = [
            (200, .consumed), (400, .pending), (429, .unmarked), (503, .pending)
        ]
        for (index, item) in cases.enumerated() {
            let endpoint = endpoint
            sync.setTokenEndpointForTesting { token in
                item.status == 200 ? await endpoint.redeem(token) : (item.status, nil)
            }
            let original = login("case\(index)", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
            let account = seedBesideAnotherOwner("case\(index)", holding: original)

            _ = await sync.ensureFreshCredentials(
                for: account.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
            )

            XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: original), item.mark, "HTTP \(item.status)")
            discard(account)
        }
    }

    /// The redemption record keeps the refused record's rules: ordinary saves
    /// leave it alone, an entry leaves only once its credential's deadline has
    /// passed, nothing evicts by count, a relaunch reads it back, and a
    /// consumed credential is never marked pending again.
    func testTheRedemptionRecordFollowsTheStoreOwnedRules() async {
        let live = login("account", generation: 1, expiresIn: 6 * 3600, deadlineIn: 20 * 86_400)
        let pastDeadline = login("account", generation: 2, expiresIn: 6 * 3600, deadlineIn: -60)
        let noDeadline = login("account", generation: 3, expiresIn: 6 * 3600)
        let pendingLive = await store.markClaudeRedemptionPending(live)
        XCTAssertEqual(pendingLive, .introduced)
        await store.markClaudeRedemptionConsumed(pastDeadline)
        let pendingNoDeadline = await store.markClaudeRedemptionPending(noDeadline)
        XCTAssertEqual(pendingNoDeadline, .introduced)

        let roster = [profile("someone", login: nil)]
        seed(roster, focused: roster[0].id)
        store.saveProfiles(roster)

        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: live), .pending)
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: noDeadline), .pending, "no deadline: kept")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: pastDeadline), .unmarked, "pruned once its deadline passed")
        for i in 0..<300 {
            _ = await store.markClaudeRedemptionPending(login("bulk", generation: i, expiresIn: 3600, deadlineIn: 20 * 86_400))
        }
        store.reloadClaudeRedemptionRecordForTesting()
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: login("bulk", generation: 0, expiresIn: 3600, deadlineIn: 20 * 86_400)),
                       .pending, "no count eviction, and a relaunch reads it back")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: live), .pending)

        await store.markClaudeRedemptionConsumed(live)
        let again = await store.markClaudeRedemptionPending(live)
        XCTAssertEqual(again, .notRecorded, "a consumed credential is never sent again")
        await store.clearClaudeRedemptionPending(live)
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: live), .consumed, "clearing takes back only a pending mark")
    }

    /// Codex round 3, minor 7. One sweep pass reads the CLI's new credential
    /// once: the first-sight read and the adoption decision share it.
    func testOneSweepPassReadsEachCredentialOnce() async {
        let reads = countingIdentityEndpoint()
        let owner = seedOwner("account", holding: login("account", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
        cliStore.set(keychain: login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)

        let outcome = await runSweepAdoption()

        XCTAssertEqual(outcome, .owner(owner.id, adopted: true))
        XCTAssertEqual(reads.freshCount("account-access-2"), 1, "the CLI's credential is read once per pass")
        XCTAssertEqual(reads.freshCount("account-access-1"), 1, "and the stored one once")
    }

    /// A switch reads the CLI's login at most once.
    func testOneSwitchReadsTheCLIsLoginAtMostOnce() async {
        let reads = countingIdentityEndpoint()
        var owner = profile("owner", login: login("owner", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
        owner.claudeAccountUUID = "acct-owner"
        let target = profile("target", login: login("target", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400))
        seed([owner, target], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        cliStore.set(keychain: login("owner", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)

        let outcome = await manager.activateProfileDetailed(target.id, userInitiated: false)

        XCTAssertEqual(outcome, .activated)
        XCTAssertLessThanOrEqual(reads.freshCount("owner-access-2"), 1)
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "owner-refresh-2", "the outgoing re-sync adopted it")
    }

    /// When the CLI's login cannot authorize an adoption (its read got no
    /// answer), the stored login is never read: there is nothing to decide.
    func testWhenTheCLIsLoginCannotAuthorizeTheStoredOneIsNeverRead() async throws {
        let reads = countingIdentityEndpoint { token, _ in token == "account-access-2" ? .unavailable : nil }
        for path in [AdoptionPath.reSync, .keychainAdoption] {
            let owner = seedOwner("account", holding: login("account", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
            cliStore.set(keychain: login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)

            try await adopt(path, into: owner.id)

            XCTAssertEqual(reads.freshCount("account-access-1"), 0, "\(path.rawValue): the stored login is not read")
            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-1")
            discard(owner)
        }
    }

    /// A decision that refused an adoption is not re-made on every sweep for
    /// the same pair of credentials; a changed pair is decided at once. A
    /// decision that adopts is never remembered: the next one reads afresh.
    func testARefusedDecisionIsNotRemadeEverySweepForTheSamePair() async throws {
        let reads = countingIdentityEndpoint()
        // Stamped A, holding B's live login: the CLI's A login is refused.
        let mislabeled = seedOwner("a", holding: login("b", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400))
        cliStore.set(keychain: login("a", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)
        for _ in 0..<3 {
            try await adopt(.keychainAdoption, into: mislabeled.id)
            try await adopt(.reSync, into: mislabeled.id)
        }
        XCTAssertEqual(refreshToken(storedLogin(mislabeled.id)), "b-refresh-1")
        XCTAssertEqual(reads.freshTotal, 2, "one decision: the CLI's login and the stored one, read once each")

        cliStore.set(keychain: login("a", generation: 3, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)
        try await adopt(.keychainAdoption, into: mislabeled.id)
        XCTAssertEqual(reads.freshCount("a-access-3"), 1, "a changed pair is decided afresh")
        discard(mislabeled)

        // An adopting decision, twice over the same pair: read both times.
        let owner = seedOwner("c", holding: login("c", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
        let cliLogin = login("c", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        cliStore.set(keychain: cliLogin, file: nil)
        try await adopt(.keychainAdoption, into: owner.id)
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "c-refresh-2")
        XCTAssertTrue(store.replaceCLILogin(owner.id, expected: cliLogin,
                                            with: login("c", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)))
        try await adopt(.keychainAdoption, into: owner.id)
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "c-refresh-2")
        XCTAssertEqual(reads.freshCount("c-access-2"), 2, "success is never remembered as liveness")
    }

    /// A 429 from the identity endpoint is no answer about the token, and no
    /// read is sent again until its Retry-After has passed.
    func testAnIdentityRead429BacksOffUntilItsRetryAfter() async throws {
        let reads = countingIdentityEndpoint { token, _ in token == "account-access-2" ? .throttled(retryAfter: 600) : nil }
        let owner = seedOwner("account", holding: login("account", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
        cliStore.set(keychain: login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)

        try await adopt(.keychainAdoption, into: owner.id)
        XCTAssertEqual(reads.freshTotal, 1)
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-1", "a 429 is unknown: nothing adopted")

        cliStore.set(keychain: login("account", generation: 3, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)
        try await adopt(.keychainAdoption, into: owner.id)
        await runSweepAdoption()
        XCTAssertEqual(reads.freshTotal, 1, "no read goes out while the endpoint asked to wait")
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-1")
    }

    /// Once the hold has passed, the reads resume and a live login is adopted:
    /// what was held was a failure, never a verdict for good.
    func testHeldReadsAndDecisionsResumeOnceTheHoldHasPassed() async throws {
        var throttled = true
        let reads = countingIdentityEndpoint { token, _ in
            throttled && token == "account-access-2" ? .throttled(retryAfter: 600) : nil
        }
        let owner = seedOwner("account", holding: login("account", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
        cliStore.set(keychain: login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)
        try await adopt(.keychainAdoption, into: owner.id)
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-1")

        throttled = false
        sync.expireIdentityBudgetForTesting()
        try await adopt(.keychainAdoption, into: owner.id)

        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-2", "decided afresh, and adopted")
        XCTAssertEqual(reads.freshCount("account-access-2"), 2)
    }

    /// What a grant that brought back no successor did to its credential.
    func testWhatAGrantWithoutASuccessorDidToItsCredential() {
        typealias Outcome = ClaudeRefreshPolicy.GrantOutcome
        let cases: [(Error, Outcome, String)] = [
            (ClaudeCodeError.tokenRefreshFailed(status: 400), .refused, "invalid_grant"),
            (ClaudeCodeError.tokenRefreshFailed(status: 401), .refused, "401"),
            (ClaudeCodeError.tokenRefreshFailed(status: 403), .refused, "403"),
            (ClaudeCodeError.tokenRefreshFailed(status: 429), .notProcessed, "rate limited, not processed"),
            (ClaudeCodeError.tokenRefreshFailed(status: 503), .ambiguous, "a 5xx may have consumed it"),
            (ClaudeCodeError.tokenRefreshFailed(status: 200), .ambiguous, "a 200 without a readable successor"),
            (ClaudeCodeError.tokenRefreshFailed(status: -1), .ambiguous, "no HTTP response"),
            (ClaudeCodeError.invalidJSON, .ambiguous, "could be after the answer"),
            (URLError(.cannotConnectToHost), .notProcessed, "never connected"),
            (URLError(.notConnectedToInternet), .notProcessed, "offline"),
            (URLError(.dnsLookupFailed), .notProcessed, "no name"),
            (URLError(.secureConnectionFailed), .notProcessed, "TLS failed before the body"),
            (URLError(.timedOut), .ambiguous, "the request may have arrived"),
            (URLError(.networkConnectionLost), .ambiguous, "dropped mid-request"),
            (URLError(.cancelled), .ambiguous, "cancelled mid-request"),
        ]
        for (error, expected, why) in cases {
            XCTAssertEqual(ClaudeRefreshPolicy.grantOutcome(of: error), expected, why)
        }
    }

    // MARK: - Review round 4 (#186): uncertainty survives, the record fails closed

    /// A token endpoint that gives its answers in order (the last one again
    /// once they run out), counting the grants it is sent.
    private final class ScriptedEndpoint {
        var answers: [() throws -> (status: Int, payload: [String: Any]?)] = []
        var sent = 0
    }

    private func installScriptedEndpoint(_ answers: [() throws -> (status: Int, payload: [String: Any]?)]) -> ScriptedEndpoint {
        let scripted = ScriptedEndpoint()
        scripted.answers = answers
        sync.setTokenEndpointForTesting { _ in
            let answer = scripted.answers[min(scripted.sent, scripted.answers.count - 1)]
            scripted.sent += 1
            return try answer()
        }
        return scripted
    }

    /// Codex round 4, major 1. One credential, three attempts in a row: the
    /// first answer is lost (it may have consumed the token), the retry is
    /// rate limited (not processed), the next never leaves the Mac. Neither
    /// retry says anything about the first attempt, so the pending mark
    /// stands, and the credential is never applied, synced or adopted.
    func testAnUnsuccessfulRetryNeverClearsAnEarlierUncertainRedemption() async throws {
        let scripted = installScriptedEndpoint([
            { (504, nil) },
            { (429, nil) },
            { throw URLError(.cannotConnectToHost) },
        ])
        let original = login("account", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: original)
        for attempt in ["lost answer", "429", "never sent"] {
            _ = await sync.ensureFreshCredentials(for: account.id, adoptSystemKeychain: false, freshFor: 4 * 3600)
            XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: original), .pending, "after the \(attempt) attempt")
        }
        XCTAssertEqual(scripted.sent, 3)

        XCTAssertThrowsError(try sync.applyProfileCredentials(account.id), "never applied")
        let outcome = await manager.activateProfileDetailed(account.id, userInitiated: false)
        XCTAssertNotEqual(outcome, .activated)
        XCTAssertFalse(cliStore.writes.contains { ClaudeLoginLifetime.isSamePair($0, original) })
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: original), .pending, "the activation's retry changes nothing")

        let owner = seedOwner("account", holding: login("account", generation: 5, expiresIn: 6 * 3600, deadlineIn: 20 * 86_400))
        cliStore.set(keychain: original, file: nil)
        for path in AdoptionPath.allCases {
            try await adopt(path, into: owner.id)
            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "account-refresh-5", "\(path.rawValue): never adopted")
        }
        XCTAssertThrowsError(try sync.syncToProfile(owner.id), "never synced")
    }

    /// The same for an attempt withdrawn before sending: ownership moves to
    /// the profile while its pending mark is being written. Nothing is sent,
    /// and the earlier attempt's mark stands.
    func testAWithdrawnRetryNeverClearsAnEarlierUncertainRedemption() async {
        let backing = InMemoryClaudeRedemptionRecord()
        store.setClaudeRedemptionRecordForTesting(backing)
        let scripted = installScriptedEndpoint([{ (504, nil) }])
        let original = login("account", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: original)
        _ = await sync.ensureFreshCredentials(for: account.id, adoptSystemKeychain: false, freshFor: 4 * 3600)
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: original), .pending)

        let manager = manager
        let id = account.id
        backing.onWrite = { [weak backing] in
            backing?.onWrite = nil
            DispatchQueue.main.sync { MainActor.assumeIsolated { manager.claimActiveClaudeOwnership(id) } }
        }
        _ = await sync.ensureFreshCredentials(for: account.id, adoptSystemKeychain: false, freshFor: 4 * 3600)

        XCTAssertEqual(scripted.sent, 1, "withdrawn: the CLI's owner is never redeemed")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: original), .pending, "the earlier mark stands")
    }

    /// Codex round 4, major 3. The CLI's store gains the token while its
    /// pending mark is being written. Both halves are inspected again after
    /// the write, right before sending: nothing is sent, and the mark this
    /// attempt introduced is taken back.
    func testATokenTheCLIStoreGainsDuringThePendingWriteIsNeverSent() async {
        let backing = InMemoryClaudeRedemptionRecord()
        store.setClaudeRedemptionRecordForTesting(backing)
        let original = login("account", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: original)
        let cliStore = cliStore
        backing.onWrite = { [weak backing] in
            backing?.onWrite = nil
            cliStore.set(keychain: original, file: nil)  // an external writer restores it
        }

        _ = await sync.ensureFreshCredentials(
            for: account.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )

        XCTAssertTrue(endpoint.redeemed.isEmpty, "the CLI holds it now: never redeemed")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: original), .unmarked, "this attempt's mark is taken back")
        XCTAssertEqual(refreshToken(storedLogin(account.id)), "account-refresh-1")
    }

    /// Codex round 4, major 2. A record that cannot be read is not an empty
    /// one: no grant is sent, and no credential is adopted, synced or applied,
    /// because none can be confirmed unredeemed. It is never written over
    /// while it cannot be read, and is read again once it can.
    func testAnUnreadableRecordFailsClosedUntilItCanBeRead() async throws {
        let backing = InMemoryClaudeRedemptionRecord()
        backing.failReads = true
        store.setClaudeRedemptionRecordForTesting(backing)
        let original = login("account", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: original)

        _ = await sync.ensureFreshCredentials(
            for: account.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        XCTAssertTrue(endpoint.redeemed.isEmpty, "no grant while the record cannot be read")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: original), .unknown)
        XCTAssertThrowsError(try sync.applyProfileCredentials(account.id), "never applied")

        let owner = seedOwner("b", holding: login("b", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
        cliStore.set(keychain: login("b", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400), file: nil)
        for path in AdoptionPath.allCases {
            try await adopt(path, into: owner.id)
            XCTAssertEqual(refreshToken(storedLogin(owner.id)), "b-refresh-1", "\(path.rawValue): nothing adopted")
        }
        XCTAssertThrowsError(try sync.syncToProfile(owner.id), "nothing synced")
        XCTAssertNil(backing.stored, "never written while it cannot be read")

        backing.failReads = false
        store.reloadClaudeRedemptionRecordForTesting()
        sync.expireIdentityBudgetForTesting()
        try await adopt(.keychainAdoption, into: owner.id)
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "b-refresh-2", "readable again: decided as usual")
    }

    /// The unreadable record is a status, not just a refusal: the store's flag
    /// (and the published one the banners read) is set while it lasts and
    /// cleared once the record reads again.
    func testAnUnreadableRecordIsSurfacedUntilItReadsAgain() async throws {
        let backing = InMemoryClaudeRedemptionRecord()
        backing.failReads = true
        store.setClaudeRedemptionRecordForTesting(backing)
        let probe = login("account", expiresIn: 3600, deadlineIn: 20 * 86_400)

        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: probe), .unknown)
        XCTAssertTrue(store.claudeRedemptionRecordUnreadable)
        try await waitUntil { self.manager.claudeRedemptionRecordUnreadable }
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: probe), .unknown, "not read again before the retry interval")

        backing.failReads = false
        store.reloadClaudeRedemptionRecordForTesting()
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: probe), .unmarked)
        XCTAssertFalse(store.claudeRedemptionRecordUnreadable)
        try await waitUntil { !self.manager.claudeRedemptionRecordUnreadable }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "never became true", file: file, line: line)
    }

    /// The app's file record tells a confirmed absence (first launch: empty)
    /// from a file it cannot read, and round-trips what it writes.
    func testTheFileRecordTellsAbsenceFromFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuw-redemption-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = FileClaudeRedemptionRecord(url: directory.appendingPathComponent("record.json"))
        XCTAssertNil(try record.read(), "no file yet: confirmed absent")
        try record.write(Data("{}".utf8))
        XCTAssertEqual(try record.read(), Data("{}".utf8))

        let blocked = FileClaudeRedemptionRecord(url: directory)  // a directory where the file should be
        XCTAssertThrowsError(try blocked.read(), "unreadable is not absent")
    }

    /// Codex round 4, minor (a). After a relaunch the CLI's credential has a
    /// recorded account, so the pass routes on a cached lookup. A lookup that
    /// got no answer is not repeated every sweep.
    func testARoutingLookupThatFailedIsNotRetriedEverySweep() async {
        let reads = countingIdentityEndpoint { token, fresh in !fresh && token == "account-access-2" ? .unavailable : nil }
        let cliLogin = login("account", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        store.recordClaudeLoginAccount(cliLogin, account: "acct-account")
        _ = seedOwner("account", holding: login("account", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
        cliStore.set(keychain: cliLogin, file: nil)

        let first = await runSweepAdoption()
        let second = await runSweepAdoption()

        XCTAssertEqual(first, .noSharedLogin)
        XCTAssertEqual(second, .noSharedLogin)
        XCTAssertEqual(reads.cached["account-access-2"] ?? 0, 1, "the failed lookup is held, not repeated next sweep")
    }

    // MARK: - Review round 5 (#186): the conservative rebuild

    /// A record whose bytes do not decode, installed for one test.
    private func installCorruptRecord(_ bytes: Data = Data("{\"0123\": {\"state\": ".utf8)) -> InMemoryClaudeRedemptionRecord {
        let backing = InMemoryClaudeRedemptionRecord()
        backing.stored = bytes
        store.setClaudeRedemptionRecordForTesting(backing)
        return backing
    }

    /// A check finds the record corrupt (if nothing has yet); the automatic
    /// rebuild follows.
    private func awaitAutomaticRebuild(probing login: String) async throws {
        _ = store.claudeRedemptionStatus(ofClaudeLogin: login)
        try await waitUntil { !self.store.claudeRedemptionRecordUnreadable }
    }

    /// Codex round 5. A record that does not decode is quarantined (kept,
    /// never deleted) and rebuilt automatically, confirmed, with EVERY
    /// credential the widget knows marked pending: every profile's stored
    /// login and both halves of the CLI's store. Nothing is sent while it is
    /// corrupt; afterwards none of those credentials is adopted, synced or
    /// applied until renewed. A credential first seen after the rebuild is
    /// clean.
    func testACorruptRecordIsQuarantinedAndRebuiltWithEveryKnownLoginPending() async throws {
        let damaged = Data("{\"0123\": {\"state\": ".utf8)
        let backing = installCorruptRecord(damaged)
        let original = login("account", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: original)
        let otherLogin = try XCTUnwrap(cliStore.keychain)
        let fileOnly = login("stale", generation: 3, expiresIn: -3600, deadlineIn: 20 * 86_400)
        cliStore.set(keychain: otherLogin, file: fileOnly)

        _ = await sync.ensureFreshCredentials(
            for: account.id, adoptSystemKeychain: false, freshFor: ClaudeRefreshPolicy.handoffFreshness
        )
        XCTAssertTrue(endpoint.redeemed.isEmpty, "nothing is sent while the record does not decode")
        try await waitUntil { !self.store.claudeRedemptionRecordUnreadable }

        XCTAssertEqual(backing.quarantined.count, 1)
        XCTAssertTrue(backing.quarantined.keys.first?.hasPrefix("claude-redeemed-logins.corrupt-") ?? false)
        XCTAssertEqual(backing.quarantined.values.first ?? nil, damaged, "the damaged record is preserved")
        for (known, why) in [(original, "a profile's login"), (otherLogin, "the CLI's Keychain item"), (fileOnly, "the CLI's file")] {
            XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: known), .pending, why)
        }
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: login("fresh", expiresIn: 3600, deadlineIn: 20 * 86_400)),
                       .unmarked, "first seen after the rebuild: clean")
        XCTAssertThrowsError(try sync.applyProfileCredentials(account.id), "not applied until renewed")
        XCTAssertThrowsError(try sync.syncToProfile(account.id), "not synced until renewed")
        let reSyncOwner = seedOwner("other", holding: login("other", generation: 4, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400))
        try await adopt(.reSync, into: reSyncOwner.id)
        XCTAssertEqual(refreshToken(storedLogin(reSyncOwner.id)), "other-refresh-4", "not adopted until renewed")
    }

    /// After the rebuild the owner's login is pending, and the owner keeps
    /// working: the CLI renews its own login and the owner adopts the clean
    /// successor. The widget never renews the CLI's login itself.
    func testAPendingOwnerKeepsWorkingThroughTheCLIsOwnRenewal() async throws {
        _ = installCorruptRecord()
        let held = login("owner", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)
        let owner = seedOwner("owner", holding: held)
        cliStore.set(keychain: held, file: nil)
        try await awaitAutomaticRebuild(probing: held)
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: held), .pending)

        let renewed = login("owner", generation: 2, expiresIn: 8 * 3600, deadlineIn: 20 * 86_400)
        cliStore.set(keychain: renewed, file: nil)
        let outcome = await runSweepAdoption()

        XCTAssertEqual(outcome, .owner(owner.id, adopted: true))
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "owner-refresh-2")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: renewed), .unmarked, "the CLI's successor is clean")
        XCTAssertTrue(endpoint.redeemed.isEmpty, "the widget never renews the CLI's login")
    }

    /// A hand-off renews a pending target whatever its expiry, and applies the
    /// clean successor.
    func testAHandOffRenewsAPendingTargetAndAppliesItsCleanSuccessor() async throws {
        _ = installCorruptRecord()
        let pendingLogin = login("target", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)
        let outgoing = profile("outgoing", login: login("outgoing", expiresIn: 6 * 3600, deadlineIn: 20 * 86_400))
        let target = profile("target", login: pendingLogin)
        seed([outgoing, target], focused: outgoing.id)
        manager.claimActiveClaudeOwnership(outgoing.id)
        cliStore.set(keychain: outgoing.cliCredentialsJSON, file: nil)
        try await awaitAutomaticRebuild(probing: pendingLogin)
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: pendingLogin), .pending)

        let outcome = await manager.activateProfileDetailed(target.id, userInitiated: false)

        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(endpoint.redeemed, ["target-refresh-1"], "renewed first, though it had three hours left")
        XCTAssertEqual(refreshToken(cliStore.keychain), "target-refresh-2", "the clean successor is applied")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: pendingLogin), .consumed)
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: storedLogin(target.id) ?? ""), .unmarked)
    }

    /// A `/login` after the rebuild is a new credential: synced normally.
    func testALoginAfterTheRebuildIsSyncable() async throws {
        _ = installCorruptRecord()
        let old = login("owner", generation: 1, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)
        let owner = seedOwner("owner", holding: old)
        cliStore.set(keychain: old, file: nil)
        try await awaitAutomaticRebuild(probing: old)
        XCTAssertThrowsError(try sync.syncToProfile(owner.id), "the CLI's known login is pending")

        cliStore.set(keychain: login("owner", generation: 7, expiresIn: 8 * 3600, deadlineIn: 30 * 86_400), file: nil)
        XCTAssertNoThrow(try sync.syncToProfile(owner.id))
        XCTAssertEqual(refreshToken(storedLogin(owner.id)), "owner-refresh-7")
    }

    /// A read error that persists is never rebuilt on its own. Once it has
    /// lasted ten minutes, Repair is offered. A Repair whose quarantine fails
    /// changes nothing and stays closed, saying why; a Repair that succeeds
    /// preserves the unreadable record and rebuilds with every known login
    /// pending.
    func testAPersistentReadErrorOffersRepairAfterTenMinutes() async throws {
        let backing = InMemoryClaudeRedemptionRecord()
        let unreadableBytes = Data("{}".utf8)
        backing.stored = unreadableBytes
        backing.failReads = true
        store.setClaudeRedemptionRecordForTesting(backing)
        let held = login("account", expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: held)

        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: held), .unknown)
        XCTAssertFalse(store.claudeRedemptionRepairOffered, "not before ten minutes")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: held, now: Date().addingTimeInterval(9 * 60)), .unknown)
        XCTAssertFalse(store.claudeRedemptionRepairOffered, "nine minutes: not yet")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: held, now: Date().addingTimeInterval(601)), .unknown)
        XCTAssertTrue(store.claudeRedemptionRepairOffered)
        try await waitUntil { self.manager.claudeRedemptionRepairOffered }
        XCTAssertTrue(backing.quarantined.isEmpty, "a read error is never rebuilt on its own")

        backing.failQuarantine = true
        let failed = await manager.repairClaudeRedemptionRecord()
        guard case .quarantineFailed = failed else { return XCTFail("expected a failed quarantine, got \(failed)") }
        XCTAssertTrue(store.claudeRedemptionRecordUnreadable, "still closed")
        XCTAssertNotNil(store.claudeRedemptionRebuildFailure, "and says why")
        XCTAssertTrue(store.claudeRedemptionRepairOffered, "Repair is still offered")
        XCTAssertEqual(backing.stored, unreadableBytes, "nothing replaced")
        XCTAssertThrowsError(try sync.applyProfileCredentials(account.id))

        backing.failQuarantine = false
        let repaired = await manager.repairClaudeRedemptionRecord()
        guard case .rebuilt = repaired else { return XCTFail("expected a rebuild, got \(repaired)") }
        XCTAssertFalse(store.claudeRedemptionRecordUnreadable)
        XCTAssertEqual(backing.quarantined.values.first ?? nil, unreadableBytes, "the unreadable record is preserved")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: held), .pending)
        try await waitUntil { !self.manager.claudeRedemptionRecordUnreadable && !self.manager.claudeRedemptionRepairOffered }
    }

    /// The notification's button is Repair.
    func testTheRepairNotificationActionRunsRepair() {
        XCTAssertEqual(NotificationManager.responseAction(
            actionIdentifier: NotificationManager.repairClaudeRedemptionRecordActionIdentifier,
            categoryIdentifier: NotificationManager.claudeRedemptionRecordCategoryIdentifier
        ), .repairClaudeRedemptionRecord)
        XCTAssertEqual(NotificationManager.claudeRedemptionRecordCategory.actions.map(\.identifier),
                       [NotificationManager.repairClaudeRedemptionRecordActionIdentifier])
    }

    /// The app's file record, in a temporary directory: a damaged record is
    /// preserved under the quarantine name (an unreadable one too, through a
    /// hard link that needs no read) and replaced atomically; a taken
    /// quarantine name is never overwritten.
    func testTheFileRecordPreservesADamagedRecordAndReplacesIt() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("cuw-redemption-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("record.json")
        defer {
            for item in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(item).path)
            }
            try? fileManager.removeItem(at: directory)
        }
        let record = FileClaudeRedemptionRecord(url: path)

        try Data("{not json".utf8).write(to: path)
        XCTAssertEqual(try record.replaceQuarantining(with: Data("{}".utf8), quarantineName: "q.json"), "q.json")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("q.json")), Data("{not json".utf8))
        XCTAssertEqual(try record.read(), Data("{}".utf8))

        try Data("{\"secret history\":1}".utf8).write(to: path)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        XCTAssertThrowsError(try record.read(), "unreadable")
        XCTAssertEqual(try record.replaceQuarantining(with: Data("{\"a\":1}".utf8), quarantineName: "q.json"), "q-2.json")
        XCTAssertEqual(try record.read(), Data("{\"a\":1}".utf8), "replaced, and readable")
        let second = directory.appendingPathComponent("q-2.json")
        XCTAssertTrue(fileManager.fileExists(atPath: second.path), "the taken name is never overwritten")
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: second.path)
        XCTAssertEqual(try Data(contentsOf: second), Data("{\"secret history\":1}".utf8), "the unreadable bytes are preserved")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("q.json")), Data("{not json".utf8))
    }

    // MARK: - Review round 6 (#186): the rebuild's completeness and its way out

    /// Codex round 6, the write claim made true, on the real file: a
    /// replacement whose read-back fails puts the damaged record back at its
    /// path and leaves no quarantine name behind.
    func testTheFileRecordPutsTheDamagedRecordBackWhenTheReplacementFails() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("cuw-redemption-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let path = directory.appendingPathComponent("record.json")
        let record = FileClaudeRedemptionRecord(url: path)
        try Data("{not json".utf8).write(to: path)

        record.failVerificationForTesting = true
        XCTAssertThrowsError(try record.replaceQuarantining(with: Data("{}".utf8), quarantineName: "q.json"))

        XCTAssertEqual(try Data(contentsOf: path), Data("{not json".utf8), "the damaged record is back")
        XCTAssertFalse(fileManager.fileExists(atPath: directory.appendingPathComponent("q.json").path), "nothing else left")
    }

    /// The same in the store: a rebuild whose replacement fails after the new
    /// bytes landed changes nothing, stays closed, and offers Repair.
    func testARebuildWhoseReplacementFailsChangesNothing() async throws {
        let damaged = Data("{\"0123\": {\"state\": ".utf8)
        let backing = installCorruptRecord(damaged)
        backing.failAfterReplace = true
        let held = login("account", expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)
        _ = seedBesideAnotherOwner("account", holding: held)

        _ = store.claudeRedemptionStatus(ofClaudeLogin: held)
        try await waitUntil { self.store.claudeRedemptionRepairOffered }

        XCTAssertEqual(backing.stored, damaged, "the damaged record is back")
        XCTAssertTrue(backing.quarantined.isEmpty, "and no quarantine name is left")
        XCTAssertTrue(store.claudeRedemptionRecordUnreadable, "still closed")
        XCTAssertNotNil(store.claudeRedemptionRebuildFailure)
    }

    /// Codex round 6, major 2. The rebuild reads every profile's stored login
    /// DIRECTLY: hydration folds a failed Keychain read into "no credential",
    /// and a login missed would come back clean. While one profile's read
    /// fails, nothing is rebuilt and everything stays closed; once it reads,
    /// the rebuild marks that login pending — here one only the Keychain
    /// item holds.
    func testARebuildNeverRunsWhileAProfilesLoginCannotBeRead() async throws {
        let backing = InMemoryClaudeRedemptionRecord()
        backing.stored = Data("{}".utf8)
        backing.failReads = true
        store.setClaudeRedemptionRecordForTesting(backing)
        let cached = login("account", generation: 2, expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: cached)
        await store.flushKeychainWrites()
        let keychainOnly = login("account", generation: 1, expiresIn: 30 * 60, deadlineIn: 20 * 86_400)
        KeychainService.shared.setProfileCredentialReadFailureForTesting(profileId: account.id, key: "cli-creds", failing: true)
        defer { KeychainService.shared.setProfileCredentialReadFailureForTesting(profileId: account.id, key: "cli-creds", failing: false) }
        _ = store.claudeRedemptionStatus(ofClaudeLogin: cached)

        let blocked = await manager.repairClaudeRedemptionRecord()
        XCTAssertEqual(blocked, .notReady)
        XCTAssertTrue(store.claudeRedemptionRecordUnreadable, "still closed")
        XCTAssertTrue(backing.quarantined.isEmpty, "nothing rebuilt")
        XCTAssertEqual(backing.stored, Data("{}".utf8))
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: keychainOnly), .unknown)

        // The item holds a login the in-memory cache does not (as when
        // hydration folded the failed read into nil), and now reads.
        KeychainService.shared.saveProfileCredential(keychainOnly, profileId: account.id, key: "cli-creds")
        KeychainService.shared.setProfileCredentialReadFailureForTesting(profileId: account.id, key: "cli-creds", failing: false)
        let repaired = await manager.repairClaudeRedemptionRecord()
        guard case .rebuilt = repaired else { return XCTFail("expected a rebuild, got \(repaired)") }
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: keychainOnly), .pending, "the login only the Keychain held")
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: cached), .pending)
    }

    /// Codex round 6, major 1. The automatic rebuild of a corrupt record that
    /// waits in vain for a profile's login to be readable records the failure
    /// and offers Repair; credentials becoming ready later rebuild it
    /// automatically.
    func testAnExhaustedAutomaticRebuildOffersRepairAndResumesWhenCredentialsAreReady() async throws {
        manager.automaticRedemptionRebuildAttempts = 2
        manager.automaticRedemptionRebuildRetryInterval = 0.01
        defer {
            manager.automaticRedemptionRebuildAttempts = 120
            manager.automaticRedemptionRebuildRetryInterval = 5
        }
        let damaged = Data("{\"0123\": {\"state\": ".utf8)
        let held = login("account", expiresIn: 3 * 3600, deadlineIn: 20 * 86_400)
        let account = seedBesideAnotherOwner("account", holding: held)
        await store.flushKeychainWrites()
        KeychainService.shared.setProfileCredentialReadFailureForTesting(profileId: account.id, key: "cli-creds", failing: true)
        defer { KeychainService.shared.setProfileCredentialReadFailureForTesting(profileId: account.id, key: "cli-creds", failing: false) }
        let backing = installCorruptRecord(damaged)

        _ = store.claudeRedemptionStatus(ofClaudeLogin: held)
        try await waitUntil { self.manager.claudeRedemptionRepairOffered }
        XCTAssertTrue(store.claudeRedemptionRepairOffered, "exhausted: Repair is offered")
        XCTAssertNotNil(store.claudeRedemptionRebuildFailure)
        XCTAssertTrue(store.claudeRedemptionRecordUnreadable, "still closed")
        XCTAssertEqual(backing.stored, damaged)

        // Credentials become ready (a re-hydration that now reads the item).
        KeychainService.shared.setProfileCredentialReadFailureForTesting(profileId: account.id, key: "cli-creds", failing: false)
        store.resetAndRewarmCredentialCacheForTesting()
        try await waitUntil { !self.store.claudeRedemptionRecordUnreadable }
        XCTAssertEqual(store.claudeRedemptionStatus(ofClaudeLogin: held), .pending, "rebuilt automatically")
        XCTAssertEqual(backing.quarantined.values.first ?? nil, damaged)
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
    private var _cachedAccount: String?

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
    /// `~/.claude.json`'s `oauthAccount.accountUuid`: who the CLI last recorded
    /// itself as. Not bound to any token, and it can go stale across a `/login`.
    var cachedAccount: String? {
        get { locked { _cachedAccount } }
        set { locked { _cachedAccount = newValue } }
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
