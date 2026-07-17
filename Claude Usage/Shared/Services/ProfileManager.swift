//
//  ProfileManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Combine

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [Profile] = []
    @Published var activeProfile: Profile?
    @Published var displayMode: ProfileDisplayMode = .single
    @Published var multiProfileConfig: MultiProfileDisplayConfig = .default
    @Published var isSwitchingProfile: Bool = false

    /// Per-provider active accounts. Two accounts are "active" at any time — one
    /// Claude (owns the Claude Code CLI Keychain login) and one Codex (owns
    /// ~/.codex/auth.json). `activeProfile` is only the FOCUSED profile; these track
    /// which profile each CLI is actually logged into, so switching a Codex profile
    /// influences only the other Codex account and vice versa.
    @Published private(set) var activeClaudeProfileId: UUID?
    @Published private(set) var activeCodexProfileId: UUID?

    private let profileStore = ProfileStore.shared
    private let cliSyncService = ClaudeCodeSyncService.shared

    private var switchingSemaphore = false

    /// Observer that re-reads profiles once the background Keychain credential load completes.
    private var credentialsReadyObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Initialization

    func loadProfiles() {
        registerCredentialsReadyObserverIfNeeded()

        profiles = profileStore.loadProfiles()

        // Ensure minimum profiles exist
        if profiles.isEmpty {
            let defaultProfiles = createDefaultProfiles()
            profiles = defaultProfiles
            profileStore.saveProfiles(profiles)

            // On first launch, try to sync CLI credentials to the first default profile
            syncCLICredentialsToDefaultProfile(defaultProfiles[0].id)
        }

        // Load active profile
        if let activeId = profileStore.loadActiveProfileId(),
           let profile = profiles.first(where: { $0.id == activeId }) {
            activeProfile = profile
        } else {
            activeProfile = profiles.first
            if let first = profiles.first {
                profileStore.saveActiveProfileId(first.id)
            }
        }

        displayMode = profileStore.loadDisplayMode()
        multiProfileConfig = profileStore.loadMultiProfileConfig()

        activeClaudeProfileId = profileStore.loadActiveClaudeProfileId()
        activeCodexProfileId = profileStore.loadActiveCodexProfileId()

        LoggingService.shared.log("ProfileManager: Loaded \(profiles.count) profile(s), active: \(activeProfile?.name ?? "none")")
    }

    // MARK: - Profile Operations

    func createProfile(name: String? = nil, copySettingsFrom: Profile? = nil) -> Profile {
        let profileName = name ?? "Profile \(profiles.count + 1)"

        let newProfile = Profile(
            id: UUID(),
            name: profileName,
            hasCliAccount: false,
            iconConfig: copySettingsFrom?.iconConfig ?? .default,
            refreshInterval: copySettingsFrom?.refreshInterval ?? 30.0,
            checkOverageLimitEnabled: copySettingsFrom?.checkOverageLimitEnabled ?? true,
            notificationSettings: copySettingsFrom?.notificationSettings ?? NotificationSettings(),
            isSelectedForDisplay: true
        )

        profiles.append(newProfile)
        profileStore.saveProfiles(profiles)

        LoggingService.shared.log("Created new profile: \(newProfile.name)")
        return newProfile
    }

    func updateProfile(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile

            if activeProfile?.id == profile.id {
                activeProfile = profile

                // Detailed logging for credential state
                LoggingService.shared.log("ProfileManager.updateProfile: Updated ACTIVE profile '\(profile.name)'")
                LoggingService.shared.log("  - claudeSessionKey: \(profile.claudeSessionKey == nil ? "NIL" : "EXISTS")")
                LoggingService.shared.log("  - organizationId: \(profile.organizationId == nil ? "NIL" : "EXISTS")")
                LoggingService.shared.log("  - hasClaudeAI: \(profile.hasClaudeAI)")
                LoggingService.shared.log("  - hasAnyCredentials: \(profile.hasAnyCredentials)")
                LoggingService.shared.log("  - claudeUsage: \(profile.claudeUsage == nil ? "NIL" : "EXISTS")")
            } else {
                LoggingService.shared.log("Updated profile: \(profile.name) (not active)")
            }

            profileStore.saveProfiles(profiles)
        }
    }

    func deleteProfile(_ id: UUID) throws {
        guard profiles.count > 1 else {
            throw ProfileError.cannotDeleteLastProfile
        }

        let profileName = profiles.first(where: { $0.id == id })?.name ?? "unknown"

        // Release provider-active ownership if the deleted profile held it
        if activeClaudeProfileId == id {
            activeClaudeProfileId = nil
            profileStore.saveActiveClaudeProfileId(nil)
        }
        if activeCodexProfileId == id {
            activeCodexProfileId = nil
            profileStore.saveActiveCodexProfileId(nil)
        }

        // Delete Keychain credentials before removing from the array
        profileStore.deleteProfileCredentials(profileId: id)

        profiles.removeAll { $0.id == id }

        // Switch to first profile if deleted active
        if activeProfile?.id == id {
            if let first = profiles.first {
                Task {
                    await activateProfile(first.id)
                }
            }
        }

        profileStore.saveProfiles(profiles)
        LoggingService.shared.log("Deleted profile: \(profileName)")
    }

    func toggleProfileSelection(_ id: UUID) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = self.profiles.firstIndex(where: { $0.id == id }) {
                self.profiles[index].isSelectedForDisplay.toggle()
                self.profileStore.saveProfiles(self.profiles)
            }
        }
    }

    func getSelectedProfiles() -> [Profile] {
        displayMode == .single
            ? [activeProfile].compactMap { $0 }
            : profiles.filter { $0.isSelectedForDisplay }
    }

    func updateDisplayMode(_ mode: ProfileDisplayMode) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.displayMode = mode
            self?.profileStore.saveDisplayMode(mode)
            LoggingService.shared.log("Updated display mode to: \(mode.rawValue)")
        }
    }

    func updateMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.multiProfileConfig = config
            self?.profileStore.saveMultiProfileConfig(config)
            LoggingService.shared.log("Updated multi-profile config: style=\(config.iconStyle.rawValue), showWeek=\(config.showWeek)")
        }
    }

    // MARK: - Profile Activation (Centralized)

    /// Returns false when the switch could not take over a provider login the
    /// profile carries (dead credentials were NOT applied — see the gates below),
    /// so callers like the auto-switch can try a different candidate.
    @discardableResult
    /// `userInitiated` marks a switch the user asked for by clicking a menu/button.
    /// The dead-login gate then re-delivers the re-login notification even if one
    /// was already sent — a silent no-op on a manual click reads as a broken
    /// button, not as a safety gate.
    func activateProfile(_ id: UUID, userInitiated: Bool = false) async -> Bool {
        guard !switchingSemaphore else {
            LoggingService.shared.log("Profile switch already in progress, ignoring")
            return false
        }

        guard let profile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("Profile not found: \(id)")
            return false
        }

        if activeProfile?.id == id {
            LoggingService.shared.log("Profile already active: \(profile.name)")
            return true
        }

        switchingSemaphore = true
        isSwitchingProfile = true

        LoggingService.shared.log("Switching to profile: \(profile.name)")

        // Provider-scoped handoff: activating a profile only replaces the shared
        // login state of the providers THAT PROFILE carries. Switching to a Codex
        // profile touches only ~/.codex/auth.json (the outgoing CODEX account is
        // re-adopted first) and leaves the Claude Code CLI login untouched;
        // switching to a Claude profile does the reverse. The outgoing account of
        // each provider is tracked separately from the focused profile — the two
        // can differ (e.g. focused on Claude while a Codex account is also active).

        profiles = profileStore.loadProfiles()
        let target = profiles.first(where: { $0.id == id })

        // 1. Claude side: the CLI Keychain login is about to be replaced — re-adopt
        //    it (incl. any silent token refresh) into the profile that owns it.
        //    The `security` subprocess runs off the main actor so the UI never freezes.
        if target?.cliCredentialsJSON != nil,
           let outgoingId = activeClaudeProfileId ?? (activeProfile?.cliCredentialsJSON != nil ? activeProfile?.id : nil),
           outgoingId != id,
           profiles.first(where: { $0.id == outgoingId })?.cliCredentialsJSON != nil {
            do {
                // Async + account-matched: the `security` read stays off-main inside,
                // and the outgoing profile refuses a login known to be another
                // account's (see adoptionAccountMatches).
                try await ClaudeCodeSyncService.shared.resyncBeforeSwitching(for: outgoingId)
                LoggingService.shared.log("✓ Re-synced outgoing Claude account before switching")
            } catch {
                LoggingService.shared.logError("Failed to re-sync outgoing Claude account (non-fatal)", error: error)
            }
            profiles = profileStore.loadProfiles()
        }

        // 2. Codex side: auth.json is about to be replaced — adopt the codex CLI's
        //    silent refreshes back into the outgoing Codex profile (account-matched,
        //    so a stale id can never mix accounts).
        if target?.codexCredentialsJSON != nil,
           let outgoingId = activeCodexProfileId, outgoingId != id {
            await runOffMainActor {
                CodexUsageService.shared.adoptAuthFileIfSameAccount(for: outgoingId)
            }
            profiles = profileStore.loadProfiles()
        }

        // Get the updated target profile from the reloaded data
        guard var updatedProfile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("Profile not found after reload: \(id)")
            switchingSemaphore = false
            isSwitchingProfile = false
            return false
        }

        // Set when a provider login the profile carries could NOT be handed to the
        // CLI because the stored credentials are dead (expired + unrefreshable).
        var deadLoginSkipped = false

        // Apply new profile's CLI credentials (if available)
        LoggingService.shared.log("Checking CLI credentials for profile '\(updatedProfile.name)': hasJSON=\(updatedProfile.cliCredentialsJSON != nil)")

        if updatedProfile.cliCredentialsJSON != nil {
            // If the target's OAuth token went stale while it was inactive, refresh it
            // FIRST so the CLI is handed a usable login instead of an expired token.
            // Never adopt from the system Keychain here — at this point it still holds
            // the PREVIOUS profile's account. syncToSystem is false because
            // applyProfileCredentials writes the credentials to the system right after.
            if await cliSyncService.ensureFreshCredentials(for: id, adoptSystemKeychain: false, syncToSystem: false) {
                profiles = profileStore.loadProfiles()
                if let refreshed = profiles.first(where: { $0.id == id }) {
                    updatedProfile = refreshed
                }
                LoggingService.shared.log("✓ Refreshed stale CLI token for '\(updatedProfile.name)' before applying")
            }
        }

        if let cliJSON = updatedProfile.cliCredentialsJSON {
            // GATE: never hand the CLI a dead login. If the token is still expired
            // after the refresh attempt above, its refresh token is revoked or
            // consumed — writing it would replace the WORKING outgoing login with
            // credentials no session can use, bricking every running Claude Code
            // session with "login expired. Please run /login". Keep the outgoing
            // login in place and tell the user this account needs a manual /login.
            if cliSyncService.isTokenExpired(cliJSON) {
                deadLoginSkipped = true
                cliSyncService.notifyReloginNeeded(for: id, force: userInitiated)
                LoggingService.shared.log("⛔️ '\(updatedProfile.name)' CLI login is dead (expired, unrefreshable) — NOT applied, outgoing login kept")
            } else {
                let targetProfileId = updatedProfile.id
                let targetProfileName = updatedProfile.name
                await runOffMainActor {
                    do {
                        try ClaudeCodeSyncService.shared.applyProfileCredentials(targetProfileId)
                        LoggingService.shared.log("✓ Applied CLI credentials for: \(targetProfileName)")
                    } catch {
                        LoggingService.shared.logError("Failed to apply CLI credentials (non-fatal)", error: error)
                    }
                }
                // Claim ownership IMMEDIATELY after the apply — the shared login
                // just changed hands, and any await between the apply and the
                // pointer update is a window where a concurrent sweep would adopt
                // the NEW login into the OLD owner's profile (cross-account
                // contamination — a real incident).
                activeClaudeProfileId = id
                profileStore.saveActiveClaudeProfileId(id)

                // Learn/refresh the applied login's account identity in the
                // background so future adoptions stay account-matched.
                Task { await ClaudeCodeSyncService.shared.stampAccountIdentity(for: id) }
            }
        } else {
            LoggingService.shared.log("⚠️ Profile '\(updatedProfile.name)' has no CLI credentials JSON")
        }

        // Apply the profile's Codex account (if any) to ~/.codex/auth.json so the
        // `codex` CLI switches accounts along with the app.
        if updatedProfile.codexCredentialsJSON != nil {
            // Validate/refresh the stored tokens BEFORE handing them to the CLI
            // (parity with the Claude flow above). The stored copy may be days old;
            // requiring 24h of remaining validity means the CLI won't have to
            // refresh mid-session with a possibly-rotated-away refresh token —
            // that was the "refresh token was revoked" failure after a switch.
            // A revoked token is surfaced to the user by the service; the raw
            // copy is still applied so a transient refresh failure isn't fatal.
            if await CodexUsageService.shared.ensureFreshCredentials(for: id, freshFor: 24 * 3600) {
                profiles = profileStore.loadProfiles()
                if let refreshed = profiles.first(where: { $0.id == id }) {
                    updatedProfile = refreshed
                }
                LoggingService.shared.log("✓ Refreshed stale Codex token for '\(updatedProfile.name)' before applying")
            }

            // GATE: same rule as the Claude side — a login that is expired even
            // after the refresh attempt is dead, and writing it to auth.json would
            // break the codex CLI until a manual `codex login`.
            if let codexJSON = updatedProfile.codexCredentialsJSON,
               CodexUsageService.shared.isTokenExpired(codexJSON) {
                deadLoginSkipped = true
                CodexUsageService.shared.notifyReloginNeeded(for: id, force: userInitiated)
                LoggingService.shared.log("⛔️ '\(updatedProfile.name)' Codex login is dead (expired, unrefreshable) — NOT applied, outgoing login kept")
            } else {
                let targetProfileId = updatedProfile.id
                let targetProfileName = updatedProfile.name
                await runOffMainActor {
                    do {
                        try CodexUsageService.shared.applyProfileCredentials(targetProfileId)
                        LoggingService.shared.log("✓ Applied Codex credentials for: \(targetProfileName)")
                    } catch {
                        LoggingService.shared.logError("Failed to apply Codex credentials (non-fatal)", error: error)
                    }
                }
                // Same rule as the Claude side: pointer follows the apply with no
                // awaits in between.
                activeCodexProfileId = id
                profileStore.saveActiveCodexProfileId(id)
            }
        }

        // A gated switch must leave the FOCUS unchanged too, not just the shared
        // login: callers (auto-switch walking ranked candidates, retry sweeps)
        // treat false as "nothing happened" — flipping activeProfile onto a dead
        // account would point the UI (and single-profile mode's whole display) at
        // an account the CLI was never switched to, once per retry.
        if deadLoginSkipped {
            switchingSemaphore = false
            isSwitchingProfile = false
            LoggingService.shared.log("⛔️ Activation of '\(updatedProfile.name)' aborted (dead provider login NOT applied) — focus stays on the current profile")
            return false
        }

        // Update last used timestamp
        var updated = updatedProfile
        updated.lastUsedAt = Date()

        if let index = profiles.firstIndex(where: { $0.id == updatedProfile.id }) {
            profiles[index] = updated
        }

        activeProfile = updated
        profileStore.saveActiveProfileId(id)
        profileStore.saveProfiles(profiles)

        // Provider pointers were claimed immediately after each successful apply
        // (see above) — a gated dead login never claims, so the outgoing account
        // keeps owning the shared login.

        switchingSemaphore = false
        isSwitchingProfile = false

        // An explicit user choice must stick: tell the auto-switch machinery so
        // it doesn't immediately rotate away from an account the user picked
        // while it sits above a switch threshold (it re-arms on its own once
        // the account regains headroom).
        if userInitiated {
            NotificationCenter.default.post(name: .profileManuallyActivated, object: id)
        }

        LoggingService.shared.log("Successfully activated profile: \(updatedProfile.name)")
        return true
    }

    // MARK: - Provider Ownership

    /// Records `profileId` as the owner of the Claude Code CLI's shared Keychain
    /// login. Call right after syncing the system credentials INTO that profile —
    /// it then matches the shared login by construction, so the pointer must follow
    /// (a Sync used to leave the pointer on the previously active account, and the
    /// launch-time repair never re-checked a non-nil pointer).
    func claimActiveClaudeOwnership(_ profileId: UUID) {
        activeClaudeProfileId = profileId
        profileStore.saveActiveClaudeProfileId(profileId)
        LoggingService.shared.log("ProfileManager: '\(profiles.first(where: { $0.id == profileId })?.name ?? "?")' claimed the active Claude login")
    }

    /// Records `profileId` as the owner of ~/.codex/auth.json. Call right after
    /// syncing auth.json INTO that profile (see claimActiveClaudeOwnership).
    func claimActiveCodexOwnership(_ profileId: UUID) {
        activeCodexProfileId = profileId
        profileStore.saveActiveCodexProfileId(profileId)
        LoggingService.shared.log("ProfileManager: '\(profiles.first(where: { $0.id == profileId })?.name ?? "?")' claimed the active Codex login")
    }

    /// True if the profile owns its provider's shared CLI login — the Claude Code
    /// Keychain item or ~/.codex/auth.json. One Claude and one Codex account are
    /// active at any time, so up to TWO profiles carry the "Active" badge; the
    /// focused profile is a separate concept and gets no badge of its own.
    func isProviderActive(_ profile: Profile) -> Bool {
        profile.id == activeClaudeProfileId || profile.id == activeCodexProfileId
    }

    // MARK: - Credentials

    func loadCredentials(for profileId: UUID) throws -> ProfileCredentials {
        return try profileStore.loadProfileCredentials(profileId)
    }

    func saveCredentials(for profileId: UUID, credentials: ProfileCredentials) throws {
        try profileStore.saveProfileCredentials(profileId, credentials: credentials)

        // Update profile in memory
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].claudeSessionKey = credentials.claudeSessionKey
            profiles[index].organizationId = credentials.organizationId
            profiles[index].apiSessionKey = credentials.apiSessionKey
            profiles[index].apiOrganizationId = credentials.apiOrganizationId
            profiles[index].cliCredentialsJSON = credentials.cliCredentialsJSON
            profiles[index].codexCredentialsJSON = credentials.codexCredentialsJSON

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }
        }
    }

    /// Removes Claude.ai credentials for a profile
    func removeClaudeAICredentials(for profileId: UUID) throws {
        // Load and clear credentials from Keychain. saveProfiles never deletes on
        // nil (stale-save protection), so the removal must be explicit.
        var creds = try profileStore.loadProfileCredentials(profileId)
        creds.claudeSessionKey = nil
        creds.organizationId = nil
        try profileStore.saveProfileCredentials(profileId, credentials: creds)
        profileStore.clearProfileCredential(profileId, key: .claudeSessionKey)

        // Update Profile model in memory
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].claudeSessionKey = nil
            profiles[index].organizationId = nil
            profiles[index].claudeUsage = nil  // Clear saved usage data

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }

        LoggingService.shared.log("ProfileManager: Removed Claude.ai credentials for profile \(profileId)")

        // Post single notification for credential change
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    /// Removes API Console credentials for a profile
    func removeAPICredentials(for profileId: UUID) throws {
        // Load and clear credentials from Keychain (explicit removal — see above)
        var creds = try profileStore.loadProfileCredentials(profileId)
        creds.apiSessionKey = nil
        creds.apiOrganizationId = nil
        try profileStore.saveProfileCredentials(profileId, credentials: creds)
        profileStore.clearProfileCredential(profileId, key: .apiSessionKey)

        // Update Profile model in memory
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].apiSessionKey = nil
            profiles[index].apiOrganizationId = nil
            profiles[index].apiUsage = nil  // Clear saved usage data

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }

        LoggingService.shared.log("ProfileManager: Removed API credentials for profile \(profileId)")

        // Post single notification for credential change
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    // MARK: - Usage Data

    /// Saves Claude usage data for a specific profile
    func saveClaudeUsage(_ usage: ClaudeUsage, for profileId: UUID) {
        // Re-read the store FIRST: this runs right after a fetch, and the fetch may
        // have rotated this profile's credentials (Codex/CLI adoption or an OAuth
        // refresh) store-direct. saveProfiles syncs the credential cache from the
        // Profile objects it's given, so saving a stale in-memory array would
        // clobber the rotated tokens with the CONSUMED refresh token — which the
        // next refresh attempt then trips OpenAI/Anthropic reuse detection on
        // ("refresh token was revoked").
        profiles = profileStore.loadProfiles()

        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            LoggingService.shared.logError("saveClaudeUsage: Profile not found with ID: \(profileId)")
            return
        }

        // Defense in depth: never persist a sentinel reset stamp. Fetch paths heal
        // before display; this catches any save that skipped them (idempotent).
        var usage = usage
        usage.healMissingResetStamps(previous: profiles[index].claudeUsage)

        profiles[index].claudeUsage = usage

        // Update activeProfile reference if it's the same profile
        if activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }

        // Save to persistent storage
        profileStore.saveProfiles(profiles)
        LoggingService.shared.log("Saved Claude usage for profile: \(profiles[index].name)")
    }

    /// Loads Claude usage data for a specific profile
    func loadClaudeUsage(for profileId: UUID) -> ClaudeUsage? {
        return profiles.first(where: { $0.id == profileId })?.claudeUsage
    }

    /// Saves API usage data for a specific profile
    func saveAPIUsage(_ usage: APIUsage, for profileId: UUID) {
        // Same store re-read as saveClaudeUsage — never clobber credentials that
        // rotated during the fetch this call is reporting on.
        profiles = profileStore.loadProfiles()

        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            LoggingService.shared.logError("saveAPIUsage: Profile not found with ID: \(profileId)")
            return
        }

        profiles[index].apiUsage = usage

        // Update activeProfile reference if it's the same profile
        if activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }

        // Save to persistent storage
        profileStore.saveProfiles(profiles)
        LoggingService.shared.log("Saved API usage for profile: \(profiles[index].name)")
    }

    /// Loads API usage data for a specific profile
    func loadAPIUsage(for profileId: UUID) -> APIUsage? {
        return profiles.first(where: { $0.id == profileId })?.apiUsage
    }

    // MARK: - Profile Settings

    /// Updates icon configuration for a profile
    func updateIconConfig(_ config: MenuBarIconConfiguration, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].iconConfig = config

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates refresh interval for a profile
    func updateRefreshInterval(_ interval: TimeInterval, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].refreshInterval = interval

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates whether a profile may be chosen as an auto-switch target
    func updateAutoSwitchEnabled(_ enabled: Bool, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].isAutoSwitchEnabled = enabled

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
            LoggingService.shared.log("ProfileManager: Auto-switch \(enabled ? "enabled" : "disabled") for profile '\(profiles[index].name)'")
        }
    }

    /// Updates check overage limit setting for a profile
    func updateCheckOverageLimitEnabled(_ enabled: Bool, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].checkOverageLimitEnabled = enabled

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates notification settings for a profile
    func updateNotificationSettings(_ settings: NotificationSettings, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].notificationSettings = settings

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates organization ID for a profile
    func updateOrganizationId(_ orgId: String?, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].organizationId = orgId

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates API organization ID for a profile
    func updateAPIOrganizationId(_ orgId: String?, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].apiOrganizationId = orgId

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    // MARK: - Private Helpers

    /// Runs blocking work (e.g. `security` subprocesses, Keychain I/O) on a background
    /// queue and *suspends* — rather than blocks — the calling actor until it finishes.
    /// Keeps the main thread free so the UI stays responsive during a profile switch.
    private func runOffMainActor(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                work()
                continuation.resume()
            }
        }
    }

    /// Registers (once) an observer that re-reads profiles when ProfileStore finishes
    /// loading credentials from the Keychain on its background queue.
    private func registerCredentialsReadyObserverIfNeeded() {
        guard credentialsReadyObserver == nil else { return }
        credentialsReadyObserver = NotificationCenter.default.addObserver(
            forName: .profileCredentialsReady,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ProfileManager.shared.reloadAfterCredentialSync()
            }
        }
    }

    /// Re-reads profiles after the background Keychain credential load completes, so the
    /// UI picks up credentials that were not yet available at the synchronous startup load.
    private func reloadAfterCredentialSync() {
        let reloaded = profileStore.loadProfiles()
        guard !reloaded.isEmpty else { return }

        profiles = reloaded
        if let activeId = activeProfile?.id,
           let updatedActive = reloaded.first(where: { $0.id == activeId }) {
            activeProfile = updatedActive
        }

        LoggingService.shared.log("ProfileManager: Reloaded profiles after Keychain credential sync")

        // One-time: import a Codex CLI login into its own profile. Runs here (not at
        // startup) because the Keychain credential cache must be hydrated first to
        // know whether a codex profile already exists.
        autoImportCodexAccountIfNeeded()

        // Resolve/repair the per-provider active accounts now that credentials are
        // hydrated (before hydration every profile looks credential-less).
        resolveProviderActiveAccounts()

        // Let the menu bar / popover refresh now that credentials are available.
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    /// Validates the persisted per-provider active ids against the loaded profiles
    /// and infers them when missing (first run after the two-active-accounts update):
    /// - Claude: falls back to the focused profile when it holds CLI credentials.
    /// - Codex: matched by account_id against ~/.codex/auth.json — deterministic,
    ///   because that file IS the codex CLI's current login.
    private func resolveProviderActiveAccounts() {
        if let id = activeClaudeProfileId,
           profiles.first(where: { $0.id == id })?.cliCredentialsJSON == nil {
            activeClaudeProfileId = nil
        }
        if activeClaudeProfileId == nil,
           let focused = activeProfile, focused.cliCredentialsJSON != nil {
            activeClaudeProfileId = focused.id
        }
        profileStore.saveActiveClaudeProfileId(activeClaudeProfileId)

        // Unlike auth.json for Codex, the Claude credentials JSON carries no
        // account id — the shared login's TRUE owner is verified asynchronously
        // against the identity endpoint (a mislabeled pointer once let the app
        // bill days of sessions to the wrong account name).
        repairClaudeOwnerFromSystemIdentity()

        // auth.json IS the codex CLI's current login: whenever its account matches a
        // profile, that profile owns the shared login — even if the persisted pointer
        // disagrees (a Sync into another profile used to leave the pointer behind, and
        // a stale pointer made auto-switch watch an account the CLI wasn't using).
        let codexService = CodexUsageService.shared
        if let fileJSON = codexService.readAuthFile(),
           let fileAccount = codexService.extractAccountId(from: fileJSON),
           let owner = profiles.first(where: {
               $0.codexCredentialsJSON.flatMap(codexService.extractAccountId(from:)) == fileAccount
           }) {
            activeCodexProfileId = owner.id
        } else {
            if let id = activeCodexProfileId,
               profiles.first(where: { $0.id == id })?.codexCredentialsJSON == nil {
                activeCodexProfileId = nil
            }
            if activeCodexProfileId == nil {
                let codexProfiles = profiles.filter { $0.hasCodexAccount }
                if codexProfiles.count == 1 {
                    activeCodexProfileId = codexProfiles[0].id
                }
            }
        }
        profileStore.saveActiveCodexProfileId(activeCodexProfileId)

        LoggingService.shared.log("ProfileManager: active Claude=\(profiles.first(where: { $0.id == activeClaudeProfileId })?.name ?? "none"), active Codex=\(profiles.first(where: { $0.id == activeCodexProfileId })?.name ?? "none")")
    }

    /// Verifies WHO the shared Claude Code login actually belongs to (via the
    /// account identity endpoint) and repairs the bookkeeping to match:
    /// - The pointer moves to the profile whose stamped account uuid — or, as a
    ///   fallback, whose claude.ai organizationId — matches the live token's
    ///   identity, even when the persisted pointer disagrees.
    /// - Any OTHER profile holding the same access token is contaminated (it
    ///   absorbed the owner's login through a pre-guard adoption); its CLI
    ///   credential copy is cleared so it stops impersonating the owner. The
    ///   token itself is never touched — running CLI sessions are unaffected.
    private func repairClaudeOwnerFromSystemIdentity() {
        Task { await adoptSystemLoginByIdentity() }
    }

    /// Same repair, callable on demand (runs after every sweep as well as at
    /// launch): resolves the shared login's live identity, routes the pointer to
    /// the matching profile, and — new — ADOPTS the login into that profile when
    /// its stored copy is older. This is what lets a plain `/login` in the CLI
    /// revive a dead profile without switching to it first (impossible — the
    /// dead-login gate refuses the switch) or relaunching the app. The identity
    /// lookup is cached per token, so steady-state sweeps cost nothing.
    /// True while an identity-routed adoption pass is running (they can be
    /// triggered from launch AND from sweep-end; overlapping passes would race
    /// each other's saves).
    private var identityAdoptionInFlight = false

    @discardableResult
    func adoptSystemLoginByIdentity() async -> String? {
        // Never touch shared-login bookkeeping mid-switch (contamination window).
        guard !isSwitchingProfile, !identityAdoptionInFlight else { return nil }
        identityAdoptionInFlight = true
        defer { identityAdoptionInFlight = false }

        let sync = ClaudeCodeSyncService.shared
        guard let systemJSON = try? await sync.readSystemCredentialsOffMain(),
              let systemToken = sync.extractAccessToken(from: systemJSON),
              let identity = await sync.fetchAccountIdentity(accessToken: systemToken) else { return nil }

        // The awaits above are suspension points: a switch may have STARTED (or
        // finished, rewriting the shared login) while the identity fetch was in
        // flight. Re-validate both before acting on what is now stale data —
        // adoption stays identity-keyed either way (a token can only ever land
        // in the profile its LIVE identity matches), but a stale pass could
        // still wobble the ownership pointer for a sweep.
        guard !isSwitchingProfile else { return nil }
        guard let recheckJSON = try? await sync.readSystemCredentialsOffMain(),
              sync.extractAccessToken(from: recheckJSON) == systemToken,
              !isSwitchingProfile else {
            return nil  // the shared login changed under us — next sweep re-runs
        }

        var reloaded = profileStore.loadProfiles()
        let owner = reloaded.first(where: { $0.claudeAccountUUID == identity.accountUUID })
            ?? reloaded.first(where: {
                $0.cliCredentialsJSON != nil && !identity.organizationUUID.isEmpty
                    && $0.organizationId == identity.organizationUUID
            })
        guard let owner else { return nil }

        if activeClaudeProfileId != owner.id {
            LoggingService.shared.log("ProfileManager: ⚠️ active Claude pointer repaired — the shared login's identity matches '\(owner.name)', not '\(reloaded.first(where: { $0.id == activeClaudeProfileId })?.name ?? "none")'")
            activeClaudeProfileId = owner.id
            profileStore.saveActiveClaudeProfileId(owner.id)
        }

        var changed = false
        if let index = reloaded.firstIndex(where: { $0.id == owner.id }) {
            if reloaded[index].claudeAccountUUID != identity.accountUUID
                || reloaded[index].claudeAccountEmail != identity.email {
                reloaded[index].claudeAccountUUID = identity.accountUUID
                reloaded[index].claudeAccountEmail = identity.email.isEmpty ? nil : identity.email
                reloaded[index].claudeOrganizationUUID = identity.organizationUUID.isEmpty ? nil : identity.organizationUUID
                changed = true
            }

            // Adopt the shared login into its owner when the stored copy is a
            // DIFFERENT, older token (typical after a manual /login that revived
            // a dead account). Expiry decides — never overwrite a fresher copy.
            let ownerToken = reloaded[index].cliCredentialsJSON.flatMap(sync.extractAccessToken(from:))
            let systemExpiry = sync.extractTokenExpiry(from: systemJSON) ?? .distantPast
            let ownerExpiry = reloaded[index].cliCredentialsJSON.flatMap(sync.extractTokenExpiry(from:)) ?? .distantPast
            if ownerToken != systemToken, systemExpiry > ownerExpiry {
                reloaded[index].cliCredentialsJSON = systemJSON
                reloaded[index].hasCliAccount = true
                reloaded[index].cliAccountSyncedAt = Date()
                sync.markLoginRevived(owner.id)
                changed = true
                LoggingService.shared.log("ProfileManager: ✓ adopted the CLI's fresh login into '\(owner.name)' (identity-matched)")
            }
        }

        // Contamination dedupe: a profile OTHER than the owner holding the
        // owner's account is a mislabeled duplicate — either a byte-identical
        // copy of the live token, or a STALE same-account token absorbed
        // earlier (its fetches then lose the per-account rate limit race to
        // the owner's every sweep). Clear both kinds (nil never deletes on
        // save, so the explicit clear is the only removal path — by design).
        for profile in reloaded where profile.id != owner.id {
            guard let json = profile.cliCredentialsJSON,
                  let index = reloaded.firstIndex(where: { $0.id == profile.id }) else { continue }
            let sameToken = sync.extractAccessToken(from: json) == systemToken
            let sameAccountStamp = profile.claudeAccountUUID == identity.accountUUID
            guard sameToken || sameAccountStamp else { continue }
            profileStore.clearProfileCredential(profile.id, key: .cliCredentials)
            reloaded[index].cliCredentialsJSON = nil
            reloaded[index].hasCliAccount = false
            reloaded[index].cliAccountSyncedAt = nil
            reloaded[index].claudeAccountUUID = nil
            reloaded[index].claudeAccountEmail = nil
            reloaded[index].claudeOrganizationUUID = nil
            changed = true
            LoggingService.shared.log("ProfileManager: ⚠️ cleared '\(profile.name)' CLI credentials — \(sameToken ? "a copy of" : "a stale token from") '\(owner.name)'s account (cross-account contamination)")
        }

        if changed {
            profileStore.saveProfiles(reloaded)
            profiles = profileStore.loadProfiles()
            if let activeId = activeProfile?.id,
               let updatedActive = profiles.first(where: { $0.id == activeId }) {
                activeProfile = updatedActive
            }
        }
        return owner.name
    }

    /// If the user is logged into the codex CLI (~/.codex/auth.json exists) and no
    /// profile holds Codex credentials yet, create a dedicated Codex profile once.
    /// Additional Codex accounts are added manually: log into the other account with
    /// `codex`, create a profile, and use Settings → Codex Account → Sync.
    private func autoImportCodexAccountIfNeeded() {
        let flagKey = "codexAutoImported_v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard !profiles.contains(where: { $0.hasCodexAccount }) else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }

        let codexService = CodexUsageService.shared
        guard let authJSON = codexService.readAuthFile(),
              codexService.extractAccessToken(from: authJSON) != nil else {
            // Not logged into codex — retry next launch (don't set the flag).
            return
        }

        let email = codexService.extractEmail(from: authJSON)
        let newProfile = Profile(
            name: email.map { "Codex (\($0))" } ?? "Codex",
            codexCredentialsJSON: authJSON,
            codexEmail: email,
            codexAccountSyncedAt: Date(),
            iconConfig: .default,
            refreshInterval: 60.0,
            checkOverageLimitEnabled: false,
            notificationSettings: NotificationSettings(),
            isSelectedForDisplay: true
        )

        profiles.append(newProfile)
        profileStore.saveProfiles(profiles)
        UserDefaults.standard.set(true, forKey: flagKey)
        LoggingService.shared.log("ProfileManager: ✅ Auto-imported Codex account '\(email ?? "unknown")' as profile '\(newProfile.name)'")
    }

    /// Syncs CLI credentials to default profile on first launch only.
    /// The read shells out to `security` (and may hit the Keychain), so ALL of it
    /// runs on a background queue — this used to run synchronously on the main
    /// actor, violating the "never read Keychain item data on the main thread" rule.
    private func syncCLICredentialsToDefaultProfile(_ profileId: UUID) {
        Task {
            let syncService = cliSyncService
            let synced: Bool = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        // Attempt to read credentials from system Keychain
                        guard let jsonData = try syncService.readSystemCredentials() else {
                            LoggingService.shared.log("ProfileManager: No CLI credentials found in system Keychain")
                            continuation.resume(returning: false)
                            return
                        }

                        // Validate: not expired
                        if syncService.isTokenExpired(jsonData) {
                            LoggingService.shared.log("ProfileManager: CLI credentials found but expired")
                            continuation.resume(returning: false)
                            return
                        }

                        // Validate: has valid access token
                        guard syncService.extractAccessToken(from: jsonData) != nil else {
                            LoggingService.shared.log("ProfileManager: CLI credentials found but missing access token")
                            continuation.resume(returning: false)
                            return
                        }

                        // Sync to the newly created default profile
                        try syncService.syncToProfile(profileId)
                        continuation.resume(returning: true)
                    } catch {
                        LoggingService.shared.logError("ProfileManager: Failed to sync CLI credentials on first launch (non-fatal)", error: error)
                        // Non-fatal: profile will be created without credentials
                        // User can manually sync in settings
                        continuation.resume(returning: false)
                    }
                }
            }

            guard synced else { return }

            // Back on the main actor: reload so the UI picks up the credentials.
            profiles = profileStore.loadProfiles()
            if let activeId = activeProfile?.id,
               let updated = profiles.first(where: { $0.id == activeId }) {
                activeProfile = updated
            }
            claimActiveClaudeOwnership(profileId)
            LoggingService.shared.log("ProfileManager: ✅ Successfully synced CLI credentials to default profile on first launch")
        }
    }

    private func createDefaultProfiles() -> [Profile] {
        let account1 = Profile(
            name: "Account 1",
            iconConfig: .default,
            refreshInterval: 30.0,
            checkOverageLimitEnabled: true,
            notificationSettings: NotificationSettings()
        )
        let account2 = Profile(
            name: "Account 2",
            iconConfig: .default,
            refreshInterval: 30.0,
            checkOverageLimitEnabled: true,
            notificationSettings: NotificationSettings()
        )
        return [account1, account2]
    }

}

// MARK: - ProfileError

enum ProfileError: LocalizedError {
    case cannotDeleteLastProfile

    var errorDescription: String? {
        switch self {
        case .cannotDeleteLastProfile:
            return "Cannot delete the last profile. At least one profile is required."
        }
    }
}
