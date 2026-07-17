//
//  ProfileStore.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Security

/// Manages storage and retrieval of profiles and profile-related data.
///
/// Credentials (claudeSessionKey, apiSessionKey, cliCredentialsJSON) are NEVER written to
/// UserDefaults — `Profile.CodingKeys` excludes them. They live in the macOS Keychain plus
/// an in-memory cache.
///
/// IMPORTANT: All Keychain *writes* happen on a background queue, and *reads* are served
/// from the in-memory cache. This is deliberate — reading a Keychain item's data can raise
/// a modal SecurityAgent prompt, and if that happens on the main thread the app deadlocks
/// (the prompt needs the very thread that is blocked waiting for it). `loadProfiles()`
/// therefore never touches the Keychain on the calling thread.
class ProfileStore {
    static let shared = ProfileStore()

    private let defaults: UserDefaults
    private let keychainService = KeychainService.shared

    /// Serial queue for all Keychain I/O — keeps it off the main thread.
    private let keychainQueue = DispatchQueue(label: "com.claudewidget.profilestore.keychain", qos: .userInitiated)

    /// In-memory credential cache. `loadProfiles()` hydrates from here, not the Keychain.
    private struct CachedCredentials: Equatable {
        var claudeSessionKey: String?
        var apiSessionKey: String?
        var cliCredentialsJSON: String?
        var codexCredentialsJSON: String?
        var grokCredentialsJSON: String?

        subscript(key: CredentialKey) -> String? {
            get {
                switch key {
                case .claudeSessionKey: return claudeSessionKey
                case .apiSessionKey: return apiSessionKey
                case .cliCredentials: return cliCredentialsJSON
                case .codexCredentials: return codexCredentialsJSON
                case .grokCredentials: return grokCredentialsJSON
                }
            }
            set {
                switch key {
                case .claudeSessionKey: claudeSessionKey = newValue
                case .apiSessionKey: apiSessionKey = newValue
                case .cliCredentials: cliCredentialsJSON = newValue
                case .codexCredentials: codexCredentialsJSON = newValue
                case .grokCredentials: grokCredentialsJSON = newValue
                }
            }
        }
    }
    private var credentialCache: [UUID: CachedCredentials] = [:]
    private let cacheLock = NSLock()

    /// The Keychain item behind each credential field. Raw values are the
    /// per-profile Keychain key suffixes used by KeychainService.
    enum CredentialKey: String, CaseIterable {
        case claudeSessionKey = "claude-key"
        case apiSessionKey = "api-key"
        case cliCredentials = "cli-creds"
        case codexCredentials = "codex-creds"
        case grokCredentials = "grok-creds"
    }

    private enum Keys {
        static let profiles = "profiles_v3"
        static let activeProfileId = "activeProfileId"
        static let displayMode = "profileDisplayMode"
        static let multiProfileConfig = "multiProfileDisplayConfig"
        static let credentialsMigratedToKeychain = "credentialsMigratedToKeychain"  // legacy v1 flag
        static let credentialsRepairedV2 = "credentialsRepairedToKeychain_v2"
        static let keychainRebuiltV3 = "keychainItemsRebuiltViaSecurityTool_v3"
    }

    init() {
        // Use standard UserDefaults (app container)
        self.defaults = UserDefaults.standard
        LoggingService.shared.log("ProfileStore: Using standard app container storage")

        // Populate the credential cache and repair Keychain ACLs if needed.
        bootstrapCredentials()
    }

    // MARK: - Credential Bootstrap & Migration

    /// Populates the in-memory credential cache at startup, and (once) repairs Keychain
    /// item ACLs that may have been invalidated by a code-signature change.
    private func bootstrapCredentials() {
        if defaults.bool(forKey: Keys.credentialsRepairedV2) {
            warmCacheFromKeychain()
        } else {
            runCredentialRepairV2()
        }
    }

    /// v2-already-done path: load credentials from the Keychain into the cache.
    /// The main-thread wait is bounded — permissive Keychain items resolve in
    /// microseconds, and a background pass finishes + notifies observers regardless.
    private func warmCacheFromKeychain() {
        let ids = storedProfileIds()
        guard !ids.isEmpty else { return }

        let sem = DispatchSemaphore(value: 0)
        keychainQueue.async { [weak self] in
            self?.readCredentialsIntoCache(profileIds: ids)
            sem.signal()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .profileCredentialsReady, object: nil)
            }
            // One-time: recreate every item through the security CLI so rebuilds
            // of this (ad-hoc signed) app stop triggering SecurityAgent prompts.
            self?.rebuildKeychainItemsViaSecurityToolIfNeeded()
        }
        // Insurance: never block the main thread more than 2s, even on an
        // unexpected authorization prompt. The background pass still completes.
        _ = sem.wait(timeout: .now() + 2.0)
    }

    /// One-time (v3): rebuilds every per-profile Keychain item through the
    /// security CLI. Items created by SecItemAdd carry a partition list stamped
    /// with the cdhash of whichever build created them; because this app is
    /// ad-hoc signed, EVERY rebuild has a new cdhash, fails the partition check,
    /// and raises one SecurityAgent prompt PER ITEM — "Always Allow" only
    /// whitelists the clicking build, which is why it never stuck. Items created
    /// by /usr/bin/security live in the `apple-tool:` partition and are readable
    /// by the security CLI forever, regardless of this app's signature; all
    /// KeychainService reads/writes now go through that CLI.
    ///
    /// Runs on keychainQueue AFTER the cache hydration, so every value is in
    /// memory: per item we add a backup copy first, then delete + re-add the
    /// canonical item, verify it reads back, and only then drop the backup — a
    /// crash mid-migration can always be recovered from on the next run.
    private func rebuildKeychainItemsViaSecurityToolIfNeeded() {
        guard !defaults.bool(forKey: Keys.keychainRebuiltV3) else { return }

        cacheLock.lock()
        var snapshot = credentialCache
        cacheLock.unlock()

        // Recover from a crash in a PREVIOUS migration run: a value whose backup
        // item exists but whose canonical read came back empty was caught between
        // delete and re-add — restore it from the backup before rebuilding.
        for profileId in snapshot.keys {
            for key in CredentialKey.allCases {
                let current = snapshot[profileId]?[key]
                guard current == nil,
                      let backup = keychainService.loadProfileCredential(profileId: profileId, key: key.rawValue + "-v3bak") else {
                    continue
                }
                LoggingService.shared.log("ProfileStore: recovered \(key.rawValue) for \(profileId.uuidString.prefix(8)) from v3 migration backup")
                snapshot[profileId]?[key] = backup
                cacheLock.lock()
                credentialCache[profileId]?[key] = backup
                cacheLock.unlock()
            }
        }

        var rebuilt = 0
        var failed = 0
        for (profileId, creds) in snapshot {
            let values: [(CredentialKey, String?)] = [
                (.claudeSessionKey, creds.claudeSessionKey),
                (.apiSessionKey, creds.apiSessionKey),
                (.cliCredentials, creds.cliCredentialsJSON),
                (.codexCredentials, creds.codexCredentialsJSON),
                (.grokCredentials, creds.grokCredentialsJSON)
            ]
            for (key, value) in values {
                guard let value else { continue }
                let backupKey = key.rawValue + "-v3bak"
                keychainService.saveProfileCredential(value, profileId: profileId, key: backupKey)
                keychainService.deleteProfileCredential(profileId: profileId, key: key.rawValue)
                keychainService.saveProfileCredential(value, profileId: profileId, key: key.rawValue)
                if keychainService.loadProfileCredential(profileId: profileId, key: key.rawValue) == value {
                    keychainService.deleteProfileCredential(profileId: profileId, key: backupKey)
                    rebuilt += 1
                } else {
                    // Restore from the in-memory value and leave the flag unset so
                    // the next launch retries this item.
                    keychainService.saveProfileCredential(value, profileId: profileId, key: key.rawValue)
                    failed += 1
                    LoggingService.shared.logError("ProfileStore: v3 keychain rebuild verify failed for \(key.rawValue) (\(profileId.uuidString.prefix(8)))")
                }
            }
        }

        if failed == 0 {
            defaults.set(true, forKey: Keys.keychainRebuiltV3)
            LoggingService.shared.log("ProfileStore: rebuilt \(rebuilt) Keychain item(s) via security CLI (v3) — rebuild prompts are gone for good")
        } else {
            LoggingService.shared.logError("ProfileStore: v3 keychain rebuild incomplete (\(rebuilt) ok, \(failed) failed) — will retry next launch")
        }
    }

    /// First run on a build with the new storage model. Recovers credentials from the
    /// legacy plaintext JSON (no Keychain access needed), strips the plaintext leak, and
    /// repairs Keychain items in the background — deleting each item (which drops the
    /// stale, signature-bound ACL) and re-adding it with a permissive ACL.
    private func runCredentialRepairV2() {
        // 1. Recover secrets from the legacy plaintext JSON (synchronous, no Keychain).
        var recovered: [UUID: CachedCredentials] = [:]
        if let data = defaults.data(forKey: Keys.profiles),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for dict in array {
                guard let idString = dict["id"] as? String,
                      let id = UUID(uuidString: idString) else { continue }
                recovered[id] = CachedCredentials(
                    claudeSessionKey: nonEmptyString(dict["claudeSessionKey"]),
                    apiSessionKey: nonEmptyString(dict["apiSessionKey"]),
                    cliCredentialsJSON: nonEmptyString(dict["cliCredentialsJSON"])
                )
            }
        }

        cacheLock.lock()
        credentialCache = recovered
        cacheLock.unlock()

        // 2. Strip plaintext secrets from the stored JSON immediately (privacy fix).
        stripPlaintextCredentialsFromStoredJSON()

        // 3. Repair Keychain ACLs in the background. A prompt here cannot deadlock the
        //    UI — it runs on a background queue.
        let ids = Array(recovered.keys)
        keychainQueue.async { [weak self] in
            guard let self else { return }
            for id in ids {
                var creds = recovered[id] ?? CachedCredentials()
                // For any secret missing from the JSON, recover it from the existing
                // Keychain item before the item is deleted.
                if creds.claudeSessionKey == nil {
                    creds.claudeSessionKey = self.keychainService.loadProfileCredential(profileId: id, key: "claude-key")
                }
                if creds.apiSessionKey == nil {
                    creds.apiSessionKey = self.keychainService.loadProfileCredential(profileId: id, key: "api-key")
                }
                if creds.cliCredentialsJSON == nil {
                    creds.cliCredentialsJSON = self.keychainService.loadProfileCredential(profileId: id, key: "cli-creds")
                }
                // Delete (drops the stale ACL) then re-add with a permissive ACL.
                self.keychainService.deleteProfileCredentials(profileId: id)
                self.writeCredentialItems(profileId: id, credentials: creds)

                self.cacheLock.lock()
                self.credentialCache[id] = creds
                self.cacheLock.unlock()
            }
            self.defaults.set(true, forKey: Keys.credentialsRepairedV2)
            // Items were just (re)written through the security CLI, so they are
            // already partition-safe — no separate v3 rebuild needed.
            self.defaults.set(true, forKey: Keys.keychainRebuiltV3)
            LoggingService.shared.log("ProfileStore: Keychain credential repair (v2) complete for \(ids.count) profile(s)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .profileCredentialsReady, object: nil)
            }
        }
    }

    /// Reads each profile's three credential items from the Keychain into the cache.
    private func readCredentialsIntoCache(profileIds: [UUID]) {
        for id in profileIds {
            let cached = CachedCredentials(
                claudeSessionKey: keychainService.loadProfileCredential(profileId: id, key: "claude-key"),
                apiSessionKey: keychainService.loadProfileCredential(profileId: id, key: "api-key"),
                cliCredentialsJSON: keychainService.loadProfileCredential(profileId: id, key: "cli-creds"),
                codexCredentialsJSON: keychainService.loadProfileCredential(profileId: id, key: "codex-creds"),
                grokCredentialsJSON: keychainService.loadProfileCredential(profileId: id, key: "grok-creds")
            )
            cacheLock.lock()
            credentialCache[id] = cached
            cacheLock.unlock()
        }
    }

    /// Removes the three credential keys from the stored profiles JSON.
    private func stripPlaintextCredentialsFromStoredJSON() {
        guard let data = defaults.data(forKey: Keys.profiles),
              var array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        var changed = false
        for i in array.indices {
            for key in ["claudeSessionKey", "apiSessionKey", "cliCredentialsJSON"] {
                if array[i].removeValue(forKey: key) != nil { changed = true }
            }
        }
        guard changed,
              let cleaned = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted]) else {
            return
        }
        defaults.set(cleaned, forKey: Keys.profiles)
        LoggingService.shared.log("ProfileStore: Stripped plaintext credentials from stored profiles JSON")
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private func storedProfileIds() -> [UUID] {
        guard let data = defaults.data(forKey: Keys.profiles),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
    }

    // MARK: - Profile Management

    func saveProfiles(_ profiles: [Profile]) {
        // 1. Sync credentials into the in-memory cache; persist changes to the
        //    Keychain on a background queue (never blocks the caller).
        //
        //    MERGE semantics: a nil credential field NEVER implies deletion here.
        //    Profile values may predate the background Keychain hydration (the
        //    startup cache warm-up waits at most 2s) — saving such a stale profile
        //    used to diff nil-vs-cached and enqueue Keychain deletions, silently
        //    destroying every credential on a slow Keychain. Intentional removal
        //    goes through clearProfileCredential(_:key:) instead.
        for profile in profiles {
            let incoming = CachedCredentials(
                claudeSessionKey: profile.claudeSessionKey,
                apiSessionKey: profile.apiSessionKey,
                cliCredentialsJSON: profile.cliCredentialsJSON,
                codexCredentialsJSON: profile.codexCredentialsJSON,
                grokCredentialsJSON: profile.grokCredentialsJSON
            )

            cacheLock.lock()
            let old = credentialCache[profile.id]
            let merged = CachedCredentials(
                claudeSessionKey: incoming.claudeSessionKey ?? old?.claudeSessionKey,
                apiSessionKey: incoming.apiSessionKey ?? old?.apiSessionKey,
                cliCredentialsJSON: incoming.cliCredentialsJSON ?? old?.cliCredentialsJSON,
                codexCredentialsJSON: incoming.codexCredentialsJSON ?? old?.codexCredentialsJSON,
                grokCredentialsJSON: incoming.grokCredentialsJSON ?? old?.grokCredentialsJSON
            )
            credentialCache[profile.id] = merged
            cacheLock.unlock()

            if merged != incoming {
                LoggingService.shared.log("ProfileStore: preserved cached credential(s) for \(profile.id) that the saved profile was missing (stale pre-hydration copy?)")
            }

            if merged != old {
                let profileId = profile.id
                keychainQueue.async { [weak self] in
                    self?.writeCredentialItems(profileId: profileId, credentials: merged)
                }
            }
        }

        // 2. Encode profiles WITHOUT credentials (Profile.CodingKeys excludes them),
        //    so the JSON written to UserDefaults contains NO secrets.
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(profiles)
            defaults.set(data, forKey: Keys.profiles)
            LoggingService.shared.log("ProfileStore: Saved \(profiles.count) profiles (\(data.count) bytes, credentials in Keychain)")
        } catch {
            LoggingService.shared.logStorageError("saveProfiles", error: error)
        }
    }

    /// Suspends until every Keychain write queued so far has been committed.
    /// Call after persisting a ROTATED refresh token: the old token is already
    /// consumed at the provider, so process death before the queue drains would
    /// lose the only working login for that account.
    func flushKeychainWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            keychainQueue.async { continuation.resume() }
        }
    }

    func loadProfiles() -> [Profile] {
        guard let data = defaults.data(forKey: Keys.profiles) else {
            LoggingService.shared.log("ProfileStore: No profiles found in storage")
            return []
        }

        do {
            // Decode profiles — credential fields are nil (excluded from CodingKeys).
            var profiles = try JSONDecoder().decode([Profile].self, from: data)

            // Re-hydrate credentials from the in-memory cache (no Keychain on this thread).
            for i in profiles.indices {
                hydrateCredentialsFromCache(for: &profiles[i])
            }

            LoggingService.shared.log("ProfileStore: Loaded \(profiles.count) profiles from storage (credentials from cache)")
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

    // MARK: - Per-Provider Active Accounts
    // Two accounts are "active" at any time — one Claude (owns the Claude Code CLI
    // Keychain login) and one Codex (owns ~/.codex/auth.json). Switching a profile
    // of one provider must never disturb the other provider's active account.

    func saveActiveClaudeProfileId(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: "activeClaudeProfileId")
    }

    func loadActiveClaudeProfileId() -> UUID? {
        defaults.string(forKey: "activeClaudeProfileId").flatMap(UUID.init(uuidString:))
    }

    func saveActiveCodexProfileId(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: "activeCodexProfileId")
    }

    func loadActiveCodexProfileId() -> UUID? {
        defaults.string(forKey: "activeCodexProfileId").flatMap(UUID.init(uuidString:))
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
        profiles[index].codexCredentialsJSON = credentials.codexCredentialsJSON
        profiles[index].grokCredentialsJSON = credentials.grokCredentialsJSON

        // saveProfiles persists credentials to the Keychain (cache + background queue)
        // and non-credential data to UserDefaults.
        saveProfiles(profiles)
    }

    func loadProfileCredentials(_ profileId: UUID) throws -> ProfileCredentials {
        let profiles = loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileId }) else {
            throw NSError(domain: "ProfileStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Profile not found"])
        }

        // Credentials have already been hydrated from the cache by loadProfiles()
        return ProfileCredentials(
            claudeSessionKey: profile.claudeSessionKey,
            organizationId: profile.organizationId,
            apiSessionKey: profile.apiSessionKey,
            apiOrganizationId: profile.apiOrganizationId,
            apiSessionKeyExpiry: profile.apiSessionKeyExpiry,
            cliCredentialsJSON: profile.cliCredentialsJSON,
            codexCredentialsJSON: profile.codexCredentialsJSON,
            grokCredentialsJSON: profile.grokCredentialsJSON
        )
    }

    // MARK: - Private Keychain Helpers

    /// Deletes all Keychain credentials for a given profile (called when a profile is
    /// deleted) and drops it from the in-memory cache.
    func deleteProfileCredentials(profileId: UUID) {
        cacheLock.lock()
        credentialCache.removeValue(forKey: profileId)
        cacheLock.unlock()

        keychainQueue.async { [weak self] in
            self?.keychainService.deleteProfileCredentials(profileId: profileId)
        }
    }

    /// Writes a profile's non-nil credentials to the Keychain. Nil fields are left
    /// untouched — deletion is only ever explicit (clearProfileCredential /
    /// deleteProfileCredentials). MUST be called on `keychainQueue`.
    private func writeCredentialItems(profileId: UUID, credentials: CachedCredentials) {
        syncCredentialItem(credentials.claudeSessionKey, profileId: profileId, key: CredentialKey.claudeSessionKey.rawValue)
        syncCredentialItem(credentials.apiSessionKey, profileId: profileId, key: CredentialKey.apiSessionKey.rawValue)
        syncCredentialItem(credentials.cliCredentialsJSON, profileId: profileId, key: CredentialKey.cliCredentials.rawValue)
        syncCredentialItem(credentials.codexCredentialsJSON, profileId: profileId, key: CredentialKey.codexCredentials.rawValue)
        syncCredentialItem(credentials.grokCredentialsJSON, profileId: profileId, key: CredentialKey.grokCredentials.rawValue)
    }

    private func syncCredentialItem(_ value: String?, profileId: UUID, key: String) {
        if let value {
            keychainService.saveProfileCredential(value, profileId: profileId, key: key)
        }
    }

    /// Explicitly removes ONE credential from a profile — the only way a single
    /// credential leaves the Keychain. Drops it from the in-memory cache
    /// immediately and deletes the Keychain item on the background queue.
    func clearProfileCredential(_ profileId: UUID, key: CredentialKey) {
        cacheLock.lock()
        var cached = credentialCache[profileId] ?? CachedCredentials()
        switch key {
        case .claudeSessionKey: cached.claudeSessionKey = nil
        case .apiSessionKey: cached.apiSessionKey = nil
        case .cliCredentials: cached.cliCredentialsJSON = nil
        case .codexCredentials: cached.codexCredentialsJSON = nil
        case .grokCredentials: cached.grokCredentialsJSON = nil
        }
        credentialCache[profileId] = cached
        cacheLock.unlock()

        keychainQueue.async { [weak self] in
            self?.deleteKeychainCredential(profileId: profileId, key: key.rawValue)
        }
        LoggingService.shared.log("ProfileStore: cleared credential '\(key.rawValue)' for profile \(profileId)")
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

    /// Loads credentials from the in-memory cache into the profile's fields.
    private func hydrateCredentialsFromCache(for profile: inout Profile) {
        cacheLock.lock()
        let cached = credentialCache[profile.id]
        cacheLock.unlock()

        profile.claudeSessionKey = cached?.claudeSessionKey
        profile.apiSessionKey = cached?.apiSessionKey
        profile.cliCredentialsJSON = cached?.cliCredentialsJSON
        profile.codexCredentialsJSON = cached?.codexCredentialsJSON
        profile.grokCredentialsJSON = cached?.grokCredentialsJSON
    }
}
