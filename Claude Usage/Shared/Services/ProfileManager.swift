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
    /// The Grok half of the same idea: who owns ~/.grok/auth.json. Nil means the
    /// app has never handed that file to a profile, which is how every install
    /// predating this pointer starts — `providerOwnerId(for:)` then falls back
    /// to a sole credentialed Grok profile, and to nothing at all when several
    /// carry a Grok login.
    @Published private(set) var activeGrokProfileId: UUID?

    /// Whether a window the user is actively working IN would be disrupted by
    /// moving the view: the Settings window is key, or a sheet is up. An
    /// AUTOMATIC switch honours it and stays put even when the view WAS the
    /// outgoing owner — the user is mid-repair on a login screen, and the sweep
    /// pulling the inspector onto another account under their hands is the exact
    /// interruption the focus-preserving rule exists to prevent. A user's own
    /// "Make active" is unaffected: they asked for the move from that window.
    ///
    /// Installed by `MenuBarManager.setup()`, which owns the Settings window.
    /// The default answers false, so tests and headless callers see the plain
    /// outgoing-owner rule.
    var viewIsPinnedByOpenUI: () -> Bool = { false }

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

        setProviderOwner(.claude, to: profileStore.loadActiveClaudeProfileId(), cause: .launchRepair)
        setProviderOwner(.codex, to: profileStore.loadActiveCodexProfileId(), cause: .launchRepair)
        setProviderOwner(.grok, to: profileStore.loadActiveGrokProfileId(), cause: .launchRepair)
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
            setProviderOwner(.claude, to: nil, cause: .delete)
            profileStore.saveActiveClaudeProfileId(nil)
        }
        if activeCodexProfileId == id {
            setProviderOwner(.codex, to: nil, cause: .delete)
            profileStore.saveActiveCodexProfileId(nil)
        }
        // The Grok pointer needs the same release. It was missed when Grok got a
        // pointer of its own, and a dangling one is no longer merely untidy:
        // `providerOwnerId(for:)` reads these pointers as THE owner, so a
        // deleted profile's id would go on naming the Grok owner and suppress
        // the sole-credentialed answer that is now correct.
        if activeGrokProfileId == id {
            setProviderOwner(.grok, to: nil, cause: .delete)
            profileStore.saveActiveGrokProfileId(nil)
        }

        // Delete Keychain credentials before removing from the array
        profileStore.deleteProfileCredentials(profileId: id)

        profiles.removeAll { $0.id == id }
        ProfileCredentialStatusCache.invalidateAll()

        // The VIEWED profile is gone, so the UI needs somewhere to look — and
        // that is the whole of it. A delete must never rewrite a CLI login:
        // `activateProfile` would apply the surviving profile's credentials to
        // the shared Keychain item / auth.json, so removing an account the user
        // never even switched to would silently sign the CLI into a different
        // one. The pointers the deleted profile held were released above (and
        // are re-derived from live evidence on the next resolve), so a focus
        // move is all that is left to do.
        if activeProfile?.id == id, let first = profiles.first {
            viewProfile(first.id)
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

    // MARK: - Focus vs Ownership

    /// Who currently owns each provider's shared CLI login, as one value, so the
    /// decision below is a pure function of state a test can construct.
    struct ProviderOwnership: Equatable {
        var claude: UUID?
        var codex: UUID?
        /// Grok's owner of `~/.grok/auth.json`. Nil is NOT "no pointer exists"
        /// any more — it is "the app has never applied a Grok login on this
        /// install", which is the state every pre-pointer install starts in and
        /// the reason the Grok arm of `needsProviderApply` keys off the
        /// pointer's EXISTENCE rather than off whose it is: with nothing ever
        /// applied, no profile can be somebody else's non-owner.
        var grok: UUID?

        init(claude: UUID? = nil, codex: UUID? = nil, grok: UUID? = nil) {
            self.claude = claude
            self.codex = codex
            self.grok = grok
        }
    }

    /// The pointers as they stand right now.
    var currentProviderOwnership: ProviderOwnership {
        ProviderOwnership(
            claude: activeClaudeProfileId,
            codex: activeCodexProfileId,
            grok: activeGrokProfileId
        )
    }

    /// The provider logins `profile` CARRIES but does NOT own — i.e. the work an
    /// activation still has to do for a profile that is already focused.
    ///
    /// A nil pointer for a shared-login provider means nobody owns that login,
    /// so applying it is exactly right: the apply claims the pointer. A nil
    /// pointer for Grok means something else entirely — that provider has no
    /// shared login at all — which is why Grok is decided by the pointer's
    /// existence rather than by whose it is.
    static func needsProviderApply(profile: Profile, pointers: ProviderOwnership) -> [Profile.ProviderKind] {
        Profile.ProviderKind.allCases.filter { provider in
            switch provider {
            case .claude:
                return profile.cliCredentialsJSON != nil && pointers.claude != profile.id
            case .codex:
                return profile.codexCredentialsJSON != nil && pointers.codex != profile.id
            case .grok:
                return profile.grokCredentialsJSON != nil
                    && pointers.grok != nil
                    && pointers.grok != profile.id
            }
        }
    }

    /// Whether a LANDED switch should take the FOCUS — the account the popover,
    /// the inspector and Settings are showing — along with it.
    ///
    /// - A **user-initiated** switch always moves it: you chose to make that
    ///   account active in order to look at it.
    /// - An **ownership repair** on the profile already on screen trivially
    ///   moves it (there is nowhere else for it to go).
    /// - An **AUTOMATIC** switch moves it only out of the OUTGOING OWNER. If
    ///   the user was watching the active account they should go on watching
    ///   the active account; if they were looking anywhere else they went there
    ///   deliberately — an inspector open half-way through a re-login is the
    ///   sharp case — and a sweep-driven rotation must not yank the screen off
    ///   a repair nobody asked to abandon.
    ///
    /// - `viewIsPinned` vetoes the automatic move even out of the outgoing
    ///   owner: a Settings window is key or a sheet is up, so the user is
    ///   working IN the view (`viewIsPinnedByOpenUI`). It never vetoes a
    ///   user-initiated switch — they asked for it from that very window.
    ///
    /// This deliberately narrows `docs/specs/ux-revamp.md` D5 / §6, which had
    /// the view follow every switch: D5's reasoning ("you switched to look at
    /// it") is a statement about a switch the user ASKED for, and once viewing
    /// is free to land on any account it stops holding for the automatic one.
    nonisolated static func focusFollowsSwitch(
        userInitiated: Bool,
        focusIsTarget: Bool,
        focusWasOutgoingOwner: Bool,
        hasFocus: Bool,
        viewIsPinned: Bool = false
    ) -> Bool {
        guard hasFocus else { return true }
        if userInitiated || focusIsTarget { return true }
        return focusWasOutgoingOwner && !viewIsPinned
    }

    /// How a provider set is named in the ownership-repair log line.
    private static func providerNames(_ providers: [Profile.ProviderKind]) -> String {
        providers.map { provider in
            switch provider {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .grok: return "Grok"
            }
        }.joined(separator: " + ")
    }

    /// Name of the profile that currently owns `provider`'s shared CLI login.
    private func currentOwnerName(of provider: Profile.ProviderKind) -> String? {
        let ownerId: UUID?
        switch provider {
        case .claude: ownerId = activeClaudeProfileId
        case .codex: ownerId = activeCodexProfileId
        case .grok: ownerId = activeGrokProfileId
        }
        return ownerId.flatMap { owner in profiles.first(where: { $0.id == owner })?.name }
    }

    // MARK: - Focus Without Activation

    /// Moves the FOCUS to `id` and nothing else.
    ///
    /// `activeProfile` is only the focused profile — which account each CLI is
    /// signed into is the separate question the three provider pointers answer —
    /// so a caller that wants to LOOK at a profile does not need, and must not
    /// pay for, an activation. This sets `activeProfile`, persists
    /// `activeProfileId`, and publishes; it never touches credentials, never
    /// moves a provider pointer, never records a `SwitchEvent`, never bumps
    /// `lastUsedAt`, and never posts `.profileManuallyActivated` (that mark tells
    /// the auto-switch to stop rotating away from a deliberately chosen account —
    /// viewing is not choosing).
    ///
    /// The publish IS the notification: `activeProfile` is `@Published` and
    /// `MenuBarManager.observeProfileChanges` subscribes to `$activeProfile`, so
    /// the menu bar, popover and Settings follow exactly as they do when the
    /// focus-only branch of `activateProfileDetailed` moves it.
    ///
    /// Returns false — changing nothing — when no profile carries that id.
    @discardableResult
    func viewProfile(_ id: UUID) -> Bool {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("ProfileManager: cannot view unknown profile \(id)")
            return false
        }
        activeProfile = profile
        profileStore.saveActiveProfileId(id)
        LoggingService.shared.log("👁 Viewing profile '\(profile.name)' (focus only — no login was applied)")
        return true
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

        // BEING FOCUSED IS NOT BEING ACTIVE. `activeProfile` is only the focus;
        // `activeClaudeProfileId` / `activeCodexProfileId` say who owns each
        // shared CLI login, and the two differ routinely — most sharply right
        // after an in-app repair. A user clicks a profile whose login is dead,
        // the gate moves the FOCUS without applying it (`focusedWithoutApplying`),
        // they sign that profile back in from Settings (which operates on the
        // focused profile), and then click it again to hand the new login to
        // the CLI. That click used to hit this early return: "already active",
        // nothing applied, the CLI still signed in as somebody else, and no way
        // to finish the switch by clicking (reported live 2026-09-03).
        //
        // So a focused profile short-circuits only when it also OWNS every
        // provider login it carries. Otherwise the normal apply path runs for
        // the providers it does not own — same liveness gate, same outgoing
        // adoption, same pointer moves, same refusal.
        let isFocused = activeProfile?.id == id
        let unownedProviders = Self.needsProviderApply(profile: profile, pointers: currentProviderOwnership)
        if isFocused && unownedProviders.isEmpty {
            LoggingService.shared.log("Profile already active: \(profile.name)")
            return .alreadyActive
        }

        switchingSemaphore = true
        isSwitchingProfile = true

        // Which provider logins this activation may hand to a CLI. A normal
        // switch applies every provider the target carries (the `!= nil` checks
        // below decide that); an ownership repair applies ONLY the unowned ones
        // — re-applying a login the profile already owns would refresh and
        // rotate the token family out from under the CLI that is live on it,
        // for no gain (the same reasoning that keeps `preflightCandidates` off
        // a candidate that owns its provider's shared login).
        let applyScope: Set<Profile.ProviderKind> = isFocused
            ? Set(unownedProviders)
            : Set(Profile.ProviderKind.allCases)

        // Captured before any state changes — the history record needs the
        // OUTGOING account, and activeProfile is rewritten mid-switch. On an
        // ownership repair the focus is not moving, so the account being left
        // is the one that owns the login, not the focused profile (which is the
        // target itself — a from == to record would read as a no-op).
        let outgoingNameForHistory = isFocused
            ? (unownedProviders.compactMap { currentOwnerName(of: $0) }.first ?? activeProfile?.name)
            : activeProfile?.name

        // Whether the VIEW should follow this switch, decided before any pointer
        // moves. A user-initiated "Make active" always moves the focus — you
        // switched in order to look at the account you switched to. An AUTOMATIC
        // switch moves it only when the focus was the OUTGOING OWNER: the user
        // was watching the active account, so they should go on watching the
        // active account. Any other view is somewhere the user deliberately
        // went — an inspector open on a half-finished re-login is the sharp case
        // — and a sweep-driven rotation that dragged the screen off it would
        // interrupt a repair nobody asked to abandon.
        let focusWasOutgoingOwner: Bool = activeProfile.map { focused in
            applyScope.contains { provider in
                Self.carriesLogin(profile, for: provider) && providerOwnerId(for: provider) == focused.id
            }
        } ?? false

        if isFocused {
            LoggingService.shared.log(
                "Profile '\(profile.name)' is focused but does not own its "
                + "\(Self.providerNames(unownedProviders)) login — applying now"
            )
        } else {
            LoggingService.shared.log("Switching to profile: \(profile.name)")
        }

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
        // The outgoing account is the one that OWNS the shared login — resolved
        // from the pointer, or from a sole credentialed profile. It used to fall
        // back to the focused profile, which would re-sync the CLI's live login
        // into whatever account the user happened to be looking at.
        if target?.cliCredentialsJSON != nil,
           let outgoingId = providerOwnerId(for: .claude),
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

        // 3. Grok side: exactly the Codex shape. ~/.grok/auth.json is about to be
        //    replaced, and the `grok` CLI refreshes its token IN that file, so
        //    the outgoing account's rotated refresh token must be adopted back
        //    into its profile before the overwrite — otherwise switching away and
        //    back hands the CLI a consumed refresh token.
        if target?.grokCredentialsJSON != nil,
           let outgoingId = resolveOutgoingGrokOwner(), outgoingId != id {
            await runOffMainActor {
                GrokUsageService.shared.adoptAuthFileIfSameAccount(for: outgoingId)
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

        if updatedProfile.cliCredentialsJSON != nil, applyScope.contains(.claude) {
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

        if applyScope.contains(.claude), let cliJSON = updatedProfile.cliCredentialsJSON {
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
                setProviderOwner(.claude, to: id, cause: .activate)
                profileStore.saveActiveClaudeProfileId(id)

                // Learn/refresh the applied login's account identity in the
                // background so future adoptions stay account-matched.
                Task { await ClaudeCodeSyncService.shared.stampAccountIdentity(for: id) }
            }
        } else if updatedProfile.cliCredentialsJSON == nil {
            LoggingService.shared.log("⚠️ Profile '\(updatedProfile.name)' has no CLI credentials JSON")
        }

        // Apply the profile's Codex account (if any) to ~/.codex/auth.json so the
        // `codex` CLI switches accounts along with the app.
        if updatedProfile.codexCredentialsJSON != nil, applyScope.contains(.codex) {
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
                setProviderOwner(.codex, to: id, cause: .activate)
                profileStore.saveActiveCodexProfileId(id)
            }
        }

        // Apply the profile's Grok account (if any) to ~/.grok/auth.json so the
        // `grok` CLI switches accounts along with the app — the same three beats
        // as the two providers above: refresh, gate, apply-and-claim.
        if updatedProfile.grokCredentialsJSON != nil, applyScope.contains(.grok) {
            if await GrokUsageService.shared.ensureFreshCredentials(
                for: id, freshFor: Self.grokApplyFreshnessWindow
            ) {
                profiles = profileStore.loadProfiles()
                applyPendingOverlay(to: &profiles)
                if let refreshed = profiles.first(where: { $0.id == id }) {
                    updatedProfile = refreshed
                }
                LoggingService.shared.log("✓ Refreshed stale Grok token for '\(updatedProfile.name)' before applying")
            }
        }

        if applyScope.contains(.grok), let grokJSON = updatedProfile.grokCredentialsJSON {
            // GATE: the Claude rule, not the Codex one. A Grok access token lives
            // ~6h and carries a real `expires_at`, so expiry IS evidence here (the
            // Codex side needs a liveness probe precisely because its ~10-day token
            // is not). Still expired after the refresh above means the refresh
            // token is revoked or consumed; writing it would replace a working
            // login in auth.json with one no `grok` session can use.
            let grokService = GrokUsageService.shared
            if grokService.isTokenExpired(grokJSON) || grokService.isLoginMarkedDead(id) {
                refusedProviders.append(.grok)
                grokService.notifyReloginNeeded(for: id, force: false)
                LoggingService.shared.log("⛔️ '\(updatedProfile.name)' Grok login is dead (expired, unrefreshable) — NOT applied, outgoing login kept")
            } else {
                let targetProfileId = updatedProfile.id
                let targetProfileName = updatedProfile.name
                await runOffMainActor {
                    do {
                        try GrokUsageService.shared.applyProfileCredentials(targetProfileId)
                        LoggingService.shared.log("✓ Applied Grok credentials for: \(targetProfileName)")
                    } catch {
                        LoggingService.shared.logError("Failed to apply Grok credentials (non-fatal)", error: error)
                    }
                }
                // Same rule as the other two: the pointer follows the apply with
                // no awaits in between.
                setProviderOwner(.grok, to: id, cause: .activate)
                profileStore.saveActiveGrokProfileId(id)
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

        if Self.focusFollowsSwitch(
            userInitiated: userInitiated,
            focusIsTarget: isFocused,
            focusWasOutgoingOwner: focusWasOutgoingOwner,
            hasFocus: activeProfile != nil,
            viewIsPinned: viewIsPinnedByOpenUI()
        ) {
            activeProfile = updated
            profileStore.saveActiveProfileId(id)
        } else {
            // The view stays put — but its published copy predates this
            // switch's reloads, so re-read it or the UI shows stale usage.
            refreshFocusedProfileCopy()
            LoggingService.shared.log("👁 Automatic switch to '\(updated.name)' left the view on '\(activeProfile?.name ?? "none")' — the focus was not the outgoing owner")
        }
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
            // On an ownership repair the focus was already here, so saying it
            // "moved" would misreport the one fact the line exists to report.
            if isFocused {
                LoggingService.shared.log("⛔️ '\(updatedProfile.name)' is focused but its dead \(RefusedProvider.summary(refusedProviders)) login was NOT applied — the CLI keeps its current account")
            } else {
                LoggingService.shared.log("👁 Focus moved to '\(updatedProfile.name)' WITHOUT applying its dead \(RefusedProvider.summary(refusedProviders)) login — the CLI keeps its current account")
            }
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
        case grok

        /// How the provider is named to the user.
        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .grok: return "Grok"
            }
        }

        /// Where the in-app repair lives, for the notice's instruction. Grok has
        /// no in-app login screen — the repair is a CLI login followed by a Sync,
        /// which is what its re-login notification already tells the user.
        var repairLocation: String {
            switch self {
            case .claude: return "Settings → CLI Account"
            case .codex: return "Settings → Codex Account"
            case .grok: return "a `grok login` in Terminal, then Sync"
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
            case .grok: ownerId = activeGrokProfileId
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

    /// Why a provider's owner pointer moved. Travels with every
    /// `.providerOwnerClaimed` post as `userInfo["cause"]`, so an observer can
    /// tell a switch the user asked for from the app repairing its own
    /// bookkeeping behind them.
    enum OwnerClaimCause: String {
        /// An activation applied this provider's credentials to the CLI and
        /// claimed the login it had just written.
        case activate
        /// A Sync pulled the CLI's own login INTO a profile, so that profile
        /// matches the shared login by construction. The default for the three
        /// `claimActive…Ownership` entry points — every caller today is a Sync.
        case sync
        /// An import claimed the pointer. Reserved: no import path claims one
        /// today, because neither the Codex home import nor the isolated-home
        /// login writes the default `auth.json` (see `CodexAccountView`). It is
        /// spelled here so an import that DOES claim never has to invent a
        /// string the consumers do not know.
        case `import`
        /// The app re-derived or restored the pointer itself, with no user act
        /// and no CLI-side login behind it: the store hydration inside
        /// `loadProfiles()`, and `resolveProviderActiveAccounts` matching a live
        /// auth.json or inferring a sole credentialed profile.
        case launchRepair
        /// An adoption pass moved the pointer because a login OUTSIDE the app
        /// changed who owns a shared login (`adoptSystemLoginByIdentity`,
        /// `adoptCodexLoginByAccountId`). These also post
        /// `.providerOwnerChangedExternally`, which is the UI's older, narrower
        /// signal for the same episode.
        case identityAdoption
        /// The owning profile was deleted, so the pointer was released.
        case delete
        /// The recorded owner no longer holds that provider's credentials, so a
        /// dangling pointer was cleared.
        case clear
        /// The call site cannot say.
        case unknown
    }

    /// THE single place any of the three provider pointers is assigned.
    ///
    /// Activation, Sync, delete, the launch resolve and both identity adoptions
    /// all route through here, so `.providerOwnerClaimed` cannot be bypassed by
    /// a new call site that assigns a pointer directly — which is also why the
    /// three properties stay `private(set)`.
    ///
    /// The assignment is UNCONDITIONAL: a `@Published` republish on an unchanged
    /// value is exactly what every caller did before this seam existed, and
    /// `ActiveSelectorMenu` merges those publishers. Only the notification is
    /// gated on the value actually changing, including a change to nil.
    ///
    /// Persisting deliberately stays with the callers. Several of them save a
    /// value they computed rather than the pointer, and
    /// `resolveProviderActiveAccounts` saves once at the end of a provider's arm
    /// after several branches may have run.
    ///
    /// `knownAccountStamp` is for a caller that has just RESOLVED the account
    /// and whose roster copy may still disagree with it. `adoptSystemLoginByIdentity`
    /// is the one such caller: when it falls back to the organization match, the
    /// profile it picks failed the stamp match by definition, so its stored
    /// `claudeAccountUUID` is nil or another account's — and shipping that in a
    /// telemetry payload would misattribute the login this pass just verified.
    private func setProviderOwner(
        _ provider: Profile.ProviderKind, to newId: UUID?, cause: OwnerClaimCause,
        knownAccountStamp: String? = nil
    ) {
        let previous = providerPointer(for: provider)
        switch provider {
        case .claude: activeClaudeProfileId = newId
        case .codex: activeCodexProfileId = newId
        case .grok: activeGrokProfileId = newId
        }
        guard previous != newId else { return }

        var userInfo: [String: Any] = [
            "provider": String(describing: provider),
            "cause": cause.rawValue
        ]
        if let previous {
            userInfo["previousOwnerId"] = previous.uuidString
        }
        if let stamp = knownAccountStamp ?? accountStamp(for: provider, ownerId: newId) {
            userInfo["accountStamp"] = stamp
        }

        NotificationCenter.default.post(
            name: .providerOwnerClaimed, object: newId, userInfo: userInfo
        )
    }

    /// The new owner's non-secret account identity for `.providerOwnerClaimed`,
    /// or nil when it is not known — an unstamped Claude profile, a Codex login
    /// synced before that stamp existed, or a Grok login still behind an
    /// unhydrated Keychain cache. These are the same ids the duplicate-account
    /// detectors key off; no token or refresh token is ever read here.
    private func accountStamp(for provider: Profile.ProviderKind, ownerId: UUID?) -> String? {
        guard let ownerId, let profile = profiles.first(where: { $0.id == ownerId }) else { return nil }
        switch provider {
        case .claude: return profile.claudeAccountUUID
        case .codex: return profile.codexAccountId
        case .grok: return profile.grokCredentialsJSON.flatMap(GrokUsageService.shared.extractUserId(from:))
        }
    }

    /// Records `profileId` as the owner of the Claude Code CLI's shared Keychain
    /// login. Call right after syncing the system credentials INTO that profile —
    /// it then matches the shared login by construction, so the pointer must follow
    /// (a Sync used to leave the pointer on the previously active account, and the
    /// launch-time repair never re-checked a non-nil pointer).
    func claimActiveClaudeOwnership(_ profileId: UUID, cause: OwnerClaimCause = .sync) {
        setProviderOwner(.claude, to: profileId, cause: cause)
        profileStore.saveActiveClaudeProfileId(profileId)
        LoggingService.shared.log("ProfileManager: '\(profiles.first(where: { $0.id == profileId })?.name ?? "?")' claimed the active Claude login")
    }

    /// Records `profileId` as the owner of ~/.codex/auth.json. Call right after
    /// syncing auth.json INTO that profile (see claimActiveClaudeOwnership).
    func claimActiveCodexOwnership(_ profileId: UUID, cause: OwnerClaimCause = .sync) {
        setProviderOwner(.codex, to: profileId, cause: cause)
        profileStore.saveActiveCodexProfileId(profileId)
        LoggingService.shared.log("ProfileManager: '\(profiles.first(where: { $0.id == profileId })?.name ?? "?")' claimed the active Codex login")
    }

    /// Records `profileId` as the owner of ~/.grok/auth.json. Call right after
    /// syncing that file INTO the profile, or right after applying the profile
    /// TO it (see the two above — same contract, same reason).
    func claimActiveGrokOwnership(_ profileId: UUID, cause: OwnerClaimCause = .sync) {
        setProviderOwner(.grok, to: profileId, cause: cause)
        profileStore.saveActiveGrokProfileId(profileId)
        LoggingService.shared.log("ProfileManager: '\(profiles.first(where: { $0.id == profileId })?.name ?? "?")' claimed the active Grok login")
    }

    /// How much remaining validity an activation demands of a Grok token before
    /// handing it to the CLI. Deliberately NOT the Codex side's 24 hours: a Grok
    /// access token lives about six hours, so a 24-hour bar would force a
    /// redemption — and rotate the refresh-token family — on every single
    /// activation. Fifteen minutes is long enough that the CLI never inherits a
    /// token about to die mid-command, and short enough to leave a healthy token
    /// alone.
    private static let grokApplyFreshnessWindow: TimeInterval = 15 * 60

    /// Who owns ~/.grok/auth.json right now, for the pre-switch adoption. Same
    /// precedence as the Codex twin: the FILE's own account first (it is the
    /// CLI's current login, so it outranks any bookkeeping), then the standing
    /// owner — pointer, else a sole credentialed profile. Never the focus: the
    /// adoption WRITES the CLI's live token into the profile it names, so a
    /// merely-viewed account would absorb somebody else's login.
    private func resolveOutgoingGrokOwner() -> UUID? {
        let service = GrokUsageService.shared
        if let fileJSON = service.readAuthFile(),
           let owner = profiles.first(where: { service.profileMatchesAuthFile($0, authFileJSON: fileJSON) }) {
            return owner.id
        }
        return providerOwnerId(for: .grok)
    }

    /// Re-reads the FOCUSED profile from `profiles` after a background pass
    /// rewrote them, so the popover and Settings do not show a stale copy.
    ///
    /// It never changes WHICH profile is focused, and that is the point: the
    /// CLI-side adoption passes (`adoptSystemLoginByIdentity`,
    /// `adoptCodexLoginByAccountId`) move a provider POINTER when a `/login`
    /// outside the app changes who owns a shared login. That is not a decision
    /// the user made about what to look at, so the view must not follow it.
    func refreshFocusedProfileCopy() {
        guard let focusedId = activeProfile?.id,
              let refreshed = profiles.first(where: { $0.id == focusedId }) else { return }
        activeProfile = refreshed
    }

    /// Announces that a provider's owner changed WITHOUT the app switching:
    /// a `/login` in the terminal, or a `codex login` in an isolated home, that
    /// an adoption pass then routed to the matching profile. The view does not
    /// follow such a change (see `refreshFocusedProfileCopy`), so the UI needs
    /// to be able to SAY it happened — "Active for Claude changed outside the
    /// app: now dLeo" — rather than leave the user to notice a moved badge.
    ///
    /// Posted only from the two adoption passes, and only inside their
    /// pointer-actually-moved branches, so it fires once per episode rather than
    /// once per sweep.
    private func announceExternalOwnerChange(provider: Profile.ProviderKind, newOwner: Profile) {
        NotificationCenter.default.post(
            name: .providerOwnerChangedExternally,
            object: newOwner.id,
            userInfo: [
                "provider": String(describing: provider),
                "ownerName": newOwner.name
            ]
        )
    }

    // MARK: - Provider Owner Resolution — FOCUS IS NEVER AUTHORITY

    /// The persisted pointer for `provider`, with no inference of any kind.
    private func providerPointer(for provider: Profile.ProviderKind) -> UUID? {
        switch provider {
        case .claude: return activeClaudeProfileId
        case .codex: return activeCodexProfileId
        case .grok: return activeGrokProfileId
        }
    }

    /// True when `profile` CARRIES `provider`'s login and could therefore be the
    /// account that CLI is signed into.
    static func carriesLogin(_ profile: Profile, for provider: Profile.ProviderKind) -> Bool {
        switch provider {
        case .claude: return profile.cliCredentialsJSON != nil
        case .codex: return profile.codexCredentialsJSON != nil
        case .grok: return profile.grokCredentialsJSON != nil
        }
    }

    /// WHO OWNS `provider`'s shared CLI login — the Claude Code Keychain item,
    /// ~/.codex/auth.json, or ~/.grok/auth.json. The single definition the
    /// sweep, the auto-switch trigger, the credential self-heal, the dead-login
    /// skip and the header probe all read, so they cannot disagree.
    ///
    /// **FOCUS IS NEVER AUTHORITY.** `activeProfile` is only the account the
    /// user is LOOKING at, and every viewing surface lets them look at any
    /// account freely. Answering "who owns the CLI login" with "whoever is on
    /// screen" is the hazard this helper exists to remove: a *viewed* non-owner
    /// sitting at 96 % session would fire the auto-switch and move the CLI off
    /// the real owner that still has headroom. So the rule is:
    ///
    /// 1. **the pointer wins** — it records a login this app actually wrote, or
    ///    verified against the account-identity endpoint. It is the only
    ///    positive evidence in the system;
    /// 2. **with no pointer, a SOLE credentialed profile still answers** — the
    ///    CLI is signed in as that account or as nobody at all, so naming it
    ///    can wrong no one. (An install predating a pointer starts here.)
    /// 3. **otherwise nil.** Several candidates and no pointer means the app
    ///    does not know, and "does not know" must never be resolved by the
    ///    focus.
    ///
    /// `pool` restricts the sole-credentialed inference to a caller's own view
    /// of the roster (the menu bar paints a selected subset); the pointer is
    /// read from live state either way.
    ///
    /// Deliberately NOT gated on credential hydration, unlike the twin
    /// inference in `resolveProviderActiveAccounts` that PERSISTS a pointer.
    /// Mid-hydration "exactly one credentialed profile" can mean "exactly one
    /// hydrated so far", which is why nothing durable is written on it — but
    /// every consumer that could act destructively on a wrong answer carries
    /// its own guard (the auto-switch waits for hydration; the Keychain
    /// adoption is account-matched), and answering nil for the whole warm-up
    /// would blind the sweep on a single-account install.
    func providerOwnerId(for provider: Profile.ProviderKind, among pool: [Profile]? = nil) -> UUID? {
        if let pointer = providerPointer(for: provider) { return pointer }
        let candidates = (pool ?? profiles).filter { Self.carriesLogin($0, for: provider) }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    /// True when `id` owns `provider`'s shared CLI login (see `providerOwnerId`).
    func isProviderOwner(_ id: UUID, of provider: Profile.ProviderKind) -> Bool {
        providerOwnerId(for: provider) == id
    }

    /// True when `id` owns ANY provider's shared CLI login — the "this account
    /// is the one a CLI is burning right now" test that the sweep's backoffs,
    /// its throttle inference and the auto-switch trigger all want. Being the
    /// account on screen is NOT this test.
    func isProviderOwner(_ id: UUID) -> Bool {
        Profile.ProviderKind.allCases.contains { isProviderOwner(id, of: $0) }
    }

    /// True if the profile owns its provider's shared CLI login. One account per
    /// provider is active at any time, so up to THREE profiles carry the "Active"
    /// badge; the focused profile is a separate concept and gets no badge of its
    /// own.
    func isProviderActive(_ profile: Profile) -> Bool {
        isProviderOwner(profile.id)
    }

    /// Every account the UI marks as ACTIVE: the profiles that own their
    /// provider's shared CLI login, resolved by the one rule above.
    ///
    /// One definition, several consumers: the menu-bar tile's cyan label
    /// (`StatusBarUIManager.paintTiles`), the popover's "Active" badge, the
    /// dashboard snapshot — and, since focus stopped conferring authority, the
    /// auto-switch trigger's membership test. They disagreed before this
    /// existed: a Grok tile drew cyan while the popover called it inactive.
    func activeAccountIds(among profiles: [Profile]) -> Set<UUID> {
        Set(Profile.ProviderKind.allCases.compactMap { providerOwnerId(for: $0, among: profiles) })
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

    /// Profiles the user must re-login to resolve a shared-account state. Two
    /// sources, because they catch different halves of it:
    ///
    /// - `contaminated`: the profile's stamp disagreed with the identity its OWN
    ///   token reports, so a write moved another account's login into it. True
    ///   regardless of whether a duplicate group exists (the other side may have
    ///   been deleted since).
    /// - a duplicate group whose owner is known: every member EXCEPT the profile
    ///   that owns the shared CLI login is holding a copy of that account. The
    ///   owner is the one demonstrably logged in, so it is the others that need
    ///   their own account.
    ///
    /// A duplicate group the active login is not part of flags nobody: which
    /// member is the impostor is genuinely unknown there, and guessing would
    /// tell the user to re-login the profile they meant to keep. That group is
    /// still reported as a duplicate — it just gets no verdict about which side
    /// to fix.
    nonisolated static func profilesNeedingAccountRelogin(
        groups: [[UUID]], activeClaudeProfileId: UUID?, contaminated: Set<UUID>
    ) -> Set<UUID> {
        var needing = contaminated
        guard let owner = activeClaudeProfileId else { return needing }
        for group in groups where group.contains(owner) {
            needing.formUnion(group.filter { $0 != owner })
        }
        return needing
    }

    /// Published mirror of the above for the settings rows.
    @Published private(set) var profilesNeedingAccountRelogin: Set<UUID> = []

    /// True when this profile is holding another account's login and only a
    /// `/login` + Sync of ITS OWN account can fix it. The app never clears the
    /// credential itself.
    func needsAccountRelogin(_ profileId: UUID) -> Bool {
        profilesNeedingAccountRelogin.contains(profileId)
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

        let needingRelogin = Self.profilesNeedingAccountRelogin(
            groups: groups,
            activeClaudeProfileId: activeClaudeProfileId,
            contaminated: Set(profiles.map(\.id).filter { ClaudeCodeSyncService.shared.isLoginContaminated($0) })
        )
        if needingRelogin != profilesNeedingAccountRelogin {
            profilesNeedingAccountRelogin = needingRelogin
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
    /// - Claude: falls back to a SOLE CLI-credentialed profile. Never to the
    ///   focused one — the focus says what the user is looking at, not what the
    ///   CLI is signed into.
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
            setProviderOwner(.claude, to: nil, cause: .clear)
        }
        // With no pointer, infer an owner only from a SOLE credentialed profile
        // — the CLI is signed in as that account or as nobody. This used to
        // claim the FOCUSED profile, which wrote "the account on screen owns the
        // Keychain login" into persisted state on every load; with viewing now
        // free to land anywhere, that pointer would follow the user's browsing.
        // The exactly-one inference leans on absence, so it needs a completed
        // hydration to mean anything (same rule as the Codex arm below).
        if activeClaudeProfileId == nil, absenceIsEvidence {
            let claudeLogins = profiles.filter { $0.cliCredentialsJSON != nil }
            if claudeLogins.count == 1 {
                setProviderOwner(.claude, to: claudeLogins[0].id, cause: .launchRepair)
            }
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
            setProviderOwner(.codex, to: owner.id, cause: .launchRepair)
        } else {
            if absenceIsEvidence,
               let id = activeCodexProfileId,
               profiles.first(where: { $0.id == id })?.codexCredentialsJSON == nil {
                setProviderOwner(.codex, to: nil, cause: .clear)
            }
            // The exactly-one inference also leans on absence: with a partial
            // cache, "one codex profile" may just be "one HYDRATED so far".
            if absenceIsEvidence, activeCodexProfileId == nil {
                let codexProfiles = profiles.filter { $0.hasCodexAccount }
                if codexProfiles.count == 1 {
                    setProviderOwner(.codex, to: codexProfiles[0].id, cause: .launchRepair)
                }
            }
        }
        profileStore.saveActiveCodexProfileId(activeCodexProfileId)

        // Grok, resolved the way Codex is: ~/.grok/auth.json IS the grok CLI's
        // current login, so whenever its account matches a profile, that profile
        // owns the shared login regardless of what the pointer says.
        //
        // What deliberately does NOT happen here is the Codex side's
        // exactly-one-profile inference. A sole Codex profile is evidence
        // because the app has always written auth.json for Codex; for Grok it is
        // not — until this pointer shipped, nothing in the app ever wrote
        // ~/.grok/auth.json, so "one Grok profile" says nothing about who the
        // CLI is logged in as. With no match the pointer stays unset and
        // `providerOwnerId(for:)` answers from a sole credentialed Grok profile
        // — or, when several carry one, not at all.
        let grokService = GrokUsageService.shared
        if let fileJSON = grokService.readAuthFile(),
           let owner = profiles.first(where: { grokService.profileMatchesAuthFile($0, authFileJSON: fileJSON) }) {
            setProviderOwner(.grok, to: owner.id, cause: .launchRepair)
        } else if absenceIsEvidence,
                  let id = activeGrokProfileId,
                  profiles.first(where: { $0.id == id })?.grokCredentialsJSON == nil {
            // The recorded owner no longer holds a Grok login (removed, or the
            // profile is gone). Same absence rule as the two above: only a
            // completed hydration makes nil credentials mean anything.
            setProviderOwner(.grok, to: nil, cause: .clear)
        }
        profileStore.saveActiveGrokProfileId(activeGrokProfileId)

        LoggingService.shared.log("ProfileManager: active Claude=\(profiles.first(where: { $0.id == activeClaudeProfileId })?.name ?? "none"), active Codex=\(profiles.first(where: { $0.id == activeCodexProfileId })?.name ?? "none"), active Grok=\(profiles.first(where: { $0.id == activeGrokProfileId })?.name ?? "none")")
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
            setProviderOwner(.claude, to: owner.id, cause: .identityAdoption,
                             knownAccountStamp: identity.accountUUID)
            profileStore.saveActiveClaudeProfileId(owner.id)
            announceExternalOwnerChange(provider: .claude, newOwner: owner)
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
            refreshFocusedProfileCopy()
        }
        return owner.name
    }

    /// The profile that owns ~/.codex/auth.json right now, by the file's own
    /// `account_id` — the only deterministic answer, since that file IS the
    /// codex CLI's current login. Falls back to the standing owner (pointer,
    /// else a sole credentialed profile), never to the focus: this resolves the
    /// account auth.json's rotated refresh token is ADOPTED INTO, so naming the
    /// profile the user happens to be viewing would file one account's login
    /// under another's name.
    private func resolveOutgoingCodexOwner() -> UUID? {
        if let ownerId = codexOwnerFromAuthFile()?.id { return ownerId }
        return providerOwnerId(for: .codex)
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
            setProviderOwner(.codex, to: owner.id, cause: .identityAdoption)
            profileStore.saveActiveCodexProfileId(owner.id)
            announceExternalOwnerChange(provider: .codex, newOwner: owner)
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
            refreshFocusedProfileCopy()
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
