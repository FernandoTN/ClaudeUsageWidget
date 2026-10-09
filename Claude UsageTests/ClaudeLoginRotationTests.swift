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
        savedProfilesData = defaults.data(forKey: profilesKey)
        savedActiveProfileId = defaults.string(forKey: activeProfileKey)
        savedManagerProfiles = manager.profiles
        savedActiveProfile = manager.activeProfile
        savedActiveClaudeProfileId = manager.activeClaudeProfileId
        savedActiveCodexProfileId = manager.activeCodexProfileId
        savedActiveGrokProfileId = manager.activeGrokProfileId
        manager.flushPendingUsage()
        testProfileIDs = []

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

    /// Tonight's ordering, replayed. The target's access token has 40 minutes
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
