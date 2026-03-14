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
        guard let oldDefaults = UserDefaults(suiteName: Constants.appGroupIdentifier) else {
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
