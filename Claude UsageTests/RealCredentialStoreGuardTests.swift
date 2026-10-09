//
//  RealCredentialStoreGuardTests.swift
//  Claude UsageTests
//
//  The suite fails closed on the real credential stores.
//
//  The test host IS the app. On 2026-10-09 a suite run wrote the developer's
//  live Claude Code login (the shared Keychain item and ~/.claude/.credentials.json)
//  from five activation tests, and test profiles' credentials have always
//  landed in the real login Keychain. In Debug builds under XCTest those stores
//  are in-memory stand-ins (`RealCredentialStoreGuard`), and any code path that
//  still reaches a real one is refused and recorded.
//
//  - `RealStoreGuardPrincipal` is the test bundle's NSPrincipalClass
//    (INFOPLIST_KEY_NSPrincipalClass on the test target). XCTest creates it
//    when the bundle loads, before any test and whatever `-only-testing`
//    selects, and it arms `RealStoreTouchObserver`.
//  - The observer fails EVERY test during which a refusal is recorded.
//  - The tests below check the stand-ins are the default, through the public
//    API, with nothing refused.
//
//  Deliberately absent: a test that drives the real write primitives to prove
//  they refuse. If the guard ever broke, that test would itself overwrite the
//  live login every running session depends on.
//

import XCTest
@testable import Claude_Usage

/// The test bundle's principal class: arms the observer at bundle load.
@objc(RealStoreGuardPrincipal)
final class RealStoreGuardPrincipal: NSObject {
    override init() {
        super.init()
        RealStoreTouchObserver.register(via: .bundleLoad)
    }
}

/// A test that provokes refusals on purpose; the observer leaves it alone.
protocol ExpectsRealStoreRefusals {}

/// Fails any test during which a real credential store was reached.
final class RealStoreTouchObserver: NSObject, XCTestObservation {
    enum Registration: Equatable { case bundleLoad }

    static let shared = RealStoreTouchObserver()
    private(set) static var registeredVia: Registration?

    static func register(via source: Registration) {
        guard registeredVia == nil else { return }
        registeredVia = source
        XCTestObservationCenter.shared.addTestObserver(shared)
    }

    /// The observer's verdict for one test, pure: the refusals recorded while
    /// it ran, or nil when there were none.
    static func violation(before: Int, attempts: [String]) -> String? {
        guard attempts.count > before else { return nil }
        return "reached a real credential store under XCTest: " + attempts[before...].joined(separator: "; ")
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        guard !(testCase is ExpectsRealStoreRefusals) else { return }
        let before = RealCredentialStoreGuard.refusedAttempts.count
        testCase.addTeardownBlock {
            if let violation = Self.violation(before: before, attempts: RealCredentialStoreGuard.refusedAttempts) {
                XCTFail(violation)
            }
        }
    }
}

final class RealStoreTouchObserverTests: XCTestCase {

    /// Armed by the principal class at bundle load — not by whichever test
    /// class happened to run first. Fails if the Info.plist key is lost.
    func testTheObserverIsArmedWhenTheBundleLoads() {
        XCTAssertEqual(RealStoreTouchObserver.registeredVia, .bundleLoad)
    }

    func testTheVerdictNamesEveryRefusalRecordedDuringTheTest() {
        XCTAssertNil(RealStoreTouchObserver.violation(before: 2, attempts: ["a", "b"]))
        XCTAssertEqual(
            RealStoreTouchObserver.violation(before: 1, attempts: ["a", "b", "c"]),
            "reached a real credential store under XCTest: b; c"
        )
    }
}

@MainActor
final class RealCredentialStoreGuardTests: XCTestCase {

    private let sync = ClaudeCodeSyncService.shared

    override func setUp() async throws {
        try await super.setUp()
        sync.setCLIStoreForTesting(nil)  // the default stand-in, fresh
    }

    /// Applying a login with no stand-in installed by the test lands in the
    /// default in-memory store. Nothing reaches a real primitive (the observer
    /// would fail this test, and the refusal count would move).
    func testTheCLIStoreIsAStandInByDefault() throws {
        let before = RealCredentialStoreGuard.refusedAttempts.count
        let login = #"{"claudeAiOauth":{"accessToken":"guard-access-1","refreshToken":"guard-refresh-1","expiresAt":4102444800000}}"#

        try sync.writeSystemCredentials(login)
        XCTAssertEqual(try sync.readSystemCredentials(), login, "the write landed in the stand-in")
        sync.updateCLIAccountMetadata(accountUUID: "guard-account", email: "", organizationUUID: "")
        XCTAssertEqual(sync.cliCachedAccountUUID(), "guard-account", "~/.claude.json is stood in too")

        XCTAssertEqual(RealCredentialStoreGuard.refusedAttempts.count, before, "no real primitive was reached")
    }

    /// A test's own stand-in, once cleared, is replaced by a fresh empty one —
    /// never by the real store.
    func testClearingATestsStandInRestoresAnEmptyOneNotTheRealStore() throws {
        try sync.writeSystemCredentials(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":4102444800000}}"#)
        sync.setCLIStoreForTesting(nil)
        let before = RealCredentialStoreGuard.refusedAttempts.count
        XCTAssertNil(try sync.readSystemCredentials())
        XCTAssertEqual(RealCredentialStoreGuard.refusedAttempts.count, before)
    }

    /// Per-profile credential items and the legacy session keys live in
    /// memory under XCTest; the login Keychain is never touched.
    func testProfileKeychainItemsAreInMemory() throws {
        let before = RealCredentialStoreGuard.refusedAttempts.count
        let keychain = KeychainService.shared
        let id = UUID()

        keychain.saveProfileCredential("guard-secret", profileId: id, key: "cli-creds")
        XCTAssertEqual(keychain.loadProfileCredential(profileId: id, key: "cli-creds"), "guard-secret")
        keychain.deleteProfileCredentials(profileId: id)
        XCTAssertNil(keychain.loadProfileCredential(profileId: id, key: "cli-creds"))

        let legacyBefore = try keychain.load(for: .apiSessionKey)
        try keychain.save("guard-legacy", for: .apiSessionKey)
        XCTAssertEqual(try keychain.load(for: .apiSessionKey), "guard-legacy")
        if let legacyBefore {
            try keychain.save(legacyBefore, for: .apiSessionKey)
        } else {
            try keychain.delete(for: .apiSessionKey)
        }

        XCTAssertEqual(RealCredentialStoreGuard.refusedAttempts.count, before, "no security/SecItem call was made")
    }
}

/// Paths that refuse by default under XCTest, provoked on purpose. Probing them
/// is safe: `refuse` records and returns before anything real is touched, and
/// if the guard broke, a fixture token reaching an endpoint is rejected and
/// a fixture path is read, nothing more.
@MainActor
final class RealCredentialEndpointRefusalTests: XCTestCase, ExpectsRealStoreRefusals {

    private let sync = ClaudeCodeSyncService.shared

    func testRefuseRecordsTheAttemptInsideXCTest() {
        let before = RealCredentialStoreGuard.refusedAttempts.count
        XCTAssertTrue(RealCredentialStoreGuard.refuse("guard self-test"),
                      "a Debug build under XCTest refuses every real-store primitive")
        XCTAssertEqual(RealCredentialStoreGuard.refusedAttempts.last, "guard self-test")
        XCTAssertEqual(RealCredentialStoreGuard.refusedAttempts.count, before + 1)
    }

    func testTheTokenEndpointRefusesWithoutAStandIn() async {
        sync.setTokenEndpointForTesting(nil)
        let before = RealCredentialStoreGuard.refusedAttempts.count
        do {
            _ = try await sync.refreshOAuthToken(
                credentialsJSON: #"{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":0}}"#
            )
            XCTFail("a refresh must not be sent from a test without a stand-in endpoint")
        } catch ClaudeCodeError.tokenRefreshFailed(let status) {
            XCTAssertEqual(status, -1)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(RealCredentialStoreGuard.refusedAttempts.count, before + 1)
    }

    func testTheIdentityEndpointRefusesWithoutAStandIn() async {
        sync.setIdentityFetcherForTesting(nil)
        let before = RealCredentialStoreGuard.refusedAttempts.count
        let identity = await sync.fetchAccountIdentity(accessToken: "fixture-access-guard")
        XCTAssertNil(identity)
        XCTAssertEqual(RealCredentialStoreGuard.refusedAttempts.count, before + 1)
    }

    /// The CLI's cached usage is read from the real `~/.claude.json` only by
    /// default — a test must pass its own fixture path.
    func testTheCLICachedUsageDefaultPathRefuses() {
        let before = RealCredentialStoreGuard.refusedAttempts.count
        XCTAssertNil(LocalLimitSignalService.readCLICachedUsage())
        XCTAssertEqual(RealCredentialStoreGuard.refusedAttempts.count, before + 1)
    }
}
