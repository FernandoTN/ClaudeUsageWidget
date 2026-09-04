//
//  ShortcutRowsCard.swift
//  Claude Usage
//
//  The four global shortcut rows with their recorders — Settings › Advanced, and the
//  legacy Shortcuts page until stage 3d deletes it.
//

import SwiftUI

// MARK: - The shortcut rows (shared by Settings › Advanced and the legacy Shortcuts page)

struct ShortcutRowsCard: View {
    @State private var togglePopoverCombo: KeyCombo? = ShortcutManager.shared.shortcuts[.togglePopover]
    @State private var refreshCombo: KeyCombo? = ShortcutManager.shared.shortcuts[.refresh]
    @State private var openSettingsCombo: KeyCombo? = ShortcutManager.shared.shortcuts[.openSettings]
    @State private var nextProfileCombo: KeyCombo? = ShortcutManager.shared.shortcuts[.nextProfile]

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.small) {
            // Toggle Popover
            shortcutRow(
                icon: "rectangle.portrait.and.arrow.right",
                title: "shortcuts.open_popover".localized,
                description: "shortcuts.open_popover_desc".localized,
                combo: $togglePopoverCombo,
                action: .togglePopover
            )

            // Refresh Usage
            shortcutRow(
                icon: "arrow.clockwise",
                title: "shortcuts.refresh".localized,
                description: "shortcuts.refresh_desc".localized,
                combo: $refreshCombo,
                action: .refresh
            )

            // Open Settings
            shortcutRow(
                icon: "gearshape",
                title: "shortcuts.open_settings".localized,
                description: "shortcuts.open_settings_desc".localized,
                combo: $openSettingsCombo,
                action: .openSettings
            )

            // Next Profile
            shortcutRow(
                icon: "person.and.arrow.left.and.arrow.right",
                title: "shortcuts.next_profile".localized,
                description: "shortcuts.next_profile_desc".localized,
                combo: $nextProfileCombo,
                action: .nextProfile
            )
        }
    }

    @ViewBuilder
    private func shortcutRow(
        icon: String,
        title: String,
        description: String,
        combo: Binding<KeyCombo?>,
        action: ShortcutAction
    ) -> some View {
        HStack {
            HStack(spacing: DesignTokens.Spacing.iconText) {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.Icons.standard))
                    .foregroundColor(.accentColor)
                    .frame(width: DesignTokens.Spacing.iconFrame)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignTokens.Typography.body)
                    Text(description)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            ShortcutRecorderView(keyCombo: Binding(
                get: { combo.wrappedValue },
                set: { newValue in
                    combo.wrappedValue = newValue
                    ShortcutManager.shared.setShortcut(newValue, for: action)
                }
            ))
        }
        .padding(DesignTokens.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                .fill(DesignTokens.Colors.cardBackground)
        )
    }
}
