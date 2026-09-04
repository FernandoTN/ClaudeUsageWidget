//
//  GeneralSettingsView.swift
//  Claude Usage - General Profile Settings
//
//  Refactored to use DesignTokens and SettingsSection components
//

import SwiftUI
import UserNotifications

/// General profile settings: Refresh interval, Auto-start, Notifications
struct GeneralSettingsView: View {
    @StateObject private var profileManager = ProfileManager.shared
    /// In-flight slider value during a drag; committed to the profile store
    /// once on release (see the refresh-interval Slider).
    @State private var draftRefreshInterval: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "general.title".localized,
                    subtitle: "general.subtitle".localized
                )

                if let profile = profileManager.activeProfile {
                    // Refresh Interval
                    SettingsSectionCard(
                        title: "general.refresh_title".localized,
                        subtitle: "general.refresh_subtitle".localized
                    ) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                            HStack(spacing: DesignTokens.Spacing.iconText) {
                                Image(systemName: "clock")
                                    .font(.system(size: DesignTokens.Icons.standard))
                                    .foregroundColor(DesignTokens.Colors.accent)
                                    .frame(width: DesignTokens.Spacing.iconFrame)

                                Text(String(format: "general.refresh_seconds".localized, Int(draftRefreshInterval ?? profile.refreshInterval)))
                                    .font(DesignTokens.Typography.bodyMedium)

                                Spacer()
                            }

                            // Persist once per drag (on release), not once per
                            // 10s step — each updateProfile call re-encodes and
                            // saves the entire profile store.
                            Slider(
                                value: Binding(
                                    get: { draftRefreshInterval ?? profile.refreshInterval },
                                    set: { draftRefreshInterval = $0 }
                                ),
                                in: 10...300,
                                step: 10,
                                onEditingChanged: { editing in
                                    guard !editing, let value = draftRefreshInterval else { return }
                                    var updated = profile
                                    updated.refreshInterval = value
                                    profileManager.updateProfile(updated)
                                    draftRefreshInterval = nil
                                }
                            )

                            HStack {
                                Text("general.refresh_min".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("general.refresh_max".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Notifications
                    SettingsSectionCard(
                        title: "general.notifications_title".localized,
                        subtitle: "general.notifications_subtitle".localized
                    ) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                            SettingToggle(
                                title: "notifications.enable".localized,
                                description: "notifications.enable.description".localized,
                                isOn: Binding(
                                    get: { profile.notificationSettings.enabled },
                                    set: { newValue in
                                        var updated = profile
                                        updated.notificationSettings.enabled = newValue
                                        profileManager.updateProfile(updated)

                                        if newValue {
                                            requestNotificationPermission()
                                        }
                                    }
                                )
                            )

                            if profile.notificationSettings.enabled {
                                Divider()

                                // Built-in thresholds (toggleable)
                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                                    Text("notifications.alert_thresholds".localized)
                                        .font(DesignTokens.Typography.body)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)

                                    VStack(spacing: DesignTokens.Spacing.small) {
                                        ThresholdToggleRow(
                                            level: "75%",
                                            color: DesignTokens.Colors.usageMedium,
                                            label: "notifications.threshold.warning".localized,
                                            isOn: Binding(
                                                get: { profile.notificationSettings.threshold75Enabled },
                                                set: { newValue in
                                                    var updated = profile
                                                    updated.notificationSettings.threshold75Enabled = newValue
                                                    profileManager.updateProfile(updated)
                                                }
                                            )
                                        )
                                        ThresholdToggleRow(
                                            level: "90%",
                                            color: DesignTokens.Colors.warning,
                                            label: "notifications.threshold.high".localized,
                                            isOn: Binding(
                                                get: { profile.notificationSettings.threshold90Enabled },
                                                set: { newValue in
                                                    var updated = profile
                                                    updated.notificationSettings.threshold90Enabled = newValue
                                                    profileManager.updateProfile(updated)
                                                }
                                            )
                                        )
                                        ThresholdToggleRow(
                                            level: "95%",
                                            color: DesignTokens.Colors.error,
                                            label: "notifications.threshold.critical".localized,
                                            isOn: Binding(
                                                get: { profile.notificationSettings.threshold95Enabled },
                                                set: { newValue in
                                                    var updated = profile
                                                    updated.notificationSettings.threshold95Enabled = newValue
                                                    profileManager.updateProfile(updated)
                                                }
                                            )
                                        )
                                        ThresholdIndicator(level: "0%", color: DesignTokens.Colors.success, label: "notifications.threshold.session_reset".localized)
                                    }
                                }

                                // Custom thresholds
                                Divider()

                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                                    Text("notifications.custom_thresholds".localized)
                                        .font(DesignTokens.Typography.body)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)

                                    CustomThresholdsEditor(
                                        thresholds: Binding(
                                            get: { profile.notificationSettings.customThresholds },
                                            set: { newValue in
                                                var updated = profile
                                                updated.notificationSettings.customThresholds = newValue
                                                profileManager.updateProfile(updated)
                                            }
                                        )
                                    )
                                }

                                // Sound picker
                                Divider()

                                NotificationSoundPicker(
                                    soundName: Binding(
                                        get: { profile.notificationSettings.soundName },
                                        set: { newValue in
                                            var updated = profile
                                            updated.notificationSettings.soundName = newValue
                                            profileManager.updateProfile(updated)
                                        }
                                    )
                                )
                            }
                        }
                    }

                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Helper Methods

    private func requestNotificationPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            if settings.authorizationStatus == .authorized {
                NotificationManager.shared.sendSimpleAlert(type: .notificationsEnabled)
            } else if settings.authorizationStatus == .notDetermined {
                let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                if granted == true {
                    NotificationManager.shared.sendSimpleAlert(type: .notificationsEnabled)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview {
    GeneralSettingsView()
        .frame(width: 520, height: 600)
}
