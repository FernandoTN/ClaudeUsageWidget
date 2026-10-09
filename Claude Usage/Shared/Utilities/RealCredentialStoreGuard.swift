//
//  RealCredentialStoreGuard.swift
//  Claude Usage
//
//  Keeps XCTest away from every real credential store this app touches: the
//  Claude Code CLI's login (the shared Keychain item, ~/.claude/.credentials.json
//  and ~/.claude.json), and this app's own per-profile Keychain items.
//
//  The test host IS the app, so without this a test that applies a login writes
//  the developer's live CLI login — every running Claude Code session reads it —
//  and a test profile's credentials land in the real login Keychain. Both
//  happened (2026-10-09). In a Debug build under XCTest those stores are
//  replaced by in-memory stand-ins, and every primitive that would reach a real
//  one refuses and is counted here; the test bundle fails any test during which
//  the count moves (`RealStoreTouchObserver`). There is no opt-in.
//
//  Release builds compile the stand-in mode out: `isTestRun` is the constant
//  false there, so the app uses the real stores whatever the environment says.
//

import Foundation
import os.log

enum RealCredentialStoreGuard {
    #if DEBUG
    /// True inside the XCTest host. Same detection as ProfileStore/SharedDataStore.
    nonisolated static let isTestRun: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    #else
    nonisolated static let isTestRun = false
    #endif

    nonisolated(unsafe) private static var refused: [String] = []
    nonisolated private static let lock = NSLock()
    nonisolated private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudeusage", category: "General"
    )

    /// Call at the top of every primitive that reaches a real credential store.
    /// Returns true — "refuse, do nothing" — under XCTest, recording `what`.
    /// Never true in the app.
    nonisolated static func refuse(_ what: String) -> Bool {
        guard isTestRun else { return false }
        lock.lock()
        refused.append(what)
        lock.unlock()
        os_log("RealCredentialStoreGuard: refused %{public}@ under XCTest", log: log, type: .error, what)
        return true
    }

    /// Every refused attempt so far in this process, oldest first.
    nonisolated static var refusedAttempts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }
}

/// A lock-protected string map standing in for a Keychain or a file under
/// XCTest. Only ever populated in Debug builds under XCTest.
final class InMemoryCredentialStore: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var items: [String: String] = [:]  // guarded by `lock`

    nonisolated init() {}

    nonisolated subscript(key: String) -> String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return items[key]
        }
        set {
            lock.lock()
            items[key] = newValue
            lock.unlock()
        }
    }
}

#if DEBUG
extension ClaudeCodeSyncService.CLIStoreSeams {
    /// An empty in-memory CLI store: what every test gets unless it installs
    /// its own.
    nonisolated static func inMemory() -> ClaudeCodeSyncService.CLIStoreSeams {
        let store = InMemoryCredentialStore()
        return ClaudeCodeSyncService.CLIStoreSeams(
            readSources: { (store["keychain"], store["file"]) },
            write: { json in
                store["keychain"] = json
                store["file"] = json
            },
            cachedAccountUUID: { store["accountUUID"] },
            writeAccountMetadata: { uuid, _, _ in store["accountUUID"] = uuid }
        )
    }
}
#endif
