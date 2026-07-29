//
//  CredentialHydrationTests.swift
//  Claude UsageTests
//
//  Phase 3.2 (packet G): async credential hydration readiness.
//
//  Isolation: same UserDefaults.standard save/restore pattern as
//  ProfileStoreUsagePatchTests — real profiles_v3 is restored in tearDown.
//  Keychain reads for synthetic UUIDs complete quickly (missing items).
//

import XCTest
@testable import Claude_Usage

@MainActor
final class CredentialHydrationTests: XCTestCase {

    private let profilesKey = "profiles_v3"
    private let store = ProfileStore.shared
    private let manager = ProfileManager.shared

    private var savedProfilesData: Data?
    private var savedManagerProfiles: [Profile] = []
    private var savedActiveProfile: Profile?
    private var testProfileIDs: [UUID] = []
    private var notificationTokens: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        // Settle the test host's own launch-time warm first: a fresh host clone
        // starts ProfileStore.shared with an in-flight hydration whose late
        // .profileCredentialsReady post would otherwise leak into this test's
        // observers (the once-per-warm test raced exactly that).
        waitForHydrationSettled()
        savedProfilesData = UserDefaults.standard.data(forKey: profilesKey)
        savedManagerProfiles = manager.profiles
        savedActiveProfile = manager.activeProfile
        manager.flushPendingUsage()
        testProfileIDs = []
        notificationTokens = []
    }

    /// Polls until the store's hydration is out of `.loading` (launch warm or a
    /// previous test's rewarm). Post-based waiting is unsafe here: the post may
    /// have fired before this test installed any observer.
    private func waitForHydrationSettled(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while store.credentialHydrationState == .loading, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotEqual(
            store.credentialHydrationState, .loading,
            "hydration must settle before the test begins"
        )
    }

    override func tearDown() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens = []
        manager.flushPendingUsage()
        for id in testProfileIDs {
            store.deleteProfileCredentials(profileId: id)
        }
        if let savedProfilesData {
            UserDefaults.standard.set(savedProfilesData, forKey: profilesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: profilesKey)
        }
        if savedProfilesData != nil {
            manager.loadProfiles()
        } else {
            manager.profiles = savedManagerProfiles
            manager.activeProfile = savedActiveProfile
        }
        // Restore a clean hydrated cache for later tests / the live session.
        rewarmAndWait()
        testProfileIDs = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func seedProfiles(_ profiles: [Profile]) {
        testProfileIDs = profiles.map(\.id)
        store.saveProfiles(profiles)
        manager.profiles = store.loadProfiles()
        manager.activeProfile = manager.profiles.first
    }

    private func rewarmAndWait(timeout: TimeInterval = 10) {
        let exp = expectation(description: "credential hydration settles")
        // Overlapping warms (test-driven + tearDown rewarm) can post more than
        // once while this observer lives; only the first arrival matters.
        exp.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady,
            object: nil,
            queue: .main
        ) { _ in exp.fulfill() }
        notificationTokens.append(token)
        store.resetAndRewarmCredentialCacheForTesting()
        wait(for: [exp], timeout: timeout)
    }

    // MARK: - Tests

    /// (1) State machine: after reset+rewarm the store is `.loading`, then
    /// reaches `.ready` once the background Keychain read completes.
    func testHydrationStateMachineLoadingThenReady() {
        // Seed a synthetic profile so warm has at least one id to read
        // (missing Keychain items resolve quickly).
        let id = UUID()
        seedProfiles([Profile(id: id, name: "Hydration State")])

        let exp = expectation(description: "hydration ready")
        exp.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady,
            object: nil,
            queue: .main
        ) { _ in exp.fulfill() }
        notificationTokens.append(token)

        // Drive a fresh warm against the real API.
        store.resetAndRewarmCredentialCacheForTesting()
        XCTAssertEqual(
            store.credentialHydrationState,
            .loading,
            "fresh rewarm must start in .loading"
        )

        wait(for: [exp], timeout: 10)

        XCTAssertEqual(
            store.credentialHydrationState,
            .ready,
            "nonexistent-profile Keychain reads complete quickly and mark .ready"
        )
        // ProfileManager passthrough stays in sync.
        XCTAssertEqual(manager.credentialHydrationState, .ready)
    }

    /// (2) `.profileCredentialsReady` is posted exactly once per warm.
    func testProfileCredentialsReadyPostedOncePerWarm() {
        let id = UUID()
        seedProfiles([Profile(id: id, name: "Hydration Notify")])

        var postCount = 0
        let firstPost = expectation(description: "first credentials-ready post")
        let token = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady,
            object: nil,
            queue: .main
        ) { _ in
            postCount += 1
            if postCount == 1 {
                firstPost.fulfill()
            }
        }
        notificationTokens.append(token)

        store.resetAndRewarmCredentialCacheForTesting()
        wait(for: [firstPost], timeout: 10)

        // Give any duplicate posts a short window to arrive.
        let noMore = expectation(description: "no duplicate posts")
        noMore.isInverted = true
        let dupToken = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady,
            object: nil,
            queue: .main
        ) { _ in
            noMore.fulfill()
        }
        notificationTokens.append(dupToken)

        wait(for: [noMore], timeout: 0.5)
        XCTAssertEqual(postCount, 1, "exactly one .profileCredentialsReady per warm")
        XCTAssertNotEqual(store.credentialHydrationState, .loading)
    }

    /// (3) nil-never-deletes still holds when saveProfiles runs BEFORE hydration
    /// completes — the historic silent-credential-loss regression.
    func testNilNeverDeletesWhileHydrationLoading() async {
        let id = UUID()
        let secret = #"{"claudeAiOauth":{"accessToken":"test-access","refreshToken":"test-refresh","expiresAt":"2099-01-01T00:00:00.000000Z"}}"#
        var seeded = Profile(id: id, name: "Hydration Merge")
        seeded.cliCredentialsJSON = secret
        seeded.hasCliAccount = true
        seedProfiles([seeded])

        // Ensure the credential is committed to Keychain before we clear the cache.
        await store.flushKeychainWrites()
        XCTAssertEqual(
            store.loadProfiles().first(where: { $0.id == id })?.cliCredentialsJSON,
            secret,
            "precondition: credential is in cache after seed"
        )

        // Start a warm with an empty cache while Keychain still holds the secret.
        let exp = expectation(description: "hydration after nil-save")
        exp.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady,
            object: nil,
            queue: .main
        ) { _ in exp.fulfill() }
        notificationTokens.append(token)

        store.resetAndRewarmCredentialCacheForTesting()
        XCTAssertEqual(store.credentialHydrationState, .loading)

        // Immediately save a nil-credential copy (the stale pre-hydration shape).
        var stale = Profile(id: id, name: "Hydration Merge")
        stale.cliCredentialsJSON = nil
        stale.hasCliAccount = true
        store.saveProfiles([stale])

        await fulfillment(of: [exp], timeout: 10)
        XCTAssertEqual(store.credentialHydrationState, .ready)

        let loaded = store.loadProfiles().first(where: { $0.id == id })
        XCTAssertEqual(
            loaded?.cliCredentialsJSON,
            secret,
            "nil credential on a pre-hydration save must never delete the Keychain value"
        )
    }
}
