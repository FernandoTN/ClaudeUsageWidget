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
                                    profileManager.updateDisplayMode(enabled ? .multi : .single)
                                    // Post notification for menu bar to update
                                    NotificationCenter.default.post(name: .displayModeChanged, object: nil)
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
                                            profileManager.toggleProfileSelection(profile.id)
                                            // Post notification for menu bar to update
                                            NotificationCenter.default.post(name: .displayModeChanged, object: nil)
                                        }
                                    )
                                }

                                // Warning if trying to deselect last profile
                                if profileManager.profiles.filter({ $0.isSelectedForDisplay }).count == 1 {
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
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
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
                                        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
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
                                        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
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
                                        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
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
                                        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
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
                                        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
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
                                        NotificationCenter.default.post(name: .displayModeChanged, object: nil)
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

                        // Per-profile eligibility toggles
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                            Text("auto_switch.eligible_profiles".localized)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)

                            ForEach(profileManager.profiles) { profile in
                                Toggle(isOn: Binding(
                                    get: {
                                        profileManager.profiles.first(where: { $0.id == profile.id })?.isAutoSwitchEnabled ?? true
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
    @StateObject private var profileManager = ProfileManager.shared
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
                                await profileManager.activateProfile(profile.id)
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
        guard let json = profile.cliCredentialsJSON else { return nil }
        if ClaudeCodeSyncService.shared.isLoginMarkedDead(profile.id) { return .expired }
        return StoredTokenStatus(
            expiry: ClaudeCodeSyncService.shared.extractTokenExpiry(from: json),
            hasRefreshToken: ClaudeCodeSyncService.shared.extractRefreshToken(from: json) != nil
        )
    }

    private var codexTokenStatus: StoredTokenStatus? {
        guard let json = profile.codexCredentialsJSON else { return nil }
        if CodexUsageService.shared.isLoginMarkedDead(profile.id) { return .expired }
        return StoredTokenStatus(
            expiry: CodexUsageService.shared.extractTokenExpiry(from: json),
            hasRefreshToken: CodexUsageService.shared.extractRefreshToken(from: json) != nil
        )
    }

    private var profileInfo: String {
        var parts: [String] = []

        if profile.hasCliAccount {
            parts.append("profiles.cli_synced".localized)
        }

        if profile.hasCodexAccount {
            parts.append(profile.codexEmail.map { "Codex: \($0)" } ?? "profiles.codex_synced".localized)
        }

        parts.append("\("profiles.created".localized) \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")

        return parts.joined(separator: " • ")
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

// MARK: - Stored login health

/// Lifecycle state of a stored OAuth login. An expired access token with a live
/// refresh token on file is NOT a problem — the app redeems it on the next fetch —
/// so it renders as "renews automatically", not as an error.
enum StoredTokenStatus {
    case valid(until: Date)
    case autoRenews
    case expired

    init(expiry: Date?, hasRefreshToken: Bool) {
        if let expiry, expiry > Date() {
            self = .valid(until: expiry)
        } else if hasRefreshToken {
            self = .autoRenews
        } else {
            self = .expired
        }
    }

    private static let relativeFormatter = RelativeDateTimeFormatter()

    var color: Color {
        switch self {
        case .valid: return .green
        // Neutral, not a warning: an expired access token with a live refresh
        // token is the NORMAL resting state of every inactive profile (access
        // tokens are short-lived) — orange here would paint a healthy 5-account
        // list as four problems. Orange/red are reserved for real trouble.
        case .autoRenews: return .secondary
        case .expired: return .red
        }
    }

    var text: String {
        switch self {
        case .valid(let until):
            let relative = Self.relativeFormatter.localizedString(for: until, relativeTo: Date())
            return String(format: "profiles.token_valid".localized, relative)
        case .autoRenews:
            return "profiles.token_auto_renews".localized
        case .expired:
            return "profiles.token_expired".localized
        }
    }
}

struct CredentialStatusBadge: View {
    let provider: String
    let status: StoredTokenStatus

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(status.color)
                .frame(width: 5, height: 5)

            Text("\(provider): \(status.text)")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(status.color.opacity(0.12))
        .cornerRadius(4)
    }
}

// MARK: - Create Profile Sheet

struct CreateProfileSheet: View {
    @Binding var profileName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("profiles.create_title".localized)
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("profiles.name_label".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                TextField("profiles.name_placeholder".localized, text: $profileName)
                    .textFieldStyle(.roundedBorder)

                Text("profiles.name_hint".localized)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button("common.cancel".localized) {
                    onCancel()
                }
                .buttonStyle(.plain)

                Button("common.create".localized) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
