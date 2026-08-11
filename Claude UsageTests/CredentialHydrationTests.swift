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
        savedProfilesData = ProfileStoreUsagePatchTests.testDefaults.data(forKey: profilesKey)
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
            ProfileStoreUsagePatchTests.testDefaults.set(savedProfilesData, forKey: profilesKey)
        } else {
            ProfileStoreUsagePatchTests.testDefaults.removeObject(forKey: profilesKey)
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

    // MARK: - Failed-warm retry (2026-08-10 partial-cache incident)

    /// (4) The backoff schedule doubles from 30s and caps at 480s — early
    /// retries catch a transient launch-storm slowdown, the cap protects a
    /// genuinely broken Keychain from being hammered forever.
    func testHydrationRetryDelayDoublesFrom30sAndCapsAt480s() {
        XCTAssertEqual(ProfileStore.hydrationRetryDelay(afterAttempt: 0), 30)
        XCTAssertEqual(ProfileStore.hydrationRetryDelay(afterAttempt: 1), 60)
        XCTAssertEqual(ProfileStore.hydrationRetryDelay(afterAttempt: 2), 120)
        XCTAssertEqual(ProfileStore.hydrationRetryDelay(afterAttempt: 3), 240)
        XCTAssertEqual(ProfileStore.hydrationRetryDelay(afterAttempt: 4), 480)
        XCTAssertEqual(ProfileStore.hydrationRetryDelay(afterAttempt: 99), 480)
        // Defensive clamp: a negative attempt never shortens below the floor.
        XCTAssertEqual(ProfileStore.hydrationRetryDelay(afterAttempt: -1), 30)
    }

    /// (5) The retry entry point is a strict no-op unless the warm actually
    /// FAILED: it must never re-read the Keychain (risking a stale overwrite
    /// of an adopted token) or double-post readiness from a settled state.
    func testRetryIsANoOpUnlessHydrationFailed() throws {
        waitForHydrationSettled()
        guard store.credentialHydrationState == .ready else {
            throw XCTSkip("host warm ended .failed — the no-op assertion would be vacuous")
        }

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady,
            object: nil,
            queue: .main
        ) { _ in posts += 1 }
        notificationTokens.append(token)

        store.retryHydrationForMissingProfiles()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(posts, 0, "a settled warm must not re-post readiness")
        XCTAssertEqual(store.credentialHydrationState, .ready)
    }

    /// Shared setup for the healing tests: seeds a profile whose credential is
    /// committed to the real Keychain, then reconstructs the incident state —
    /// the warm never read this profile (no cache entry, pending, `.failed`).
    private func seedProfileWithUnreadKeychainCredential(
        secret: String
    ) async -> UUID {
        let id = UUID()
        var seeded = Profile(id: id, name: "Partial Hydration")
        seeded.cliCredentialsJSON = secret
        seeded.hasCliAccount = true
        seedProfiles([seeded])
        await store.flushKeychainWrites()
        store.simulatePartialHydrationForTesting(unreadIds: [id])
        XCTAssertNil(
            store.loadProfiles().first(where: { $0.id == id })?.cliCredentialsJSON,
            "precondition: the profile must look credential-less, as in the incident"
        )
        XCTAssertEqual(store.credentialHydrationState, .failed)
        return id
    }

    /// (6) failed -> retry -> ready: the retry re-reads the unread profile from
    /// the real Keychain, restores its credential, and posts readiness. This is
    /// the incident's healing path end to end.
    func testRetryHealsPartialHydration() async {
        let secret = #"{"claudeAiOauth":{"accessToken":"heal-access","refreshToken":"heal-refresh","expiresAt":"2099-01-01T00:00:00.000000Z"}}"#
        let id = await seedProfileWithUnreadKeychainCredential(secret: secret)

        let healed = expectation(description: "retry posts readiness")
        healed.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady, object: nil, queue: .main
        ) { _ in healed.fulfill() }
        notificationTokens.append(token)

        store.retryHydrationForMissingProfiles()
        await fulfillment(of: [healed], timeout: 10)

        XCTAssertEqual(store.credentialHydrationState, .ready)
        XCTAssertEqual(
            store.loadProfiles().first(where: { $0.id == id })?.cliCredentialsJSON,
            secret,
            "the retry must restore the unread profile's Keychain credential"
        )
    }

    /// (7) Regression (review finding): merge-on-save mints an all-nil cache
    /// entry for every profile it persists. A full-roster save between failure
    /// and retry must NOT fool the retry into a false `.ready` that skips the
    /// unread profile — the pending set, not entry absence, is the work list.
    func testRetryNotFooledByMintedCacheEntries() async {
        let secret = #"{"claudeAiOauth":{"accessToken":"mint-access","refreshToken":"mint-refresh","expiresAt":"2099-01-01T00:00:00.000000Z"}}"#
        let id = await seedProfileWithUnreadKeychainCredential(secret: secret)

        // The routine full-roster save (token-refresh persists do this every
        // sweep): mints an all-nil entry for the unread profile.
        store.saveProfiles(store.loadProfiles())

        let healed = expectation(description: "retry still heals")
        healed.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady, object: nil, queue: .main
        ) { _ in healed.fulfill() }
        notificationTokens.append(token)

        store.retryHydrationForMissingProfiles()
        await fulfillment(of: [healed], timeout: 10)

        XCTAssertEqual(store.credentialHydrationState, .ready)
        XCTAssertEqual(
            store.loadProfiles().first(where: { $0.id == id })?.cliCredentialsJSON,
            secret,
            "a minted (all-nil) cache entry must not count as hydrated"
        )
    }

    /// (8) Regression (review finding): a credential that arrives in memory
    /// while the retry's slow Keychain reads are in flight (user-driven sync)
    /// can be NEWER than the Keychain item — the retry must merge around it,
    /// never replace it with the older Keychain snapshot.
    func testRetryNeverClobbersFresherInMemoryCredential() async {
        let stale = #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":"2099-01-01T00:00:00.000000Z"}}"#
        let rotated = #"{"claudeAiOauth":{"accessToken":"rotated-access","refreshToken":"rotated-refresh","expiresAt":"2099-06-01T00:00:00.000000Z"}}"#
        let id = await seedProfileWithUnreadKeychainCredential(secret: stale)

        let settled = expectation(description: "retry completes")
        settled.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady, object: nil, queue: .main
        ) { _ in settled.fulfill() }
        notificationTokens.append(token)

        // Enqueue the retry read FIRST (it spends tens of ms in `security`
        // subprocesses on keychainQueue), then land the fresher credential in
        // the cache from the main thread — the shape of a user re-sync racing
        // the retry.
        store.retryHydrationForMissingProfiles()
        var fresher = Profile(id: id, name: "Partial Hydration")
        fresher.cliCredentialsJSON = rotated
        fresher.hasCliAccount = true
        store.saveProfiles([fresher])

        await fulfillment(of: [settled], timeout: 10)
        await store.flushKeychainWrites()

        XCTAssertEqual(
            store.loadProfiles().first(where: { $0.id == id })?.cliCredentialsJSON,
            rotated,
            "the retry must never replace an in-memory credential with the Keychain snapshot"
        )
    }

    /// (9) Regression (review finding): an EXPLICIT credential clear landing
    /// while the retry's reads are in flight is an intentional nil, not a gap —
    /// the read-merge must not resurrect the cleared value from the Keychain
    /// snapshot (whose deletion queues behind the running read).
    func testRetryPreservesIntentionalClearOverKeychainSnapshot() async {
        let secret = #"{"claudeAiOauth":{"accessToken":"cleared-access","refreshToken":"cleared-refresh","expiresAt":"2099-01-01T00:00:00.000000Z"}}"#
        let id = await seedProfileWithUnreadKeychainCredential(secret: secret)

        let settled = expectation(description: "retry completes")
        settled.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady, object: nil, queue: .main
        ) { _ in settled.fulfill() }
        notificationTokens.append(token)

        // Enqueue the retry read FIRST (slow `security` subprocesses on
        // keychainQueue read the still-present item), then clear from the main
        // thread — the tombstone must outlive the in-flight read's merge.
        store.retryHydrationForMissingProfiles()
        store.clearProfileCredential(id, key: .cliCredentials)

        await fulfillment(of: [settled], timeout: 10)
        await store.flushKeychainWrites()

        XCTAssertNil(
            store.loadProfiles().first(where: { $0.id == id })?.cliCredentialsJSON,
            "an intentional clear must survive an in-flight hydration read"
        )
    }
}
