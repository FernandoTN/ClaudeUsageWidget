//
//  MigrationService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-18.
//

import Foundation

/// Handles data migration from App Group container to standard container
class MigrationService {
    static let shared = MigrationService()

    private init() {}

    private let migrationKey = "HasMigratedFromAppGroup"

    /// Checks if migration has already been completed
    func hasMigrated() -> Bool {
        return UserDefaults.standard.bool(forKey: migrationKey)
    }

    /// Checks if we should show the migration option (without triggering TCC dialog)
    /// Returns true if migration hasn't been completed yet (user might have old data)
    func shouldShowMigrationOption() -> Bool {
        // If migration was already completed or declined, don't show
        return !hasMigrated()
    }

    /// Migrates data from App Group container to standard container
    /// - Throws: Error if migration fails
    /// - Returns: Number of keys migrated
    @discardableResult
    func migrateFromAppGroup() throws -> Int {
        LoggingService.shared.log("MigrationService: Starting App Group to standard container migration...")

        // Try to access old App Group UserDefaults
        guard let oldDefaults = UserDefaults(suiteName: Constants.legacyAppGroupIdentifier) else {
            LoggingService.shared.log("MigrationService: No App Group data found")
            UserDefaults.standard.set(true, forKey: migrationKey)
            return 0
        }

        // Get all keys from old UserDefaults
        let oldData = oldDefaults.dictionaryRepresentation()
        LoggingService.shared.log("MigrationService: Found \(oldData.count) keys in App Group")

        // Filter out credential keys to prevent copying secrets to UserDefaults
        let credentialKeys: Set<String> = [
            "apiSessionKey", "claudeSessionKey", "sessionKey",
            Constants.UserDefaultsKeys.apiSessionKey
        ]

        // Copy non-credential data to standard UserDefaults
        var migratedCount = 0
        for (key, value) in oldData {
            if credentialKeys.contains(key) {
                LoggingService.shared.log("MigrationService: Skipping credential key '\(key)'")
                continue
            }
            UserDefaults.standard.set(value, forKey: key)
            migratedCount += 1
        }

        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)

        LoggingService.shared.log("MigrationService: Successfully migrated \(migratedCount) keys from App Group (skipped \(oldData.count - migratedCount) credential keys)")

        return migratedCount
    }

    // MARK: - Bundle-Identifier Rename Migration

    private let bundleDefaultsMigrationKey = "legacyBundleDefaultsMigrated_v1"

    /// One-time migration for the open-source bundle-id rename. The bundle id IS
    /// the UserDefaults domain, so builds with the new id start with an empty
    /// preferences plist while the user's profiles/settings still sit under the
    /// old `com.fernandotn.ClaudeUsageWidget` domain. Copies every key from the
    /// old domain into the current one — but ONLY when the current domain has no
    /// `profiles_v3` yet (never clobbers an already-configured install).
    ///
    /// Credentials are unaffected: they live in Keychain items whose service
    /// names (`com.claudewidget.<key>-<profileUUID>`, `com.claudeusagetracker.*`)
    /// never derived from the bundle id. The app is NOT sandboxed (see
    /// ClaudeUsageTracker.entitlements), so reading another domain's plist via
    /// CFPreferences works.
    ///
    /// MUST run before anything reads UserDefaults.standard (first line of
    /// applicationDidFinishLaunching).
    func migrateLegacyBundleDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: bundleDefaultsMigrationKey) else { return }

        // An install that already has profiles under the new domain is past this
        // migration — mark done and never look at the old domain again.
        guard defaults.object(forKey: "profiles_v3") == nil else {
            defaults.set(true, forKey: bundleDefaultsMigrationKey)
            return
        }

        let legacyDomain = Constants.legacyBundleIdentifier as CFString
        guard let keyList = CFPreferencesCopyKeyList(legacyDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keyList.isEmpty else {
            // No legacy domain on this machine (fresh install) — nothing to do,
            // and nothing will ever appear there. Mark done.
            defaults.set(true, forKey: bundleDefaultsMigrationKey)
            return
        }

        var migratedCount = 0
        for key in keyList {
            if let value = CFPreferencesCopyAppValue(key as CFString, legacyDomain) {
                defaults.set(value, forKey: key)
                migratedCount += 1
            }
        }
        defaults.set(true, forKey: bundleDefaultsMigrationKey)
        LoggingService.shared.log("MigrationService: ✅ Migrated \(migratedCount) preference key(s) from legacy bundle domain '\(Constants.legacyBundleIdentifier)'")
    }

    /// Resets all app data (standard container only, NOT old App Group data)
    func resetAppData() {
        LoggingService.shared.log("MigrationService: Resetting app data...")

        // Get all keys from standard UserDefaults
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys

        // Remove all keys
        for key in allKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Synchronize
        UserDefaults.standard.synchronize()

        LoggingService.shared.log("MigrationService: ✅ App data reset complete (\(allKeys.count) keys removed)")
    }
}
