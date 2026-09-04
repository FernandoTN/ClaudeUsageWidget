//
//  ProfileManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Combine
import os.log

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [Profile] = [] {
        didSet { refreshDuplicateClaudeAccountGroups() }
    }
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

    /// Mirrors `ProfileStore.preferencesDegraded` for SwiftUI. True while macOS's
    /// preferences daemon is refusing reads and the store is serving cached values;
    /// settings changes will not persist until cfprefsd is restarted.
    @Published private(set) var preferencesDegraded: Bool = false

    /// Observer for `.preferencesDegradedStateChanged`.
    private var preferencesDegradedObserver: NSObjectProtocol?

    private let profileStore = ProfileStore.shared
    private let cliSyncService = ClaudeCodeSyncService.shared

    /// Passthrough of ProfileStore's credential-cache readiness so menu-bar /
    /// settings code can gate without reaching for the store singleton.
    var credentialHydrationState: ProfileStore.CredentialHydrationState {
        profileStore.credentialHydrationState
    }

    private var switchingSemaphore = false

    /// Observer that re-reads profiles once the background Keychain credential load completes.
    private var credentialsReadyObserver: NSObjectProtocol?

    /// In-memory usage updates waiting for a single disk write at a flush boundary.
    /// Re-applied after every store reload so unflushed usage is never dropped, and
    /// flushed via `applyUsagePatches` (usage-only — never writes credentials).
    private var pendingUsageByProfileID: [UUID: ProfileStore.UsagePatch] = [:]

    /// Display settings the user has explicitly chosen during THIS run. A reload
    /// re-reads everything outside this set, so an unset setting still heals when
    /// preferences recover; it never re-reads what is inside it. Deliberately not
    /// `private`: tests clear it to exercise the first-load path on the singleton,
    /// which outlives every test case.
    var displaySettingsChosenThisRun: Set<DisplaySetting> = []

    /// The store-backed display settings a reload is allowed to skip.
    enum DisplaySetting: Hashable {
        case displayMode
        case multiProfileConfig
    }

    private init() {}

    // MARK: - Initialization

    func loadProfiles() {
        registerCredentialsReadyObserverIfNeeded()
        registerPreferencesDegradedObserverIfNeeded()

        profiles = profileStore.loadProfiles()
        applyPendingOverlay(to: &profiles)

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

        hydrateDisplaySettings()

        LoggingService.shared.log("ProfileManager: Loaded \(profiles.count) profile(s), active: \(activeProfile?.name ?? "none")")
    }

    /// Reads the store-backed display settings that are NOT part of the profile
    /// array into their `@Published` properties.
    ///
    /// **A setting the user has already chosen this run is not re-read.**
    /// `loadProfiles()` is not only the startup load: it is also the RELOAD
    /// path, called after a CLI credential self-heal (so potentially before any
    /// usage fetch) and from the CLI / Codex account settings screens. On
    /// 2026-09-01 a wedged `cfprefsd` made reads unreliable for ~5.5 hours; ten
    /// runtime reloads landed inside that window and reset `multiProfileConfig`
    /// to `.default`, whose `iconStyle` is `.concentric`, so every menu-bar tile
    /// flipped from progress bars to circles while the on-disk plist still held
    /// `progressBar` all day. Nothing is posted and nothing is logged when that
    /// happens, so the revert is invisible in the app and in the unified log.
    ///
    /// `ProfileStore`'s last-known-good shadow already stops an EMPTY read from
    /// serving a default. This is the other half: a read that comes back
    /// PRESENT BUT STALE satisfies the shadow and overwrites it, so only the
    /// caller can protect a choice the user made after that snapshot was taken.
    /// The same wedge produced exactly that shape elsewhere — two reloads read
    /// back a 19-profile roster where 20 were stored.
    ///
    /// Settings the user has NOT chosen keep re-reading on every reload, which
    /// is what lets a cold launch into an already-wedged daemon recover: the
    /// shadow starts empty, so the first load can only see type defaults, and a
    /// blanket pin would hold those for the life of the process.
    ///
    /// The two per-provider active-login pointers are deliberately NOT pinned
    /// here. They have their own re-derivation path (`resolveProviderActiveAccounts`
    /// and the launch repair) whose job is to correct them, and `ProfileStore`'s
    /// pointer shadow already covers the empty-read case.
    private func hydrateDisplaySettings() {
        if !displaySettingsChosenThisRun.contains(.displayMode) {
            displayMode = profileStore.loadDisplayMode()
        }
        if !displaySettingsChosenThisRun.contains(.multiProfileConfig) {
            multiProfileConfig = profileStore.loadMultiProfileConfig()
        }

        activeClaudeProfileId = profileStore.loadActiveClaudeProfileId()
        activeCodexProfileId = profileStore.loadActiveCodexProfileId()
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
        ProfileCredentialStatusCache.invalidateAll()

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
        ProfileCredentialStatusCache.invalidateAll()

        // Switch to first profile if deleted active
        if activeProfile?.id == id {
            if let first = profiles.first {
                Task {
                    await activateProfile(first.id)
                }
            }
        }

        profileStore.saveProfiles(profiles)
        NotificationCenter.default.post(name: .profileDeleted, object: id)
        LoggingService.shared.log("Deleted profile: \(profileName)")
    }

    func toggleProfileSelection(_ id: UUID) {
        // Mutate synchronously (main-actor) so observers never rebuild from stale
        // selection; post structural notification AFTER the mutation.
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = profiles[index].isSelectedForDisplay
        profiles[index].isSelectedForDisplay.toggle()
        profileStore.saveProfiles(profiles)

        var userInfo: [AnyHashable: Any]? = nil
        if !wasSelected && profiles[index].isSelectedForDisplay {
            userInfo = ["addedProfileIds": [id.uuidString]]
        }
        NotificationCenter.default.post(
            name: .profileDisplayStructureChanged,
            object: nil,
            userInfo: userInfo
        )
    }

    func getSelectedProfiles() -> [Profile] {
        displayMode == .single
            ? [activeProfile].compactMap { $0 }
            : profiles.filter { $0.isSelectedForDisplay }
    }

    func updateDisplayMode(_ mode: ProfileDisplayMode) {
        // Mutate synchronously then notify — structural (which status items exist).
        displayMode = mode
        displaySettingsChosenThisRun.insert(.displayMode)
        profileStore.saveDisplayMode(mode)
        LoggingService.shared.log("Updated display mode to: \(mode.rawValue)")
        NotificationCenter.default.post(name: .profileDisplayStructureChanged, object: nil)
    }

    func updateMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        // Mutate synchronously then notify — cosmetic (how existing tiles look).
        multiProfileConfig = config
        displaySettingsChosenThisRun.insert(.multiProfileConfig)
        profileStore.saveMultiProfileConfig(config)
        LoggingService.shared.log("Updated multi-profile config: style=\(config.iconStyle.rawValue), showWeek=\(config.showWeek)")
        NotificationCenter.default.post(name: .profileDisplayCosmeticsChanged, object: nil)
    }

    // MARK: - Profile Activation (Centralized)

    /// Why an activation did or did not take effect.
    ///
    /// The distinction that matters is `switchInFlight` vs `credentialsRefused`:
    /// both used to collapse into `false`, and the auto-switch candidate walk
    /// read every `false` as "this account's login is dead", excluding a
    /// perfectly healthy candidate — and burning a usage fetch per candidate —
    /// whenever another switch happened to hold the semaphore (audit H6).
    /// A semaphore refusal says nothing about the candidate; it says "try again
    /// in a moment".
    enum ActivationOutcome {
        /// The switch ran and the profile is now active.
        case activated
        /// The profile was already the active one; nothing to do.
        case alreadyActive
        /// Another switch holds the semaphore. Nothing was attempted, and the
        /// target's credentials were never examined.
        case switchInFlight
        /// No profile with that id exists (deleted mid-walk).
        case profileNotFound
        /// The switch ran but a provider login the profile carries is dead
        /// (expired and unrefreshable), so it was deliberately NOT applied.
        case credentialsRefused
        /// A USER-initiated switch onto a profile whose provider login is dead:
        /// the dead login was NOT applied and the provider-active pointer stayed
        /// with its current owner, but the FOCUS moved so the profile can be
        /// viewed — and repaired — in Settings. The in-app re-login screens
        /// operate on the focused profile, so refusing to move the focus made a
        /// dead profile unreachable: the one click that could fix it was the one
        /// click the gate rejected (reported live 2026-09-03).
        ///
        /// This is NOT a landed switch. The auto-switch walk must treat it
        /// exactly like `.credentialsRefused` — but it can only be produced by a
        /// user-initiated activation, which the walk never performs.
        case focusedWithoutApplying

        /// Back-compat with the `Bool`-returning API: true only when the
        /// profile is active as a result of the call.
        ///
        /// `focusedWithoutApplying` is deliberately false: the CLI login did not
        /// change hands, and every Bool caller means "did the switch land".
        var didActivate: Bool {
            self == .activated || self == .alreadyActive
        }
    }

    /// Returns false when the switch could not take over a provider login the
    /// profile carries (dead credentials were NOT applied — see the gates below),
    /// so callers like the auto-switch can try a different candidate.
    /// Callers that must tell a dead login apart from a busy semaphore use
    /// `activateProfileDetailed` instead.
    @discardableResult
    /// `userInitiated` marks a switch the user asked for by clicking a menu/button.
    /// The dead-login gate then re-delivers the re-login notification even if one
    /// was already sent — a silent no-op on a manual click reads as a broken
    /// button, not as a safety gate.
    func activateProfile(_ id: UUID, userInitiated: Bool = false) async -> Bool {
        await activateProfileDetailed(id, userInitiated: userInitiated).didActivate
    }

    /// Same switch as `activateProfile`, reporting WHY it did not happen.
    @discardableResult
    func activateProfileDetailed(_ id: UUID, userInitiated: Bool = false) async -> ActivationOutcome {
        // Flush deferred usage BEFORE any switch work so a mid-switch store reload
        // cannot drop unflushed percentages, and so the switch never races a later
        // usage-only patch against credential handoff.
        flushPendingUsage()

        guard !switchingSemaphore else {
            LoggingService.shared.log("Profile switch already in progress, ignoring")
            return .switchInFlight
        }

        guard let profile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("Profile not found: \(id)")
            return .profileNotFound
        }

        if activeProfile?.id == id {
            LoggingService.shared.log("Profile already active: \(profile.name)")
            return .alreadyActive
        }

        switchingSemaphore = true
        isSwitchingProfile = true

        // Captured before any state changes — the history record needs the
        // OUTGOING account, and activeProfile is rewritten mid-switch.
        let outgoingNameForHistory = activeProfile?.name

        LoggingService.shared.log("Switching to profile: \(profile.name)")

        // Provider-scoped handoff: activating a profile only replaces the shared
        // login state of the providers THAT PROFILE carries. Switching to a Codex
        // profile touches only ~/.codex/auth.json (the outgoing CODEX account is
        // re-adopted first) and leaves the Claude Code CLI login untouched;
        // switching to a Claude profile does the reverse. The outgoing account of
        // each provider is tracked separately from the focused profile — the two
        // can differ (e.g. focused on Claude while a Codex account is also active).

        profiles = profileStore.loadProfiles()
        applyPendingOverlay(to: &profiles)
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
            applyPendingOverlay(to: &profiles)
        }

        // 2. Codex side: auth.json is about to be replaced — adopt the codex CLI's
        //    silent refreshes back into the outgoing Codex profile (account-matched,
        //    so a stale id can never mix accounts).
        //    The outgoing owner is resolved the same way the launch repair does
        //    — auth.json's account_id FIRST, the pointer second, the focused
        //    profile last. A nil/stale pointer used to skip the adoption
        //    entirely, and auth.json is then overwritten with the outgoing
        //    account's rotated refresh token never persisted (the CLI's
        //    "refresh token was revoked" after a later switch back).
        if target?.codexCredentialsJSON != nil,
           let outgoingId = resolveOutgoingCodexOwner(), outgoingId != id {
            await runOffMainActor {
                CodexUsageService.shared.adoptAuthFileIfSameAccount(for: outgoingId)
            }
            profiles = profileStore.loadProfiles()
            applyPendingOverlay(to: &profiles)
        }

        // Get the updated target profile from the reloaded data
        guard var updatedProfile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("Profile not found after reload: \(id)")
            switchingSemaphore = false
            isSwitchingProfile = false
            return .profileNotFound
        }

        // The providers whose login could NOT be handed to the CLI because the
        // stored credentials are dead (expired + unrefreshable). Kept per
        // provider, not as one flag, so the user-facing notice can name which
        // CLI stayed put and who still owns it.
        var refusedProviders: [RefusedProvider] = []

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
                applyPendingOverlay(to: &profiles)
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
            // `isLoginMarkedDead` joins the expiry check: a flagged login is one
            // the app has already told the user to re-`/login`, and handing it
            // to the CLI is the failure this gate exists to prevent. The flag
            // clears on any successful refresh, adoption or re-sync, so a
            // revived account is not held out.
            if cliSyncService.isTokenExpired(cliJSON) || cliSyncService.isLoginMarkedDead(id) {
                refusedProviders.append(.claude)
                // `force` is only needed when the click would otherwise be a
                // silent no-op. A user-initiated switch now MOVES THE FOCUS and
                // sends its own notice naming the repair, so re-delivering the
                // generic re-login alert on every click would just double-banner
                // the same fact. The auto path keeps its once-per-dead-login
                // dedup exactly as before.
                cliSyncService.notifyReloginNeeded(for: id, force: false)
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
                applyPendingOverlay(to: &profiles)
                if let refreshed = profiles.first(where: { $0.id == id }) {
                    updatedProfile = refreshed
                }
                LoggingService.shared.log("✓ Refreshed stale Codex token for '\(updatedProfile.name)' before applying")
            }

            // GATE: same rule as the Claude side, but expiry cannot carry it —
            // a Codex access token lives ~10 days, so a login revoked externally
            // (another account's `codex login` on this machine) passes an expiry
            // check for days while the codex CLI dies on it. The service asks the
            // account's own usage endpoint instead: measured 200 → apply, 401/403
            // → refuse, no answer → trust the dead flag (audit C2).
            if updatedProfile.codexCredentialsJSON != nil,
               !(await CodexUsageService.shared.isSafeToApplyLogin(for: id)) {
                refusedProviders.append(.codex)
                // Same reasoning as the Claude gate above.
                CodexUsageService.shared.notifyReloginNeeded(for: id, force: false)
                LoggingService.shared.log("⛔️ '\(updatedProfile.name)' Codex login failed its liveness check (expired, revoked, or refused by the account) — NOT applied, outgoing login kept")
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

        // An AUTOMATIC gated switch must leave the FOCUS unchanged too, not just
        // the shared login: the auto-switch walk and the retry sweeps treat a
        // refusal as "nothing happened", and flipping activeProfile onto a dead
        // account would point the UI (and single-profile mode's whole display) at
        // an account the CLI was never switched to, once per retry.
        //
        // A USER-initiated switch is the opposite case and falls through to the
        // focus-only path below: the user asked to LOOK at that profile, and the
        // in-app repair (Settings → Codex Account / CLI Account, which read
        // `activeProfile`) is reachable only once the focus is on it. Refusing to
        // move it made every dead profile permanently unrepairable in-app.
        if !refusedProviders.isEmpty && !userInitiated {
            switchingSemaphore = false
            isSwitchingProfile = false
            LoggingService.shared.log("⛔️ Activation of '\(updatedProfile.name)' aborted (dead provider login NOT applied) — focus stays on the current profile")
            return .credentialsRefused
        }

        // True when the focus is about to move WITHOUT the login being applied.
        // Implies `userInitiated` (the auto path returned above).
        let focusOnly = !refusedProviders.isEmpty

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

        // Persist the switch for forensics — the unified log keeps nothing for
        // this process, so this ring buffer is the only durable record of who
        // was active before a switch (a real reconstruction need, 2026-08-12).
        SharedDataStore.shared.recordSwitchEvent(SwitchEvent(
            at: Date(),
            from: outgoingNameForHistory ?? "none",
            to: updatedProfile.name,
            trigger: userInitiated ? .manual : .auto,
            reason: focusOnly
                ? "focus only — \(RefusedProvider.summary(refusedProviders)) login NOT applied, CLI unchanged"
                : nil
        ))

        if focusOnly {
            LoggingService.shared.log("👁 Focus moved to '\(updatedProfile.name)' WITHOUT applying its dead \(RefusedProvider.summary(refusedProviders)) login — the CLI keeps its current account")
            notifyFocusedWithoutApplying(profile: updatedProfile, refused: refusedProviders)
            return .focusedWithoutApplying
        }

        LoggingService.shared.log("Successfully activated profile: \(updatedProfile.name)")
        return .activated
    }

    // MARK: - Focus-Only Switch (dead provider login)

    /// A provider whose stored login the activation gate refused to apply.
    enum RefusedProvider: String {
        case claude
        case codex

        /// How the provider is named to the user.
        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        /// Where the in-app repair lives, for the notice's instruction.
        var repairLocation: String {
            switch self {
            case .claude: return "Settings → CLI Account"
            case .codex: return "Settings → Codex Account"
            }
        }

        static func summary(_ providers: [RefusedProvider]) -> String {
            providers.map(\.displayName).joined(separator: " + ")
        }
    }

    /// Last time the focus-only notice was sent for a profile. The user can
    /// click the same dead profile repeatedly (that is exactly what happens
    /// while they are repairing it), and one banner per click would be noise.
    private var focusOnlyNoticeSentAt: [UUID: Date] = [:]

    /// At most one focus-only notice per profile per hour.
    private static let focusOnlyNoticeInterval: TimeInterval = 3600

    /// Tells the user what just happened: the popover and Settings now SHOW this
    /// profile, but its dead login was not handed to the CLI, so the CLI is still
    /// signed in as somebody else — and here is where to repair it.
    private func notifyFocusedWithoutApplying(profile: Profile, refused: [RefusedProvider]) {
        let now = Date()
        if let last = focusOnlyNoticeSentAt[profile.id],
           now.timeIntervalSince(last) < Self.focusOnlyNoticeInterval {
            return
        }
        focusOnlyNoticeSentAt[profile.id] = now

        // Name the account the CLI is actually still logged into, per refused
        // provider — "the CLI stays on X" is the part that stops the user
        // believing the switch landed.
        let ownerNames = refused.compactMap { provider -> String? in
            let ownerId: UUID?
            switch provider {
            case .claude: ownerId = activeClaudeProfileId
            case .codex: ownerId = activeCodexProfileId
            }
            return ownerId.flatMap { id in profiles.first(where: { $0.id == id })?.name }
        }

        NotificationManager.shared.sendFocusedWithoutLoginNotification(
            profileName: profile.name,
            providerName: RefusedProvider.summary(refused),
            currentOwnerName: ownerNames.first,
            repairLocation: refused.first?.repairLocation ?? "Settings"
        )
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

    /// Every account the UI marks as ACTIVE: the Claude and Codex profiles that
    /// own their provider's shared CLI login, plus Grok's active account — Grok
    /// has no shared-login pointer, so the FOCUSED Grok profile counts, and a
    /// sole Grok profile is trivially the active one.
    ///
    /// One definition, two consumers: the menu-bar tile's cyan label
    /// (`StatusBarUIManager.paintTiles`) and the popover's "Active" badge /
    /// group navigator. They disagreed before this existed — a Grok tile drew
    /// cyan while the popover called it inactive.
    func activeAccountIds(among profiles: [Profile]) -> Set<UUID> {
        var ids = Set([activeClaudeProfileId, activeCodexProfileId].compactMap { $0 })
        let groks = profiles.filter { $0.providerKind == .grok }
        if let focused = activeProfile, focused.providerKind == .grok {
            ids.insert(focused.id)
        } else if groks.count == 1, let sole = groks.first {
            ids.insert(sole.id)
        }
        return ids
    }

    // MARK: - Duplicate Claude Accounts

    /// Sets of profiles that hold logins for the SAME Anthropic account, keyed
    /// by `Profile.claudeAccountUUID`. Two such profiles are two tiles over ONE
    /// quota: the usage windows are identical by construction, and an
    /// auto-switch between them buys no headroom while costing every running
    /// session its context re-read. Recomputed on every profile mutation and
    /// published so settings rows can caption the duplicates.
    ///
    /// Only ACCOUNT-STAMPED profiles can appear here — an unstamped login is no
    /// evidence of anything (that is exactly the hole the background identity
    /// pass fills). Empty in the healthy case.
    @Published private(set) var duplicateClaudeAccountGroups: [[UUID]] = []

    /// Duplicate groups the user has already been told about this run, keyed by
    /// the group's member ids. In-memory by design: the episode is "this set of
    /// profiles is doubled up right now", and a group that disappears (one side
    /// re-logged into a different account, or was removed) re-arms so a
    /// recurrence is reported again.
    private var notifiedDuplicateClaudeGroups: Set<String> = []

    /// Groups of Claude-credentialed profiles sharing one `claudeAccountUUID`.
    /// Pure and order-stable: groups follow the first member's position in
    /// `profiles`, members follow theirs, so the caption and the log line read
    /// the same on every evaluation.
    nonisolated static func duplicateClaudeAccountGroups(in profiles: [Profile]) -> [[UUID]] {
        var order: [String] = []
        var byAccount: [String: [UUID]] = [:]
        for profile in profiles {
            guard profile.carriesClaudeAccount,
                  let uuid = profile.claudeAccountUUID, !uuid.isEmpty else { continue }
            if byAccount[uuid] == nil { order.append(uuid) }
            byAccount[uuid, default: []].append(profile.id)
        }
        return order.compactMap { uuid in
            let members = byAccount[uuid] ?? []
            return members.count > 1 ? members : nil
        }
    }

    /// Which duplicate groups still owe the user a notification, and the
    /// updated "already told" set. Split out from the side effects so the
    /// once-per-episode rule is testable: the same groups asked twice notify
    /// once, and a group that vanishes is forgotten (a recurrence notifies
    /// again).
    nonisolated static func duplicateClaudeAccountNotices(
        groups: [[UUID]], alreadyNotified: Set<String>
    ) -> (toNotify: [[UUID]], notified: Set<String>) {
        let signatures = groups.map { $0.map(\.uuidString).sorted().joined(separator: "+") }
        let live = Set(signatures)
        let toNotify = zip(groups, signatures)
            .filter { !alreadyNotified.contains($0.1) }
            .map(\.0)
        return (toNotify, live)
    }

    /// The OTHER profiles that hold a login for the same Anthropic account as
    /// `profileId`, in roster order. Empty when the profile is not duplicated.
    func duplicateClaudeAccountPartnerNames(for profileId: UUID) -> [String] {
        guard let group = duplicateClaudeAccountGroups.first(where: { $0.contains(profileId) }) else { return [] }
        return group
            .filter { $0 != profileId }
            .compactMap { id in profiles.first(where: { $0.id == id })?.name }
    }

    /// Recomputes the duplicate groups and reports newly-discovered ones once.
    /// Called from `profiles`' `didSet`, so it runs after every load, save and
    /// in-place usage patch; the published array is only reassigned when the
    /// grouping actually changes, so the common case publishes nothing.
    ///
    /// This NEVER touches credentials. A duplicate is the user's own doing (two
    /// logins into one account) and only they can decide which profile keeps
    /// it — the app's job is to say so, stop double-counting the quota in the
    /// auto-switch, and get out of the way.
    private func refreshDuplicateClaudeAccountGroups() {
        let groups = Self.duplicateClaudeAccountGroups(in: profiles)
        if groups != duplicateClaudeAccountGroups {
            duplicateClaudeAccountGroups = groups
        }

        let (toNotify, live) = Self.duplicateClaudeAccountNotices(
            groups: groups, alreadyNotified: notifiedDuplicateClaudeGroups
        )
        notifiedDuplicateClaudeGroups = live
        guard !toNotify.isEmpty else { return }

        for group in toNotify {
            let names = group.compactMap { id in profiles.first(where: { $0.id == id })?.name }
            guard names.count > 1 else { continue }
            // A refusal count on a member is the forensic half of the notice:
            // it says the write guard has already caught something trying to
            // put one account's login into another account's profile, which is
            // how a duplicate is MADE (stale pointer + unstamped target).
            let refused = group.reduce(0) { $0 + ClaudeCodeSyncService.shared.refusedCredentialWrites[$1, default: 0] }
            let refusals = refused > 0 ? ", \(refused) contaminating write(s) refused" : ""
            LoggingService.shared.log(
                "ProfileManager: \u{26A0}\u{FE0F} duplicate Anthropic account \u{2014} \(names.joined(separator: ", ")) hold logins for the SAME account (one quota, \(names.count) tiles\(refusals))"
            )
            NotificationManager.shared.sendDuplicateClaudeAccountNotification(profileNames: names)
        }
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
        // refresh) store-direct. A stale in-memory array would miss those rotations
        // in the published state. Disk persistence of usage is deferred (see
        // pendingUsageByProfileID / flushPendingUsage) and applied via usage-only
        // patches so a later flush can never overwrite a concurrent credential
        // rotation with a stale non-nil copy.
        var updated = profileStore.loadProfiles()
        // Re-apply unflushed usage for OTHER profiles (and any prior patch for this
        // one) so assigning `profiles = updated` cannot resurrect stale percentages.
        applyPendingOverlay(to: &updated)

        guard let index = updated.firstIndex(where: { $0.id == profileId }) else {
            LoggingService.shared.logError("saveClaudeUsage: Profile not found with ID: \(profileId)")
            return
        }

        // Defense in depth: never persist a sentinel reset stamp. Fetch paths heal
        // before display; this catches any save that skipped them (idempotent).
        var usage = usage
        usage.healMissingResetStamps(previous: updated[index].claudeUsage)

        updated[index].claudeUsage = usage

        // Single publish for the array; only republish activeProfile when it is
        // this profile AND a visible field actually differs (usage or a credential
        // rotation adopted by the load above).
        let shouldUpdateActive = activeProfile?.id == profileId && activeProfile != updated[index]
        profiles = updated
        if shouldUpdateActive {
            activeProfile = updated[index]
        }

        // Defer the disk write: merge into the pending usage-only patch.
        var patch = pendingUsageByProfileID[profileId] ?? ProfileStore.UsagePatch()
        patch.claudeUsage = usage
        pendingUsageByProfileID[profileId] = patch
        LoggingService.shared.log("Saved Claude usage for profile: \(profiles[index].name)", type: .info)
    }

    /// Loads Claude usage data for a specific profile
    func loadClaudeUsage(for profileId: UUID) -> ClaudeUsage? {
        return profiles.first(where: { $0.id == profileId })?.claudeUsage
    }

    /// Saves API usage data for a specific profile
    func saveAPIUsage(_ usage: APIUsage, for profileId: UUID) {
        // Same store re-read as saveClaudeUsage — adopt credential rotations into
        // the published state, overlay unflushed usage, and defer the disk write.
        var updated = profileStore.loadProfiles()
        applyPendingOverlay(to: &updated)

        guard let index = updated.firstIndex(where: { $0.id == profileId }) else {
            LoggingService.shared.logError("saveAPIUsage: Profile not found with ID: \(profileId)")
            return
        }

        updated[index].apiUsage = usage

        // Single publish for the array; only republish activeProfile when it is
        // this profile AND a visible field actually differs.
        let shouldUpdateActive = activeProfile?.id == profileId && activeProfile != updated[index]
        profiles = updated
        if shouldUpdateActive {
            activeProfile = updated[index]
        }

        // Defer the disk write: merge into the pending usage-only patch.
        var patch = pendingUsageByProfileID[profileId] ?? ProfileStore.UsagePatch()
        patch.apiUsage = usage
        pendingUsageByProfileID[profileId] = patch
        LoggingService.shared.log("Saved API usage for profile: \(profiles[index].name)", type: .info)
    }

    /// Sweep-time usage staging: updates land in `pendingUsageByProfileID`
    /// (disk-deferred, like saveClaudeUsage) but WITHOUT publishing `profiles`.
    /// The sweep publishes ONCE via `publishStagedUsage()` before its repaint —
    /// with 14 accounts the per-profile publishes re-evaluated every open
    /// SwiftUI surface (settings, popover) ~15× per sweep for values only the
    /// tiles consume (Codex-validated P0 of the Manage Profiles scroll lag).
    /// Auto-switch safety is unchanged: the active-profile trigger receives
    /// fresh usage by PARAMETER, and stale candidate estimates are re-verified
    /// by the pre-switch usage fetch.
    private var hasStagedUsage = false

    func stageClaudeUsage(_ usage: ClaudeUsage, for profileId: UUID) {
        var usage = usage
        let previous = profiles.first(where: { $0.id == profileId })?.claudeUsage
        usage.healMissingResetStamps(previous: previous)
        var patch = pendingUsageByProfileID[profileId] ?? ProfileStore.UsagePatch()
        patch.claudeUsage = usage
        pendingUsageByProfileID[profileId] = patch
        hasStagedUsage = true
        LoggingService.shared.log("Staged usage for profile id \(profileId.uuidString.prefix(8))", type: .info)
    }

    /// One publish for everything staged this sweep. Idempotent; no-op when
    /// nothing is staged. Reads the CURRENT store (adopting any credential
    /// rotations, same as saveClaudeUsage) and overlays every pending patch.
    func publishStagedUsage() {
        guard hasStagedUsage else { return }
        hasStagedUsage = false
        var updated = profileStore.loadProfiles()
        applyPendingOverlay(to: &updated)
        let shouldUpdateActive = activeProfile.flatMap { active in
            updated.first(where: { $0.id == active.id }).map { $0 != active }
        } ?? false
        profiles = updated
        if shouldUpdateActive, let id = activeProfile?.id {
            activeProfile = updated.first(where: { $0.id == id })
        }
    }

    /// Writes all deferred usage patches to disk in one store operation and clears
    /// the pending map. Safe to call when empty (no-op). Call at defined flush
    /// boundaries: end of multi-profile sweep, end of single-profile refresh,
    /// before profile switch, app termination.
    func flushPendingUsage() {
        guard !pendingUsageByProfileID.isEmpty else { return }
        profileStore.applyUsagePatches(pendingUsageByProfileID)
        pendingUsageByProfileID.removeAll()
    }

    /// Re-applies unflushed usage onto a freshly loaded profile array so a store
    /// reload cannot resurrect pre-patch percentages for profiles with pending
    /// updates. Shared by every `profiles = profileStore.loadProfiles()` site.
    private func applyPendingOverlay(to profiles: inout [Profile]) {
        guard !pendingUsageByProfileID.isEmpty else { return }
        for index in profiles.indices {
            guard let patch = pendingUsageByProfileID[profiles[index].id] else { continue }
            if let claudeUsage = patch.claudeUsage {
                profiles[index].claudeUsage = claudeUsage
            }
            if let apiUsage = patch.apiUsage {
                profiles[index].apiUsage = apiUsage
            }
        }
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

    /// Republishes the store's degraded flag and tells the user ONCE per episode.
    /// The app never restarts cfprefsd itself — that is an operator action.
    private func registerPreferencesDegradedObserverIfNeeded() {
        guard preferencesDegradedObserver == nil else { return }
        preferencesDegradedObserver = NotificationCenter.default.addObserver(
            forName: .preferencesDegradedStateChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ProfileManager.shared.syncPreferencesDegradedState()
            }
        }
        syncPreferencesDegradedState()
    }

    private func syncPreferencesDegradedState() {
        let degraded = profileStore.preferencesDegraded
        guard degraded != preferencesDegraded else { return }
        preferencesDegraded = degraded
        if degraded {
            NotificationManager.shared.sendPreferencesDegradedNotification()
        } else {
            LoggingService.shared.log("ProfileManager: preferences service recovered")
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
        var reloaded = profileStore.loadProfiles()
        applyPendingOverlay(to: &reloaded)
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
        autoImportGrokAccountIfNeeded()
        backfillGrokDisplayDefaultsIfNeeded()

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
        // Nil credentials prove ABSENCE only when hydration completed (.ready).
        // After a partial (.failed) warm they usually mean "not read yet", and
        // clearing (or re-inferring) a provider-active pointer on that evidence
        // hands the next user switch a skipped outgoing-adoption — auth.json /
        // the shared login overwritten while the outgoing account's rotated
        // token is lost. Ownership of merely-UNKNOWN credentials is preserved;
        // the post-heal reload runs this again with real evidence.
        let absenceIsEvidence = credentialHydrationState == .ready

        if absenceIsEvidence,
           let id = activeClaudeProfileId,
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
           let owner = profiles.first(where: { codexService.accountId(of: $0) == fileAccount }) {
            activeCodexProfileId = owner.id
        } else {
            if absenceIsEvidence,
               let id = activeCodexProfileId,
               profiles.first(where: { $0.id == id })?.codexCredentialsJSON == nil {
                activeCodexProfileId = nil
            }
            // The exactly-one inference also leans on absence: with a partial
            // cache, "one codex profile" may just be "one HYDRATED so far".
            if absenceIsEvidence, activeCodexProfileId == nil {
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
        applyPendingOverlay(to: &reloaded)
        // Ownership is ambiguous the moment two profiles are stamped with the
        // SAME account (a real roster state — see `duplicateClaudeAccountGroups`),
        // and picking by array order there would hand the pointer to whichever
        // profile happens to be stored first and then treat the true holder as
        // contaminated. Resolve by evidence instead: the profile whose stored
        // token IS the shared login wins, then the standing pointer, and only
        // then the account stamp.
        let stampMatches = reloaded.filter { $0.claudeAccountUUID == identity.accountUUID }
        let owner = stampMatches.first(where: {
                $0.cliCredentialsJSON.flatMap(sync.extractAccessToken(from:)) == systemToken
            })
            ?? stampMatches.first(where: { $0.id == activeClaudeProfileId })
            ?? stampMatches.first
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
            // A same-account profile holding a DIFFERENT login that is still
            // usable is not contamination — it is a second, independent login
            // into one account, which only the user can resolve. Clearing it
            // would delete a working credential behind their back. Report it
            // (duplicateClaudeAccountGroups + one notification) and leave it
            // alone; the auto-switch already refuses to rotate between the two.
            // The stale copies this guard was built for are still cleared: a
            // byte-identical copy of the live token, or a same-account token
            // that is expired with no refresh token left.
            if !sameToken, profile.hasUsableCLIOAuth {
                LoggingService.shared.log("ProfileManager: '\(profile.name)' holds a SECOND live login for '\(owner.name)'s account (one quota, two profiles) — kept, not cleared")
                continue
            }
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
            applyPendingOverlay(to: &profiles)
            if let activeId = activeProfile?.id,
               let updatedActive = profiles.first(where: { $0.id == activeId }) {
                activeProfile = updatedActive
            }
        }
        return owner.name
    }

    /// The profile that owns ~/.codex/auth.json right now, by the file's own
    /// `account_id` — the only deterministic answer, since that file IS the
    /// codex CLI's current login. Falls back to the persisted pointer, then to
    /// the focused profile when it carries a Codex account (the Claude side has
    /// had that last fallback all along; its absence here meant a nil pointer
    /// silently skipped the outgoing adoption).
    private func resolveOutgoingCodexOwner() -> UUID? {
        if let ownerId = codexOwnerFromAuthFile()?.id { return ownerId }
        if let pointer = activeCodexProfileId { return pointer }
        if let focused = activeProfile, focused.codexCredentialsJSON != nil { return focused.id }
        return nil
    }

    /// The profile whose Codex account matches ~/.codex/auth.json (credentials
    /// first, persisted `codexAccountId` second so an unhydrated profile still
    /// matches). No network — a file read and a JSON parse.
    private func codexOwnerFromAuthFile() -> Profile? {
        let service = CodexUsageService.shared
        guard let fileJSON = service.readAuthFile(),
              let fileAccount = service.extractAccountId(from: fileJSON) else { return nil }
        return CodexUsageService.profileMatchingAccount(
            fileAccount,
            in: profiles,
            accountIdOf: { service.accountId(of: $0) }
        )
    }

    /// True while a Codex owner re-derivation pass is running (sweep end and
    /// launch can both trigger one; overlapping passes would race their saves).
    private var codexAdoptionInFlight = false

    /// The Codex twin of `adoptSystemLoginByIdentity`, run at the END OF EVERY
    /// SWEEP: re-derives who owns the shared codex login from auth.json's
    /// `account_id` and adopts the file into that profile when it is fresher.
    ///
    /// Without it the owner was re-derived only at launch, so a CLI-side
    /// `codex login` — the documented recovery for a dead login — flipped the
    /// real login while the app kept watching the old owner: the revived
    /// account stayed flagged dead, and the preflight refused to validate the
    /// true owner "because it already owns the login" (audit H4). Adoption
    /// clears the dead flag, so `codex login` alone now revives a profile.
    @discardableResult
    func adoptCodexLoginByAccountId() async -> String? {
        // Never touch shared-login bookkeeping mid-switch (contamination window).
        guard !isSwitchingProfile, !codexAdoptionInFlight else { return nil }
        codexAdoptionInFlight = true
        defer { codexAdoptionInFlight = false }

        guard let owner = codexOwnerFromAuthFile() else { return nil }

        if activeCodexProfileId != owner.id {
            LoggingService.shared.log("ProfileManager: ⚠️ active Codex pointer repaired — auth.json's account belongs to '\(owner.name)', not '\(profiles.first(where: { $0.id == activeCodexProfileId })?.name ?? "none")'")
            activeCodexProfileId = owner.id
            profileStore.saveActiveCodexProfileId(owner.id)
        }

        // Adoption is account-matched and freshness-checked inside the service;
        // a re-login for the same account writes a whole new token family, which
        // is exactly what this picks up. It runs off the main actor because the
        // profile save behind it touches the credential store.
        let adopted: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CodexUsageService.shared.adoptAuthFileIfSameAccount(for: owner.id))
            }
        }
        if adopted {
            profiles = profileStore.loadProfiles()
            applyPendingOverlay(to: &profiles)
            if let activeId = activeProfile?.id,
               let updatedActive = profiles.first(where: { $0.id == activeId }) {
                activeProfile = updatedActive
            }
            LoggingService.shared.log("ProfileManager: ✓ adopted the codex CLI's fresh login into '\(owner.name)' (account-matched)")
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
        // carries (metadata), not has (credential): after a PARTIAL hydration
        // an existing codex profile's credential field can be nil, and the
        // credential-based check would import a DUPLICATE profile.
        guard !profiles.contains(where: { $0.carriesCodexAccount }) else {
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
            codexAccountId: codexService.extractAccountId(from: authJSON),
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

    /// One-time: import the xAI Grok CLI login (~/.grok/auth.json) into its own
    /// profile — the Codex twin, for the third provider. Named "GROK" per the
    /// operator's convention for this account.
    private func autoImportGrokAccountIfNeeded() {
        let flagKey = "grokAutoImported_v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        // carries, not has — see the Codex twin above.
        guard !profiles.contains(where: { $0.carriesGrokAccount }) else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }

        let grokService = GrokUsageService.shared
        guard let authJSON = grokService.readAuthFile(),
              grokService.extractAccessToken(from: authJSON) != nil else {
            // Not logged into grok — retry next launch (don't set the flag).
            return
        }

        let email = grokService.extractEmail(from: authJSON)
        let newProfile = Profile(
            name: "Grok",
            grokCredentialsJSON: authJSON,
            grokEmail: email,
            grokAccountSyncedAt: Date(),
            iconConfig: .default,
            refreshInterval: 60.0,
            checkOverageLimitEnabled: false,
            notificationSettings: NotificationSettings(),
            isSelectedForDisplay: true,
            // "Grok".prefix(3) == "Gro"; the operator wants "Grk" on the tile.
            menuBarLabel: "Grk"
        )

        profiles.append(newProfile)
        profileStore.saveProfiles(profiles)
        UserDefaults.standard.set(true, forKey: flagKey)
        LoggingService.shared.log("ProfileManager: ✅ Auto-imported Grok account '\(email ?? "unknown")' as profile 'Grok'")
    }

    /// One-time: a Grok profile imported by an earlier build was named "GROK"
    /// with no menu-bar label ("GROK".prefix(3) == "GRO"). Normalize it to the
    /// display defaults the current import uses — name "Grok", tile label "Grk"
    /// — without disturbing a name/label the user has since customized.
    private func backfillGrokDisplayDefaultsIfNeeded() {
        let flagKey = "grokDisplayBackfill_v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        var changed = false
        for i in profiles.indices where profiles[i].hasGrokAccount {
            if profiles[i].name == "GROK" { profiles[i].name = "Grok"; changed = true }
            if profiles[i].menuBarLabel == nil { profiles[i].menuBarLabel = "Grk"; changed = true }
        }
        if changed {
            profileStore.saveProfiles(profiles)
            LoggingService.shared.log("ProfileManager: backfilled Grok display defaults (name 'Grok', tile 'Grk')")
        }
        // Only latch the flag once a grok profile actually exists to normalize,
        // so a backfill that ran before the import doesn't skip the real one.
        if profiles.contains(where: { $0.hasGrokAccount }) {
            UserDefaults.standard.set(true, forKey: flagKey)
        }
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
            applyPendingOverlay(to: &profiles)
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
