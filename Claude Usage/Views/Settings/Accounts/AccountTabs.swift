//
//  AccountTabs.swift
//  Claude Usage
//
//  The Accounts inspector's Alerts and Monitoring tabs and the Rename / Delete
//  footer (docs/specs/ux-revamp.md §2.2; design pass §12.2). Each edits the
//  VIEWED account through ProfileManager's update seams — the same writes
//  today's General page makes — and never touches what a CLI uses.
//

import SwiftUI

// MARK: - Alerts (per-account notification settings)

struct AccountAlertsTab: View {
    let profile: Profile
    @StateObject private var profileManager = ProfileManager.shared

    private var fleet: NotificationSettings { SharedDataStore.shared.loadFleetAlertDefaults() }

    private func update(_ change: (inout Profile) -> Void) {
        var updated = profile
        change(&updated)
        profileManager.updateProfile(updated)
    }

    var body: some View {
        SettingsContentCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                SettingToggle(
                    title: "accounts.alerts.follow_title".localized,
                    description: (profile.followsFleetAlertDefaults ? "accounts.alerts.follow_desc" : "accounts.alerts.own_state_desc").localized(with: profile.name),
                    isOn: Binding(get: { profile.followsFleetAlertDefaults }, set: { follows in
                        update { p in
                            // Leaving the fleet starts from the fleet's values when the
                            // account never had its own; its stored settings otherwise.
                            if !follows && p.notificationSettings == NotificationSettings() { p.notificationSettings = fleet }
                            p.followsFleetAlertDefaults = follows
                        }
                    })
                )
                Divider()
                if profile.followsFleetAlertDefaults {
                    HStack(alignment: .firstTextBaseline) {
                        Text("accounts.alerts.following".localized(with: FleetAlerts.summary(fleet)))
                            .font(DesignTokens.Typography.body).foregroundColor(.secondary)
                        Spacer()
                        Button("accounts.alerts.edit_fleet".localized) {
                            NotificationCenter.default.post(name: .settingsSectionRequested, object: SettingsRoute(section: .alerts))
                        }
                        .buttonStyle(.link)
                    }
                } else {
                    NotificationSettingsEditor(
                        settings: Binding(get: { profile.notificationSettings }, set: { value in update { $0.notificationSettings = value } }),
                        enableDescription: "accounts.alerts.own_desc".localized(with: profile.name)
                    )
                }
                Text("accounts.alerts.fleet_note".localized)
                    .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Monitoring (refresh, bar presence, tile label, eligibility)

struct AccountMonitoringTab: View {
    let profile: Profile
    @StateObject private var profileManager = ProfileManager.shared
    @State private var draftInterval: Double?
    @State private var draftLabel: String = ""
    @State private var labelNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            SettingsContentCard {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                    HStack {
                        Text("accounts.monitoring.refresh".localized(with: Int(draftInterval ?? profile.refreshInterval)))
                            .font(DesignTokens.Typography.bodyMedium)
                        Spacer()
                    }
                    Slider(
                        value: Binding(get: { draftInterval ?? profile.refreshInterval }, set: { draftInterval = $0 }),
                        in: 10...300, step: 10,
                        onEditingChanged: { editing in
                            guard !editing, let value = draftInterval else { return }
                            profileManager.updateRefreshInterval(value, for: profile.id)
                            draftInterval = nil
                        }
                    )
                    Text("accounts.monitoring.refresh_note".localized)
                        .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsContentCard {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                    SettingToggle(
                        title: "accounts.monitoring.show_on_bar".localized,
                        description: "accounts.monitoring.show_on_bar_desc".localized,
                        isOn: Binding(get: { profile.isSelectedForDisplay }, set: { _ in profileManager.toggleProfileSelection(profile.id) })
                    )
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("accounts.monitoring.label".localized).font(DesignTokens.Typography.body).fontWeight(.medium)
                        HStack {
                            TextField(String(profile.name.prefix(3)), text: $draftLabel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .onSubmit(commitLabel)
                            Button("common.save".localized, action: commitLabel).disabled(draftLabel == (profile.menuBarLabel ?? ""))
                            if let labelNote { Text(labelNote).font(DesignTokens.Typography.caption).foregroundColor(.orange) }
                        }
                        Text("accounts.monitoring.label_desc".localized)
                            .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        Text(profile.isAutoSwitchEnabled ? "accounts.monitoring.eligible_on".localized : "accounts.monitoring.eligible_off".localized)
                            .font(DesignTokens.Typography.body)
                        Spacer()
                        Button("accounts.monitoring.eligible_edit".localized) {
                            NotificationCenter.default.post(name: .settingsSectionRequested, object: SettingsRoute(section: .activeAccounts))
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .onAppear { draftLabel = profile.menuBarLabel ?? "" }
        .onChange(of: profile.id) { _, _ in draftLabel = profile.menuBarLabel ?? ""; labelNote = nil }
    }

    /// Commits the tile label; warns (but still saves) when another account
    /// already renders the same three letters — 40 accounts collide silently.
    private func commitLabel() {
        let trimmed = draftLabel.trimmingCharacters(in: .whitespaces)
        var updated = profile
        updated.menuBarLabel = trimmed.isEmpty ? nil : trimmed
        let shown = String(updated.menuBarDisplayName.prefix(3)).lowercased()
        let clash = profileManager.profiles.first { $0.id != profile.id && String($0.menuBarDisplayName.prefix(3)).lowercased() == shown }
        labelNote = clash.map { "accounts.monitoring.label_clash".localized(with: $0.name) }
        profileManager.updateProfile(updated)
    }
}

// MARK: - Footer (rename, delete)

struct AccountFooter: View {
    let profile: Profile
    @StateObject private var profileManager = ProfileManager.shared
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    var body: some View {
        HStack(spacing: 10) {
            if renaming {
                TextField("profiles.name_label".localized, text: $newName)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit(commitRename)
                Button("common.save".localized, action: commitRename).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("common.cancel".localized) { renaming = false }
            } else {
                Button("profiles.rename".localized) { newName = profile.name; renaming = true }
            }
            Spacer()
            if let deleteError { Text(deleteError).font(DesignTokens.Typography.caption).foregroundColor(.red) }
            Button("profiles.delete".localized, role: .destructive) { confirmingDelete = true }
                .disabled(profileManager.profiles.count < 2)
                .help(profileManager.profiles.count < 2 ? "accounts.footer.last_profile".localized : "")
        }
        .alert("profiles.delete_title".localized, isPresented: $confirmingDelete) {
            Button("common.delete".localized, role: .destructive) {
                do { try profileManager.deleteProfile(profile.id) } catch { deleteError = error.localizedDescription }
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text(String(format: "profiles.delete_confirm".localized, profile.name))
        }
    }

    private func commitRename() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var updated = profile
        updated.name = trimmed
        profileManager.updateProfile(updated)
        renaming = false
    }
}
