//
//  ProfileStore.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

/// Manages storage and retrieval of profiles and profile-related data.
/// Credentials (claudeSessionKey, apiSessionKey, cliCredentialsJSON) are stored
/// exclusively in macOS Keychain — never in UserDefaults.
class ProfileStore {
    static let shared = ProfileStore()

    private let defaults: UserDefaults
    private let keychainService = KeychainService.shared

    private enum Keys {
        static let profiles = "profiles_v3"
        static let activeProfileId = "activeProfileId"
        static let displayMode = "profileDisplayMode"
        static let multiProfileConfig = "multiProfileDisplayConfig"
        static let credentialsMigratedToKeychain = "credentialsMigratedToKeychain"
    }

    init() {
        // Use standard UserDefaults (app container)
        self.defaults = UserDefaults.standard
        LoggingService.shared.log("ProfileStore: Using standard app container storage")

        // One-time migration: move credentials from UserDefaults JSON to Keychain
        migrateCredentialsToKeychainIfNeeded()
    }

    // MARK: - One-Time Migration

    /// Migrates credentials from the old UserDefaults JSON format to Keychain-only storage.
    /// Uses a `credentialsMigratedToKeychain` flag to ensure this runs only once.
    private func migrateCredentialsToKeychainIfNeeded() {
        guard !defaults.bool(forKey: Keys.credentialsMigratedToKeychain) else {
            return
        }

        guard let data = defaults.data(forKey: Keys.profiles) else {
            // No profiles stored yet — mark as migrated (nothing to migrate)
            defaults.set(true, forKey: Keys.credentialsMigratedToKeychain)
            return
        }

        // Parse the old JSON manually to extract credentials that were previously serialized
        do {
            guard let profileArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                LoggingService.shared.logError("ProfileStore migration: Failed to parse profiles as array")
                defaults.set(true, forKey: Keys.credentialsMigratedToKeychain)
                return
            }

            var migratedCount = 0

            for profileDict in profileArray {
                guard let idString = profileDict["id"] as? String,
                      let profileId = UUID(uuidString: idString) else {
                    continue
                }

                // Extract and save each credential to Keychain
                if let claudeKey = profileDict["claudeSessionKey"] as? String, !claudeKey.isEmpty {
                    keychainService.saveProfileCredential(claudeKey, profileId: profileId, key: "claude-key")
                    migratedCount += 1
                }
                if let apiKey = profileDict["apiSessionKey"] as? String, !apiKey.isEmpty {
                    keychainService.saveProfileCredential(apiKey, profileId: profileId, key: "api-key")
                    migratedCount += 1
                }
                if let cliCreds = profileDict["cliCredentialsJSON"] as? String, !cliCreds.isEmpty {
                    keychainService.saveProfileCredential(cliCreds, profileId: profileId, key: "cli-creds")
                    migratedCount += 1
                }
            }

            if migratedCount > 0 {
                LoggingService.shared.log("ProfileStore migration: Migrated \(migratedCount) credential(s) to Keychain")

                // Re-save profiles without credentials (CodingKeys now excludes them)
                // Decode using the new CodingKeys (credentials will be nil), then re-encode
                let profiles = try JSONDecoder().decode([Profile].self, from: data)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let cleanData = try encoder.encode(profiles)
                defaults.set(cleanData, forKey: Keys.profiles)

                LoggingService.shared.log("ProfileStore migration: Re-saved profiles without credentials in UserDefaults")
            } else {
                LoggingService.shared.log("ProfileStore migration: No credentials found in UserDefaults to migrate")
            }

        } catch {
            LoggingService.shared.logError("ProfileStore migration: Error during migration: \(error.localizedDescription)")
        }

        defaults.set(true, forKey: Keys.credentialsMigratedToKeychain)
    }

    // MARK: - Profile Management

    func saveProfiles(_ profiles: [Profile]) {
        do {
            // Save each profile's credentials to Keychain only if changed
            // Load current Keychain state for comparison to avoid redundant writes
            let existingProfiles = loadProfiles()
            for profile in profiles {
                let existing = existingProfiles.first(where: { $0.id == profile.id })
                let credentialsChanged = existing == nil
                    || existing?.claudeSessionKey != profile.claudeSessionKey
                    || existing?.apiSessionKey != profile.apiSessionKey
                    || existing?.cliCredentialsJSON != profile.cliCredentialsJSON
                if credentialsChanged {
                    saveCredentialsToKeychain(for: profile)
                }
            }

            // JSON encode profiles — CodingKeys excludes credential fields,
            // so the JSON written to UserDefaults contains NO secrets
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(profiles)
            defaults.set(data, forKey: Keys.profiles)

            // Verify save
            if let savedData = defaults.data(forKey: Keys.profiles) {
                LoggingService.shared.log("ProfileStore: Saved \(profiles.count) profiles (\(savedData.count) bytes, credentials in Keychain)")
            } else {
                LoggingService.shared.logError("ProfileStore: Failed to verify save!")
            }
        } catch {
            LoggingService.shared.logStorageError("saveProfiles", error: error)
        }
    }

    func loadProfiles() -> [Profile] {
        guard let data = defaults.data(forKey: Keys.profiles) else {
            LoggingService.shared.log("ProfileStore: No profiles found in storage")
            return []
        }

        do {
            // Decode profiles — credentials will be nil (excluded from CodingKeys)
            var profiles = try JSONDecoder().decode([Profile].self, from: data)

            // Re-hydrate credentials from Keychain
            for i in profiles.indices {
                hydrateCredentialsFromKeychain(for: &profiles[i])
            }

            LoggingService.shared.log("ProfileStore: Loaded \(profiles.count) profiles from storage (credentials from Keychain)")
            return profiles
        } catch {
            LoggingService.shared.logStorageError("loadProfiles", error: error)
            LoggingService.shared.logError("ProfileStore: Failed to decode profiles, returning empty array")
            return []
        }
    }

    func saveActiveProfileId(_ id: UUID) {
        defaults.set(id.uuidString, forKey: Keys.activeProfileId)
    }

    func loadActiveProfileId() -> UUID? {
        guard let uuidString = defaults.string(forKey: Keys.activeProfileId) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    func saveDisplayMode(_ mode: ProfileDisplayMode) {
        defaults.set(mode.rawValue, forKey: Keys.displayMode)
    }

    func loadDisplayMode() -> ProfileDisplayMode {
        guard let rawValue = defaults.string(forKey: Keys.displayMode),
              let mode = ProfileDisplayMode(rawValue: rawValue) else {
            return .single
        }
        return mode
    }

    // MARK: - Multi-Profile Display Config

    func saveMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: Keys.multiProfileConfig)
        } catch {
            LoggingService.shared.logStorageError("saveMultiProfileConfig", error: error)
        }
    }

    func loadMultiProfileConfig() -> MultiProfileDisplayConfig {
        guard let data = defaults.data(forKey: Keys.multiProfileConfig) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(MultiProfileDisplayConfig.self, from: data)
        } catch {
            LoggingService.shared.logStorageError("loadMultiProfileConfig", error: error)
            return .default
        }
    }

    // MARK: - Credential Helpers

    func saveProfileCredentials(_ profileId: UUID, credentials: ProfileCredentials) throws {
        var profiles = loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw NSError(domain: "ProfileStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Profile not found"])
        }

        // Update credential fields on the in-memory profile
        profiles[index].claudeSessionKey = credentials.claudeSessionKey
        profiles[index].organizationId = credentials.organizationId
        profiles[index].apiSessionKey = credentials.apiSessionKey
        profiles[index].apiOrganizationId = credentials.apiOrganizationId
        profiles[index].cliCredentialsJSON = credentials.cliCredentialsJSON

        // saveProfiles will persist credentials to Keychain and non-credential data to UserDefaults
        saveProfiles(profiles)
    }

    func loadProfileCredentials(_ profileId: UUID) throws -> ProfileCredentials {
        let profiles = loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileId }) else {
            throw NSError(domain: "ProfileStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Profile not found"])
        }

        // Credentials have already been hydrated from Keychain by loadProfiles()
        return ProfileCredentials(
            claudeSessionKey: profile.claudeSessionKey,
            organizationId: profile.organizationId,
            apiSessionKey: profile.apiSessionKey,
            apiOrganizationId: profile.apiOrganizationId,
            cliCredentialsJSON: profile.cliCredentialsJSON
        )
    }

    // MARK: - Private Keychain Helpers

    /// Deletes all Keychain credentials for a given profile.
    /// Called when a profile is deleted to avoid orphaned Keychain entries.
    func deleteProfileCredentials(profileId: UUID) {
        keychainService.deleteProfileCredentials(profileId: profileId)
    }

    /// Syncs a profile's in-memory credentials to Keychain.
    /// Saves non-nil values and deletes Keychain entries for nil values.
    private func saveCredentialsToKeychain(for profile: Profile) {
        if let claudeKey = profile.claudeSessionKey {
            keychainService.saveProfileCredential(claudeKey, profileId: profile.id, key: "claude-key")
        } else {
            deleteKeychainCredential(profileId: profile.id, key: "claude-key")
        }
        if let apiKey = profile.apiSessionKey {
            keychainService.saveProfileCredential(apiKey, profileId: profile.id, key: "api-key")
        } else {
            deleteKeychainCredential(profileId: profile.id, key: "api-key")
        }
        if let cliCreds = profile.cliCredentialsJSON {
            keychainService.saveProfileCredential(cliCreds, profileId: profile.id, key: "cli-creds")
        } else {
            deleteKeychainCredential(profileId: profile.id, key: "cli-creds")
        }
    }

    /// Deletes a single Keychain credential entry for a profile.
    private func deleteKeychainCredential(profileId: UUID, key: String) {
        let service = "com.claudewidget.\(key)-\(profileId.uuidString)"
        let account = "profile-credential"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }

    /// Loads credentials from Keychain into the profile's in-memory fields.
    private func hydrateCredentialsFromKeychain(for profile: inout Profile) {
        profile.claudeSessionKey = keychainService.loadProfileCredential(profileId: profile.id, key: "claude-key")
        profile.apiSessionKey = keychainService.loadProfileCredential(profileId: profile.id, key: "api-key")
        profile.cliCredentialsJSON = keychainService.loadProfileCredential(profileId: profile.id, key: "cli-creds")
    }
}
