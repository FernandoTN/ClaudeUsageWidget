//
//  MetricIconCard.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import SwiftUI

/// Card component for configuring a metric's icon appearance
struct MetricIconCard: View {
    let metricType: MenuBarMetricType
    @Binding var config: MetricIconConfig
    let onConfigChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            // Header with enable toggle
            HStack {
                Image(systemName: metricType.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignTokens.Colors.accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(metricType.displayName)
                        .font(DesignTokens.Typography.sectionTitle)

                    Text(metricType.description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { config.isEnabled },
                    set: { newValue in
                        config.isEnabled = newValue
                        onConfigChanged()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            if config.isEnabled {
                // Icon style selector (session / week only; .api is decode-only legacy)
                switch metricType {
                case .session, .week:
                    Divider()
                        .padding(.vertical, DesignTokens.Spacing.extraSmall)

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                        Text("ui.icon_style".localized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)

                        IconStylePicker(selectedStyle: Binding(
                            get: { config.iconStyle },
                            set: { newValue in
                                config.iconStyle = newValue
                                onConfigChanged()
                            }
                        ))
                    }
                case .api:
                    // decode-only legacy case — no UI surface
                    EmptyView()
                }

                // Metric-specific options
                switch metricType {
                case .session where config.iconStyle == .battery || config.iconStyle == .progressBar:
                    Divider()
                        .padding(.vertical, DesignTokens.Spacing.extraSmall)
                    SessionDisplayOptions(config: $config, onConfigChanged: onConfigChanged)
                case .week where config.iconStyle == .percentageOnly:
                    Divider()
                        .padding(.vertical, DesignTokens.Spacing.extraSmall)
                    WeekDisplayOptions(config: $config, onConfigChanged: onConfigChanged)
                case .api:
                    // decode-only legacy case — no options UI
                    EmptyView()
                default:
                    EmptyView()
                }
            }
        }
        .padding(DesignTokens.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                .fill(DesignTokens.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                .strokeBorder(
                    config.isEnabled ? DesignTokens.Colors.success.opacity(0.3) : DesignTokens.Colors.cardBorder,
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Session Display Options

private struct SessionDisplayOptions: View {
    @Binding var config: MetricIconConfig
    let onConfigChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Toggle(isOn: Binding(
                get: { config.showNextSessionTime },
                set: { newValue in
                    config.showNextSessionTime = newValue
                    onConfigChanged()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("metric.show_countdown".localized)
                        .font(.system(size: 11, weight: .medium))
                    Text("metric.countdown_description".localized)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }
}

// MARK: - Week Display Options

private struct WeekDisplayOptions: View {
    @Binding var config: MetricIconConfig
    let onConfigChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text("ui.display_mode".localized)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            Picker("", selection: Binding(
                get: { config.weekDisplayMode },
                set: { newValue in
                    config.weekDisplayMode = newValue
                    onConfigChanged()
                }
            )) {
                ForEach(WeekDisplayMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.displayName)
                        Text(mode.description)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }
}

// MARK: - Previews

#Preview("Session Card - Enabled") {
    MetricIconCard(
        metricType: .session,
        config: .constant(.sessionDefault),
        onConfigChanged: {}
    )
    .frame(width: 500)
    .padding()
}

#Preview("Week Card - Enabled") {
    MetricIconCard(
        metricType: .week,
        config: .constant(MetricIconConfig(
            metricType: .week,
            isEnabled: true,
            iconStyle: .battery,
            order: 1,
            weekDisplayMode: .percentage
        )),
        onConfigChanged: {}
    )
    .frame(width: 500)
    .padding()
}
