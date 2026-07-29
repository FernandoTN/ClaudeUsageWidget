//
//  SettingsCard.swift
//  Claude Usage - Card Container Component
//
//  Created by Claude Code on 2025-12-20.
//

import SwiftUI

/// Modern card container for grouping related settings
/// Provides consistent card styling with optional header and footer
struct SettingsCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    let footer: String?
    let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    if let title = title {
                        Text(title)
                            .font(DesignTokens.Typography.subtitle)
                            .foregroundColor(.primary)
                    }

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.settingsCardPadding)
                .padding(.top, DesignTokens.Spacing.settingsCardPadding)
                .padding(.bottom, DesignTokens.Spacing.medium)
            }

            // Content
            content
                .padding(.horizontal, DesignTokens.Spacing.settingsCardPadding)
                .padding(.bottom, footer == nil ? DesignTokens.Spacing.settingsCardPadding : DesignTokens.Spacing.medium)

            // Footer
            if let footer = footer {
                Text(footer)
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DesignTokens.Spacing.settingsCardPadding)
                    .padding(.bottom, DesignTokens.Spacing.settingsCardPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
                .fill(DesignTokens.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
                .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Convenience Modifiers

extension SettingsCard {
    /// Create a card with just a title
    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: nil, footer: nil, content: content)
    }

    /// Create a card with title and footer
    init(
        title: String,
        footer: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: nil, footer: footer, content: content)
    }
}

// MARK: - Previews

#Preview("Basic Card") {
    SettingsCard {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("Card content goes here")
                .font(DesignTokens.Typography.bodyRegular)

            Text("More content")
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
        }
    }
    .padding()
}

#Preview("Card with Title") {
    SettingsCard(title: "Notification Settings") {
        VStack(spacing: DesignTokens.Spacing.medium) {
            SettingToggle(
                title: "Enable notifications",
                description: "Show notifications when usage thresholds are reached",
                isOn: .constant(true)
            )

            SettingToggle(
                title: "Sound alerts",
                description: "Play a sound with notifications",
                isOn: .constant(false)
            )
        }
    }
    .padding()
}

#Preview("Card with Title and Subtitle") {
    SettingsCard(
        title: "API Tracking",
        subtitle: "Configure your console.anthropic.com API tracking settings"
    ) {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("Session Key")
                .font(DesignTokens.Typography.body)
                .foregroundColor(.secondary)

            Text("sk-ant-api03-...")
                .font(DesignTokens.Typography.monospaced)
                .foregroundColor(.primary)
        }
    }
    .padding()
}

#Preview("Card with Footer") {
    SettingsCard(
        title: "Refresh Interval",
        footer: "Shorter intervals provide more real-time data but may impact battery life"
    ) {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            HStack {
                Text("Update every:")
                    .font(DesignTokens.Typography.bodyRegular)

                Spacer()

                Text("5 minutes")
                    .font(DesignTokens.Typography.bodyRegular)
                    .foregroundColor(.secondary)
            }

            Slider(value: .constant(5), in: 1...60)
        }
    }
    .padding()
}

#Preview("Multiple Cards") {
    VStack(spacing: DesignTokens.Spacing.cardPadding) {
        SettingsCard(title: "General") {
            SettingToggle(
                title: "Start at login",
                isOn: .constant(true)
            )
        }

        SettingsCard(title: "Appearance") {
            SettingToggle(
                title: "Show percentage in menu bar",
                isOn: .constant(false)
            )
        }

        SettingsCard(
            title: "Advanced",
            footer: "These settings are for advanced users only"
        ) {
            SettingToggle(
                title: "Debug mode",
                badge: .beta,
                isOn: .constant(false)
            )
        }
    }
    .padding()
}
