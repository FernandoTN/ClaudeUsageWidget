//
//  SingleAccountBarCards.swift
//  Claude Usage
//
//  The single-account menu-bar icon configuration (colour mode, labels, markers,
//  metrics) — the two cards that were the Appearance page, now on Settings › Display
//  (docs/specs/ux-revamp.md §5.1, stage 3d). Edits the VIEWED profile's iconConfig;
//  dimmed while the bar shows multiple accounts.
//

import SwiftUI

struct SingleAccountBarCards: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var configuration: MenuBarIconConfiguration = .default

    private var isMultiProfileMode: Bool {
        profileManager.displayMode == .multi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
            // Global Settings
            SettingsSectionCard(
                title: "appearance.global_settings".localized,
                subtitle: "appearance.global_subtitle".localized
            ) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                    SettingToggle(
                        title: "appearance.monochrome_title".localized,
                        description: "appearance.monochrome_description".localized,
                        isOn: Binding(
                            get: { configuration.colorMode == .monochrome },
                            set: { newValue in
                                configuration.colorMode = newValue ? .monochrome : .multiColor
                                saveConfiguration()
                            }
                        )
                    )

                    SettingToggle(
                        title: "appearance.show_labels_title".localized,
                        description: "appearance.show_labels_description".localized,
                        isOn: Binding(
                            get: { configuration.showIconNames },
                            set: { newValue in
                                configuration.showIconNames = newValue
                                saveConfiguration()
                            }
                        )
                    )

                    SettingToggle(
                        title: "appearance.show_remaining_title".localized,
                        description: "appearance.show_remaining_description".localized,
                        isOn: Binding(
                            get: { configuration.showRemainingPercentage },
                            set: { newValue in
                                configuration.showRemainingPercentage = newValue
                                saveConfiguration()
                            }
                        )
                    )

                    SettingToggle(
                        title: "appearance.show_time_marker_title".localized,
                        description: "appearance.show_time_marker_description".localized,
                        isOn: Binding(
                            get: { configuration.showTimeMarker },
                            set: { newValue in
                                configuration.showTimeMarker = newValue
                                saveConfiguration()
                            }
                        )
                    )

                    SettingToggle(
                        title: "appearance.show_pace_marker_title".localized,
                        description: "appearance.show_pace_marker_description".localized,
                        isOn: Binding(
                            get: { configuration.showPaceMarker },
                            set: { newValue in
                                configuration.showPaceMarker = newValue
                                saveConfiguration()
                            }
                        )
                    )

                    SettingToggle(
                        title: "appearance.pace_coloring_title".localized,
                        description: "appearance.pace_coloring_description".localized,
                        isOn: Binding(
                            get: { configuration.usePaceColoring },
                            set: { newValue in
                                configuration.usePaceColoring = newValue
                                saveConfiguration()
                            }
                        )
                    )
                }
            }
            .disabled(isMultiProfileMode)
            .opacity(isMultiProfileMode ? 0.5 : 1.0)

            // Metrics Configuration
            SettingsSectionCard(
                title: "appearance.menu_bar_metrics".localized,
                subtitle: "appearance.metrics_subtitle".localized
            ) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                    // Info message when all metrics are disabled
                    if configuration.metrics.filter({ $0.isEnabled }).isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.blue)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("appearance.all_metrics_off_title".localized)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.primary)

                                Text("appearance.all_metrics_off_description".localized)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(DesignTokens.Spacing.small)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.blue.opacity(0.1))
                        )
                    }

                    // Session Usage
                    if let sessionIndex = configuration.metrics.firstIndex(where: { $0.metricType == .session }) {
                        MetricIconCard(
                            metricType: .session,
                            config: Binding(
                                get: { configuration.metrics[sessionIndex] },
                                set: { newValue in
                                    configuration.metrics[sessionIndex] = newValue
                                }
                            ),
                            onConfigChanged: { saveConfiguration() }
                        )
                    }

                    // Week Usage
                    if let weekIndex = configuration.metrics.firstIndex(where: { $0.metricType == .week }) {
                        MetricIconCard(
                            metricType: .week,
                            config: Binding(
                                get: { configuration.metrics[weekIndex] },
                                set: { newValue in
                                    configuration.metrics[weekIndex] = newValue
                                }
                            ),
                            onConfigChanged: { saveConfiguration() }
                        )
                    }
                    // .api metric deliberately omitted — decode-only legacy case
                }
            }
            .disabled(isMultiProfileMode)
            .opacity(isMultiProfileMode ? 0.5 : 1.0)
        }
        .onAppear {
            // Load configuration from active profile
            if let activeProfile = profileManager.activeProfile {
                configuration = activeProfile.iconConfig
            }
        }
        .onChange(of: profileManager.activeProfile?.id) { _, newProfileId in
            // Reload configuration when profile changes
            if let activeProfile = profileManager.activeProfile {
                configuration = activeProfile.iconConfig
            }
        }
    }

    // MARK: - Helper Methods

    private func saveConfiguration() {
        // Allow all metrics to be disabled - will show default app logo
        // No minimum enforcement needed

        // Save to active profile
        guard let profileId = profileManager.activeProfile?.id else {
            LoggingService.shared.logError("Cannot save appearance: no active profile")
            return
        }

        profileManager.updateIconConfig(configuration, for: profileId)

        // Notify that config changed (for MenuBarManager to update)
        NotificationCenter.default.post(name: .menuBarIconConfigChanged, object: nil)

        let enabledCount = configuration.metrics.filter { $0.isEnabled }.count
        LoggingService.shared.log("Saved icon configuration to profile (enabled: \(enabledCount))")
    }
}

