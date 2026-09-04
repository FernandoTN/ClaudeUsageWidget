//
//  ManageProfilesView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import SwiftUI

struct ManageProfilesView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var showingCreateProfile = false
    @State private var newProfileName = ""
    @State private var errorMessage: String?
    @State private var autoSwitchThreshold = SharedDataStore.shared.loadAutoSwitchThreshold()
    @State private var autoSwitchWeeklyThreshold = SharedDataStore.shared.loadAutoSwitchWeeklyThreshold()
    @State private var switchQueue: [UUID] = SharedDataStore.shared.loadAutoSwitchQueue()
    /// The ⇄ active-account selector's visibility (docs/specs/ux-revamp.md
    /// §2.1). Lives here until the Display page exists (stage 3c).
    @State private var selectorEnabled = SharedDataStore.shared.loadActiveSelectorItemEnabled()

    private func providerLabel(_ profile: Profile) -> String {
        profile.providerKind == .claude ? "Claude"
            : profile.providerKind == .codex ? "Codex" : "Grok"
    }

    private func moveQueueEntry(_ index: Int, by delta: Int) {
        let target = index + delta
        guard switchQueue.indices.contains(index), switchQueue.indices.contains(target) else { return }
        switchQueue.swapAt(index, target)
        SharedDataStore.shared.saveAutoSwitchQueue(switchQueue)
    }

    private func removeQueueEntry(_ index: Int) {
        guard switchQueue.indices.contains(index) else { return }
        switchQueue.remove(at: index)
        SharedDataStore.shared.saveAutoSwitchQueue(switchQueue)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "profiles.title".localized,
                    subtitle: "profiles.subtitle".localized
                )

                // Profile List
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        ForEach(profileManager.profiles) { profile in
                            ProfileRow(profile: profile)
                                .padding(.vertical, DesignTokens.Spacing.extraSmall)

                            if profile.id != profileManager.profiles.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                // Create New Profile Button
                SettingsButton(
                    title: "profiles.create_new".localized,
                    icon: "plus.circle.fill"
                ) {
                    showingCreateProfile = true
                }

                // Multi-Profile Display Section
                SettingsSectionCard(
                    title: "multiprofile.title".localized,
                    subtitle: "multiprofile.subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                        // Main toggle
                        SettingToggle(
                            title: "multiprofile.enable_title".localized,
                            description: "multiprofile.enable_description".localized,
                            badge: .new,
                            isOn: Binding(
                                get: { profileManager.displayMode == .multi },
                                set: { enabled in
                                    // Manager mutates then posts .profileDisplayStructureChanged
                                    profileManager.updateDisplayMode(enabled ? .multi : .single)
                                }
                            )
                        )

                        // Profile selection (visible when multi-profile is ON)
                        if profileManager.displayMode == .multi {
                            Divider()

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.select_profiles".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                ForEach(profileManager.profiles) { profile in
                                    ProfileSelectionRow(
                                        profile: profile,
                                        isSelected: profile.isSelectedForDisplay,
                                        isActive: profileManager.isProviderActive(profile),
                                        onToggle: {
                                            // Ensure at least one profile stays selected
                                            let selectedCount = profileManager.profiles.filter { $0.isSelectedForDisplay }.count
                                            if profile.isSelectedForDisplay && selectedCount <= 1 {
                                                // Can't deselect the last one
                                                return
                                            }
                                            // Manager mutates then posts .profileDisplayStructureChanged
                                            profileManager.toggleProfileSelection(profile.id)
                                        }
                                    )
                                }

                                // Warning if trying to deselect last profile
                                if profileManager.profiles.lazy.filter({ $0.isSelectedForDisplay }).count == 1 {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                        Text("multiprofile.at_least_one".localized)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 4)
                                }
                            }

                            Divider()
                                .padding(.vertical, DesignTokens.Spacing.small)

                            // Icon Style Picker
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.icon_style".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                Picker("", selection: Binding(
                                    get: { profileManager.multiProfileConfig.iconStyle },
                                    set: { newStyle in
                                        var config = profileManager.multiProfileConfig
                                        config.iconStyle = newStyle
                                        // Manager mutates then posts .profileDisplayCosmeticsChanged
                                        profileManager.updateMultiProfileConfig(config)
                                    }
                                )) {
                                    ForEach(MultiProfileIconStyle.allCases, id: \.self) { style in
                                        Text(style.shortNameKey.localized).tag(style)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Menu bar layout: every account as its own tile
                            // (original), or ONE summary tile per provider —
                            // the active account plus a readiness fleet.
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.layout".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                Picker("", selection: Binding(
                                    get: { profileManager.multiProfileConfig.barLayout },
                                    set: { newLayout in
                                        var config = profileManager.multiProfileConfig
                                        config.barLayout = newLayout
                                        // Cosmetic: the provider item set is unchanged,
                                        // only what is painted into each item.
                                        profileManager.updateMultiProfileConfig(config)
                                    }
                                )) {
                                    ForEach(MenuBarLayout.allCases, id: \.self) { layout in
                                        Text(layout.shortNameKey.localized).tag(layout)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()

                                Text("multiprofile.layout_description".localized)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // What a click opens: the fleet dashboard or the
                            // classic single-account popover. "Follow layout"
                            // (nil) = dashboard for fleet layouts, classic for
                            // every-account.
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.click_surface".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                Picker("", selection: Binding(
                                    get: { profileManager.multiProfileConfig.clickSurface?.rawValue ?? "auto" },
                                    set: { raw in
                                        var config = profileManager.multiProfileConfig
                                        config.clickSurface = ClickSurface(rawValue: raw)
                                        profileManager.updateMultiProfileConfig(config)
                                    }
                                )) {
                                    Text("multiprofile.click_surface_auto".localized).tag("auto")
                                    Text("multiprofile.click_surface_dashboard".localized).tag(ClickSurface.dashboard.rawValue)
                                    Text("multiprofile.click_surface_classic".localized).tag(ClickSurface.classic.rawValue)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()

                                Text("multiprofile.click_surface_description".localized)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Show Week Toggle
                            SettingToggle(
                                title: "multiprofile.show_week".localized,
                                description: "multiprofile.show_week_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showWeek },
                                    set: { showWeek in
                                        var config = profileManager.multiProfileConfig
                                        config.showWeek = showWeek
                                        profileManager.updateMultiProfileConfig(config)
                                    }
                                )
                            )

                            // Show Profile Label Toggle
                            SettingToggle(
                                title: "multiprofile.show_label".localized,
                                description: "multiprofile.show_label_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showProfileLabel },
                                    set: { showLabel in
                                        var config = profileManager.multiProfileConfig
                                        config.showProfileLabel = showLabel
                                        profileManager.updateMultiProfileConfig(config)
                                    }
                                )
                            )

                            // Use System Color Toggle
                            SettingToggle(
                                title: "multiprofile.use_system_color".localized,
                                description: "multiprofile.use_system_color_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.useSystemColor },
                                    set: { useSystemColor in
                                        var config = profileManager.multiProfileConfig
                                        config.useSystemColor = useSystemColor
                                        profileManager.updateMultiProfileConfig(config)
                                    }
                                )
                            )

                            // Show Time Marker Toggle
                            SettingToggle(
                                title: "appearance.show_time_marker_title".localized,
                                description: "appearance.show_time_marker_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showTimeMarker },
                                    set: { showMarker in
                                        var config = profileManager.multiProfileConfig
                                        config.showTimeMarker = showMarker
                                        profileManager.updateMultiProfileConfig(config)
                                    }
                                )
                            )

                            // Pace Marker Toggle
                            SettingToggle(
                                title: "appearance.show_pace_marker_title".localized,
                                description: "appearance.show_pace_marker_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showPaceMarker },
                                    set: { showPace in
                                        var config = profileManager.multiProfileConfig
                                        config.showPaceMarker = showPace
                                        profileManager.updateMultiProfileConfig(config)
                                    }
                                )
                            )

                            // Pace-Aware Bar Colors Toggle
                            SettingToggle(
                                title: "appearance.pace_coloring_title".localized,
                                description: "appearance.pace_coloring_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.usePaceColoring },
                                    set: { usePace in
                                        var config = profileManager.multiProfileConfig
                                        config.usePaceColoring = usePace
                                        profileManager.updateMultiProfileConfig(config)
                                    }
                                )
                            )

                            // Info message
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                Text("multiprofile.info".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, DesignTokens.Spacing.small)
                        }
                    }
                }

                // Auto-Switch Profile Section
                // The ⇄ selector: one status item next to the system icons that
                // shows who is Active for Claude / Codex / Grok and switches it
                // behind a confirmation. Hiding it never changes what a CLI uses.
                SettingsSectionCard(
                    title: "selector.setting_title".localized,
                    subtitle: "selector.setting_subtitle".localized
                ) {
                    SettingToggle(
                        title: "selector.setting_toggle".localized,
                        description: "selector.setting_toggle_desc".localized,
                        isOn: Binding(
                            get: { selectorEnabled },
                            set: { enabled in
                                selectorEnabled = enabled
                                SharedDataStore.shared.saveActiveSelectorItemEnabled(enabled)
                                NotificationCenter.default.post(name: .activeSelectorVisibilityChanged, object: nil)
                            }
                        )
                    )
                }

                SettingsSectionCard(
                    title: "auto_switch.title".localized,
                    subtitle: "auto_switch.subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                        SettingToggle(
                            title: "auto_switch.enable_title".localized,
                            description: "auto_switch.enable_description".localized,
                            badge: .new,
                            isOn: Binding(
                                get: { SharedDataStore.shared.loadAutoSwitchProfileEnabled() },
                                set: { enabled in
                                    SharedDataStore.shared.saveAutoSwitchProfileEnabled(enabled)
                                }
                            )
                        )

                        Divider()

                        // Proactive switch threshold — typed percentage, saved on
                        // commit (Return / focus loss), clamped to the valid range.
                        ThresholdField(
                            title: "auto_switch.threshold_title".localized,
                            description: "auto_switch.threshold_description".localized,
                            value: $autoSwitchThreshold
                        ) { SharedDataStore.shared.saveAutoSwitchThreshold($0) }

                        // Weekly (all-models + Fable) switch threshold
                        ThresholdField(
                            title: "auto_switch.weekly_threshold_title".localized,
                            description: "auto_switch.weekly_threshold_description".localized,
                            value: $autoSwitchWeeklyThreshold
                        ) { SharedDataStore.shared.saveAutoSwitchWeeklyThreshold($0) }

                        Divider()

                        // Switch queue: a consumable playlist. #1 is the IMMEDIATE
                        // next auto-switch target; each switch consumes the entry
                        // it tried; empty queue = default soonest-weekly-reset.
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                            HStack {
                                Text("Switch queue")
                                    .font(DesignTokens.Typography.body)
                                Spacer()
                                Menu("Queue account…") {
                                    ForEach({ let queued = Set(switchQueue); return profileManager.profiles.filter { !queued.contains($0.id) } }()) { profile in
                                        Button("\(profile.name)  (\(providerLabel(profile)))") {
                                            switchQueue.append(profile.id)
                                            SharedDataStore.shared.saveAutoSwitchQueue(switchQueue)
                                        }
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }

                            if switchQueue.isEmpty {
                                Text("Queue is empty — the auto-switch uses the default order (account whose weekly limit resets soonest). Queue accounts to hand off in a specific sequence; each entry is used once, then the default order resumes.")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(Array(switchQueue.enumerated()), id: \.element) { index, id in
                                    if let profile = profileManager.profiles.first(where: { $0.id == id }) {
                                        HStack(spacing: DesignTokens.Spacing.small) {
                                            Text(index == 0 ? "next" : "\(index + 1).")
                                                .font(DesignTokens.Typography.caption)
                                                .foregroundColor(index == 0 ? DesignTokens.Colors.accent : .secondary)
                                                .monospacedDigit()
                                                .frame(width: 32, alignment: .trailing)
                                            Text(profile.name)
                                                .font(DesignTokens.Typography.body)
                                            Text(providerLabel(profile))
                                                .font(DesignTokens.Typography.caption)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Button { moveQueueEntry(index, by: -1) } label: {
                                                Image(systemName: "chevron.up")
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(index == 0)
                                            Button { moveQueueEntry(index, by: 1) } label: {
                                                Image(systemName: "chevron.down")
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(index == switchQueue.count - 1)
                                            Button { removeQueueEntry(index) } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                                Text("Each auto-switch consumes its entry; after the queue empties, the default order resumes. Headroom and dead-login checks still apply — an unusable queued account is skipped (and consumed). Providers never cross.")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        // Per-profile eligibility toggles
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                            Text("auto_switch.eligible_profiles".localized)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)

                            ForEach(profileManager.profiles) { profile in
                                Toggle(isOn: Binding(
                                    get: {
                                        // The ForEach already handed us this profile —
                                        // no O(N) re-lookup per binding read.
                                        profile.isAutoSwitchEnabled
                                    },
                                    set: { enabled in
                                        profileManager.updateAutoSwitchEnabled(enabled, for: profile.id)
                                    }
                                )) {
                                    HStack(spacing: DesignTokens.Spacing.small) {
                                        Text(profile.name)
                                            .font(DesignTokens.Typography.body)
                                            .lineLimit(1)
                                            .truncationMode(.tail)

                                        if profileManager.isProviderActive(profile) {
                                            Text("multiprofile.active_badge".localized)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor)
                                                .cornerRadius(4)
                                        }
                                    }
                                }
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                            }

                            Text("auto_switch.eligible_profiles_hint".localized)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }

                // Info Card
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: DesignTokens.Icons.standard))
                            Text("profiles.about_title".localized)
                                .font(DesignTokens.Typography.sectionTitle)
                        }

                        Text("profiles.about_description".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                            BulletPoint("profiles.about_credentials".localized)
                            BulletPoint("profiles.about_api".localized)
                            BulletPoint("profiles.about_cli".localized)
                            BulletPoint("profiles.about_appearance".localized)
                            BulletPoint("profiles.about_notifications".localized)
                            BulletPoint("profiles.about_refresh".localized)
                        }
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, DesignTokens.Spacing.small)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingCreateProfile) {
            CreateProfileSheet(
                profileName: $newProfileName,
                onSave: {
                    createNewProfile()
                },
                onCancel: {
                    showingCreateProfile = false
                    newProfileName = ""
                }
            )
        }
        .onAppear {
            // Reload: the auto-switch consumes entries store-side while this
            // view is closed; also drop entries whose profile was deleted.
            let ids = Set(profileManager.profiles.map(\.id))
            switchQueue = SharedDataStore.shared.loadAutoSwitchQueue().filter { ids.contains($0) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsChanged)) { _ in
            // Fires on every profile activation (auto or manual) — reload so a
            // consumed queue entry disappears from the list while it is open.
            switchQueue = SharedDataStore.shared.loadAutoSwitchQueue()
        }
    }

    private func createNewProfile() {
        let name = newProfileName.isEmpty ? nil : newProfileName
        _ = profileManager.createProfile(name: name)
        showingCreateProfile = false
        newProfileName = ""
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    let profile: Profile
    /// Deliberately NOT @StateObject/@ObservedObject: 14 rows each observing the
    /// shared manager re-evaluated the entire dense view (text fields, hover
    /// trackers, toggles) on EVERY publish — each re-layout re-registering its
    /// tracking areas with the window server, which is the synchronous-mach_msg
    /// storm sampled during the 2026-07-29 settings freezes. The parent list
    /// already re-renders rows when `profiles` changes; actions call the
    /// singleton without subscribing.
    private var profileManager: ProfileManager { ProfileManager.shared }
    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var showingDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            // Profile Icon
            Image(systemName: profile.hasCliAccount ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(profileManager.isProviderActive(profile) ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Profile Name", text: $editedName, onCommit: {
                        saveProfileName()
                    })
                    .textFieldStyle(.roundedBorder)
                } else {
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(.system(size: 14, weight: .medium))

                        if profileManager.isProviderActive(profile) {
                            Text("profiles.active_badge".localized)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .cornerRadius(4)
                        }
                    }
                }

                // Login health per provider, derived from the cached credential JSON
                // (in-memory only — no Keychain read on the main thread)
                let claudeStatus = claudeTokenStatus
                let codexStatus = codexTokenStatus
                if claudeStatus != nil || codexStatus != nil {
                    HStack(spacing: 6) {
                        if let status = claudeStatus {
                            CredentialStatusBadge(provider: "Claude", status: status)
                        }
                        if let status = codexStatus {
                            CredentialStatusBadge(provider: "Codex", status: status)
                        }
                    }
                }

                Text(profileInfo)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                // Two profiles holding ONE Anthropic account show that account's
                // quota twice. The app never resolves that itself (removing a
                // credential is the user's call), so the row says so instead.
                let sameAccountAs = profileManager.duplicateClaudeAccountPartnerNames(for: profile.id)
                if !sameAccountAs.isEmpty {
                    Text("profiles.same_account_as".localized(with: ListFormatter.localizedString(byJoining: sameAccountAs)))
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }

                // The actionable half: which side of a shared account to fix.
                // Shown only when the evidence names one (see
                // ProfileManager.profilesNeedingAccountRelogin) — never a guess.
                if profileManager.needsAccountRelogin(profile.id) {
                    Text("profiles.needs_account_relogin".localized)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                if !isEditing {
                    // Rename Button
                    Button(action: {
                        editedName = profile.name
                        isEditing = true
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("profiles.rename".localized)

                    // Activate Button (if not active)
                    if profileManager.activeProfile?.id != profile.id {
                        Button(action: {
                            Task {
                                await profileManager.activateProfile(profile.id, userInitiated: true)
                            }
                        }) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help("profiles.activate".localized)
                    }

                    // Delete Button (if not the last profile)
                    if profileManager.profiles.count > 1 {
                        Button(action: {
                            showingDeleteConfirmation = true
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("profiles.delete".localized)
                    }
                } else {
                    // Save Button
                    Button(action: {
                        saveProfileName()
                    }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)

                    // Cancel Button
                    Button(action: {
                        isEditing = false
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .alert("profiles.delete_title".localized, isPresented: $showingDeleteConfirmation) {
            Button("common.cancel".localized, role: .cancel) {}
            Button("common.delete".localized, role: .destructive) {
                deleteProfile()
            }
        } message: {
            Text(String(format: "profiles.delete_confirm".localized, profile.name))
        }
    }

    private var claudeTokenStatus: StoredTokenStatus? {
        ProfileCredentialStatusCache.claudeTokenStatus(for: profile)
    }

    private var codexTokenStatus: StoredTokenStatus? {
        ProfileCredentialStatusCache.codexTokenStatus(for: profile)
    }

    private var profileInfo: String {
        ProfileCredentialStatusCache.profileInfo(for: profile)
    }

    private func saveProfileName() {
        if !editedName.isEmpty && editedName != profile.name {
            var updated = profile
            updated.name = editedName
            profileManager.updateProfile(updated)
        }
        isEditing = false
    }

    private func deleteProfile() {
        do {
            try profileManager.deleteProfile(profile.id)
        } catch {
            // Error handled by ProfileManager
        }
    }
}

