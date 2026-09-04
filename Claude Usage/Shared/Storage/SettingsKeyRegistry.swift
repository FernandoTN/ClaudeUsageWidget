//
//  SettingsKeyRegistry.swift
//  Claude Usage
//
//  The source of truth for every preference key this app has ever written
//  (docs/specs/ux-revamp.md §5.2 "nothing renamed, nothing lost"). Each store
//  registers the keys it owns; the rest — service flags, the legacy single-mode
//  constants, debug switches — are listed here. `SettingsKeyRegistryTests`
//  checks the migration map against it, and Settings › Advanced shows which
//  keys are on disk and flags any that nobody registered.
//

import Foundation

struct RegisteredKey: Hashable {
    enum Owner: String {
        case profileStore, sharedDataStore, service, legacyConstants, misc
    }

    enum Status: String {
        /// Read and written by current code.
        case live
        /// A one-time flag: written once, read at launch, never deleted.
        case migrationFlag
        /// Tombstoned: may sit on disk from an old build, nothing reads it.
        case legacyUnread
        /// Written by macOS/AppKit or a debug switch — not a setting of ours.
        case external
    }

    let key: String
    let owner: Owner
    let status: Status
    /// Where the value is edited after the revamp (live keys only).
    let ui: String?

    init(_ key: String, _ owner: Owner, _ status: Status, ui: String? = nil) {
        self.key = key
        self.owner = owner
        self.status = status
        self.ui = ui
    }
}

enum SettingsKeyRegistry {
    static let all: [RegisteredKey] =
        SharedDataStore.registeredKeys + ProfileStore.registeredKeys + serviceKeys + legacyConstantKeys + miscKeys

    static let byKey: [String: RegisteredKey] = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

    static func lookup(_ key: String) -> RegisteredKey? { byKey[key] }

    static var live: [RegisteredKey] { all.filter { $0.status == .live } }

    /// Keys present in a preferences domain that nobody registered — the
    /// "no key lost" alarm. System keys (AppKit window frames, Apple's own
    /// prefixes) are not ours and are ignored.
    static func unregistered(in keys: some Sequence<String>) -> [String] {
        keys.filter { byKey[$0] == nil && !isSystemKey($0) }.sorted()
    }

    /// The keys currently on disk in this app's domain.
    static func present(in defaults: UserDefaults = .standard, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> [String] {
        guard let id = bundleIdentifier, let domain = defaults.persistentDomain(forName: id) else { return [] }
        return domain.keys.sorted()
    }

    static func isSystemKey(_ key: String) -> Bool {
        ["NS", "Apple", "com.apple.", "AK", "Web", "PK", "SU", "_", "MultipleSessionEnabled"].contains { key.hasPrefix($0) }
    }

    // MARK: Keys owned outside the two stores

    /// Written by the services with their own `UserDefaults` handles (the
    /// journal routing of the dead-login sets is the fixes session's open item).
    static let serviceKeys: [RegisteredKey] = [
        RegisteredKey("claudeDeadLogins_v1", .service, .live, ui: "Accounts › Login banner; Advanced › Dead-login flags"),
        RegisteredKey("codexDeadLogins_v1", .service, .live, ui: "Accounts › Login banner; Advanced › Dead-login flags"),
        RegisteredKey("grokDeadLogins_v1", .service, .live, ui: "Accounts › Login banner; Advanced › Dead-login flags"),
        RegisteredKey("claudeContaminatedLogins_v1", .service, .live, ui: "Accounts › row caption (re-login needed)"),
        RegisteredKey("sentNotifications", .service, .live, ui: "— (NotificationManager de-dup state)"),
        RegisteredKey("codexAutoImported_v1", .service, .migrationFlag),
        RegisteredKey("grokAutoImported_v1", .service, .migrationFlag),
        RegisteredKey("grokDisplayBackfill_v1", .service, .migrationFlag),
        RegisteredKey("legacyBundleDefaultsMigrated_v1", .service, .migrationFlag),
        // Single-mode icon configuration — `MenuBarIconConfiguration.load()` is live.
        RegisteredKey(Constants.UserDefaultsKeys.menuBarIconConfiguration, .legacyConstants, .live, ui: "Display › Single-account bar (Appearance until 3d)"),
        RegisteredKey(Constants.UserDefaultsKeys.menuBarIconStyle, .legacyConstants, .live, ui: "Display › Single-account bar (Appearance until 3d)"),
        RegisteredKey(Constants.UserDefaultsKeys.monochromeMode, .legacyConstants, .live, ui: "Display › Single-account bar (Appearance until 3d)"),
    ]

    /// `Constants.UserDefaultsKeys` entries nothing reads any more. Never
    /// deleted from disk; registered so the alarm above stays quiet about them.
    static let legacyConstantKeys: [RegisteredKey] = [
        Constants.UserDefaultsKeys.claudeUsageData, Constants.UserDefaultsKeys.notificationsEnabled,
        Constants.UserDefaultsKeys.refreshInterval, Constants.UserDefaultsKeys.apiUsageData,
        Constants.UserDefaultsKeys.apiTrackingEnabled, Constants.UserDefaultsKeys.apiSessionKey,
        Constants.UserDefaultsKeys.apiOrganizationId, Constants.UserDefaultsKeys.showIconNames,
        Constants.UserDefaultsKeys.showNextSessionTime, Constants.UserDefaultsKeys.sessionIconEnabled,
        Constants.UserDefaultsKeys.sessionIconStyle, Constants.UserDefaultsKeys.sessionIconOrder,
        Constants.UserDefaultsKeys.weekIconEnabled, Constants.UserDefaultsKeys.weekIconStyle,
        Constants.UserDefaultsKeys.weekIconOrder, Constants.UserDefaultsKeys.weekDisplayMode,
        Constants.UserDefaultsKeys.apiIconEnabled, Constants.UserDefaultsKeys.apiIconStyle,
        Constants.UserDefaultsKeys.apiIconOrder, Constants.UserDefaultsKeys.apiDisplayMode,
    ].map { RegisteredKey($0, .legacyConstants, .legacyUnread) }

    static let miscKeys: [RegisteredKey] = [
        // Menu-bar redesign: the one-time move of an untouched config to the
        // redesigned default layout (owner decision 2026-09-04).
        RegisteredKey("menuBarLayoutDefault_v1", .misc, .migrationFlag),
        RegisteredKey("debugTileLayout", .misc, .external),
        RegisteredKey("debugGroupExposure", .misc, .external),
        RegisteredKey("NSQuitAlwaysKeepsWindows", .misc, .external),
        // On disk from an abandoned feature; no code reads or writes them.
        RegisteredKey("autoSwitchCustomOrder", .misc, .legacyUnread),
        RegisteredKey("autoSwitchCustomOrderEnabled", .misc, .legacyUnread),
        // Left on this Mac by the 2026-07-17 status-item slot-pinning experiment
        // (autosaveName pins), which was never merged; no build reads it.
        RegisteredKey("cuwSlotPinsVersion", .misc, .legacyUnread),
    ]
}
