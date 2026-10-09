//
//  RealCredentialStoreGuardTests.swift
//  Claude UsageTests
//
//  The suite fails closed on the real credential stores.
//
//  The test host IS the app. On 2026-10-09 a suite run wrote the developer's
//  live Claude Code login (the shared Keychain item and ~/.claude/.credentials.json)
//  from five activation tests, and test profiles' credentials have always
//  landed in the real login Keychain. Under XCTest those stores are now
//  in-memory stand-ins (`RealCredentialStoreGuard`), and any code path that
//  still reaches a real one is refused and recorded.
//
//  Two checks here:
//  - the stand-ins are the default, observed through the public API with
//    nothing refused;
//  - EVERY test in the bundle fails if a refusal is recorded while it runs —
//    `RealStoreTouchObserver`, registered while XCTest builds the suite.
//
//  Deliberately absent: a test that drives the real write primitives to prove
//  they refuse. If the guard ever broke, that test would itself overwrite the
//  live login every running session depends on.
//

import XCTest
@testable import Claude_Usage

/// A test that provokes refusals on purpose; the observer leaves it alone.
protocol ExpectsRealStoreRefusals {}

/// Fails any test during which a real credential store was reached.
final class RealStoreTouchObserver: NSObject, XCTestObservation {
    static let shared = RealStoreTouchObserver()
    private static var registered = false

    static func registerOnce() {
        guard !registered else { return }
        registered = true
        XCTestObservationCenter.shared.addTestObserver(shared)
        print("RealStoreTouchObserver: registered — every test now fails if it reaches a real credential store")
    }

    static var isRegistered: Bool { registered }

    func testCaseWillStart(_ testCase: XCTestCase) {
        guard !(testCase is ExpectsRealStoreRefusals) else { return }
        let before = RealCredentialStoreGuard.refusedAttempts.count
        testCase.addTeardownBlock {
            let attempts = RealCredentialStoreGuard.refusedAttempts
            guard attempts.count > before else { return }
            XCTFail("reached a real credential store under XCTest: \(attempts[before...].joined(separator: "; "))")
        }
    }
}

/// Registers the observer. `defaultTestSuite` is asked of every test class
/// while XCTest assembles the run, before any test executes, so the observer
/// covers every class whatever the order.
final class RealStoreTouchObserverRegistration: XCTestCase {
    override class var defaultTestSuite: XCTestSuite {
        RealStoreTouchObserver.registerOnce()
        return super.defaultTestSuite
    }

    func testTheObserverIsRegistered() {
        XCTAssertTrue(RealStoreTouchObserver.isRegistered)
    }
}

@MainActor
final class RealCredentialStoreGuardTests: XCTestCase {

    private let sync = ClaudeCodeSyncService.shared

    override func setUp() async throws {
        try await super.setUp()
        sync.setCLIStoreForTesting(nil)  // the default stand-in, fresh
    }

    func testTheGuardRefusesInsideXCTest() {
        XCTAssertTrue(RealCredentialStoreGuard.isTestRun)
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

/// The two network calls that carry a token refuse by default under XCTest.
/// Probing them is safe: if the guard broke, a fixture token would reach the
/// endpoint and be rejected, nothing more.
@MainActor
final class RealCredentialEndpointRefusalTests: XCTestCase, ExpectsRealStoreRefusals {

    private let sync = ClaudeCodeSyncService.shared

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
}
