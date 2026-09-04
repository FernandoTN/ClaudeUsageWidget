//
//  ShortcutsSettingsView.swift
//  Claude Usage
//
//  Keyboard shortcuts configuration settings
//

import SwiftUI

struct ShortcutsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "shortcuts.title".localized,
                    subtitle: "shortcuts.subtitle".localized
                )

                // Shortcuts Section
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                    Text("shortcuts.title".localized)
                        .font(DesignTokens.Typography.sectionTitle)

                    ShortcutRowsCard()
                }

                // Info Box
                HStack(spacing: DesignTokens.Spacing.medium) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: DesignTokens.Icons.standard))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("shortcuts.info_title".localized)
                            .font(DesignTokens.Typography.body)
                        Text("shortcuts.info_desc".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DesignTokens.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .fill(Color.blue.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .strokeBorder(Color.blue.opacity(0.2), lineWidth: 1)
                )

                Spacer()
            }
            .padding(28)
        }
    }
}

#Preview {
    ShortcutsSettingsView()
        .frame(width: 520, height: 600)
}
