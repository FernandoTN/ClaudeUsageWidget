//
//  AlertsSettingsView.swift
//  Claude Usage
//
//  Settings › Alerts (docs/specs/ux-revamp.md §5.1, D11; design pass §12.4): the
//  fleet-wide alert defaults every following account uses, the list of accounts
//  that keep their own settings (each opens on its Alerts tab, or is pointed
//  back at the fleet), the bulk "follow the fleet" action and the rules.
//

import SwiftUI

struct AlertsSettingsView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var fleet: NotificationSettings = SharedDataStore.shared.loadFleetAlertDefaults()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(title: "alerts.title".localized, subtitle: "alerts.subtitle".localized)

                SettingsSectionCard(title: "alerts.fleet_title".localized, subtitle: "alerts.fleet_subtitle".localized) {
                    FleetAlertDefaultsCard(
                        settings: Binding(get: { fleet }, set: { value in
                            fleet = value
                            SharedDataStore.shared.saveFleetAlertDefaults(value)
                        }),
                        followers: FleetAlerts.followerCount(in: profileManager.profiles),
                        total: profileManager.profiles.count
                    )
                }

                SettingsSectionCard(title: "alerts.overrides_title".localized, subtitle: "alerts.overrides_subtitle".localized) {
                    AlertOverridesCard(
                        rows: FleetAlerts.overrides(in: profileManager.profiles, fleet: fleet),
                        onOpen: { id in
                            NotificationCenter.default.post(name: .settingsSectionRequested,
                                                            object: SettingsRoute(section: .accounts, profileId: id, tab: .alerts))
                        },
                        onFollow: { id in setFollowsFleet(true, for: [id]) },
                        onFollowAll: { setFollowsFleet(true, for: profileManager.profiles.filter { !$0.followsFleetAlertDefaults }.map(\.id)) }
                    )
                }

                Text("alerts.rules".localized)
                    .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .task {
            // First open persists the seed so the key exists on disk; the sweep
            // resolved the same value before this (absent reads as the defaults).
            guard !SharedDataStore.shared.hasFleetAlertDefaults() else { return }
            let seed = FleetAlerts.seed(from: profileManager.profiles)
            SharedDataStore.shared.saveFleetAlertDefaults(seed)
            fleet = seed
        }
    }

    /// Flips the flag only — the account's own settings stay stored so a later
    /// "use my own" starts from what it had.
    private func setFollowsFleet(_ follows: Bool, for ids: [UUID]) {
        for id in ids {
            guard var profile = profileManager.profiles.first(where: { $0.id == id }) else { continue }
            profile.followsFleetAlertDefaults = follows
            profileManager.updateProfile(profile)
        }
    }
}

// MARK: - Fleet defaults card

struct FleetAlertDefaultsCard: View {
    @Binding var settings: NotificationSettings
    let followers: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
            NotificationSettingsEditor(settings: $settings, enableDescription: "alerts.fleet_enable_desc".localized)
            Divider()
            Text(followers == total ? "alerts.followed_by_all".localized(with: total) : "alerts.followed_by".localized(with: followers, total))
                .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - Overrides card

struct AlertOverridesCard: View {
    let rows: [FleetAlerts.OverrideRow]
    let onOpen: (UUID) -> Void
    let onFollow: (UUID) -> Void
    let onFollowAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            if rows.isEmpty {
                Text("alerts.no_overrides".localized).font(DesignTokens.Typography.body).foregroundColor(.secondary)
            } else {
                ForEach(rows, id: \.id) { row in
                    HStack(spacing: DesignTokens.Spacing.small) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).font(DesignTokens.Typography.bodyMedium).lineLimit(1)
                            Text(row.differsFromFleet ? row.summary : "alerts.same_as_fleet".localized(with: row.summary))
                                .font(DesignTokens.Typography.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("alerts.open_account".localized) { onOpen(row.id) }.buttonStyle(.link)
                        Button("alerts.follow_fleet".localized) { onFollow(row.id) }.controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                Divider()
                HStack {
                    Text("alerts.follow_all_hint".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("alerts.follow_all".localized(with: rows.count)) { onFollowAll() }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - The one editor for a NotificationSettings value

/// Shared by the fleet defaults card and an account's own override, so the two
/// can never drift apart.
struct NotificationSettingsEditor: View {
    @Binding var settings: NotificationSettings
    let enableDescription: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
            SettingToggle(title: "notifications.enable".localized, description: enableDescription, isOn: $settings.enabled)
            if settings.enabled {
                Divider()
                Text("notifications.alert_thresholds".localized)
                    .font(DesignTokens.Typography.body).fontWeight(.medium).foregroundColor(.secondary)
                VStack(spacing: DesignTokens.Spacing.small) {
                    ThresholdToggleRow(level: "75%", color: DesignTokens.Colors.usageMedium, label: "notifications.threshold.warning".localized, isOn: $settings.threshold75Enabled)
                    ThresholdToggleRow(level: "90%", color: DesignTokens.Colors.warning, label: "notifications.threshold.high".localized, isOn: $settings.threshold90Enabled)
                    ThresholdToggleRow(level: "95%", color: DesignTokens.Colors.error, label: "notifications.threshold.critical".localized, isOn: $settings.threshold95Enabled)
                }
                Divider()
                Text("notifications.custom_thresholds".localized)
                    .font(DesignTokens.Typography.body).fontWeight(.medium).foregroundColor(.secondary)
                CustomThresholdsEditor(thresholds: $settings.customThresholds)
                Divider()
                NotificationSoundPicker(soundName: $settings.soundName)
            }
        }
    }
}
