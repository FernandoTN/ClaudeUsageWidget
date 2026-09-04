//
//  AppearanceSettingsView.swift
//  Claude Usage - Menu Bar Appearance Settings
//
//  Created by Claude Code on 2025-12-27.
//

import SwiftUI

/// Menu bar icon appearance and customization with multi-metric support
struct AppearanceSettingsView: View {
    @ObservedObject private var profileManager = ProfileManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(title: "appearance.title".localized, subtitle: "appearance.subtitle".localized)
                if profileManager.displayMode == .multi {
                    MultiProfileModeWarningCard(onDisableMultiProfile: { profileManager.updateDisplayMode(.single) })
                }
                // The cards live in SingleAccountBarCards and are also on Settings › Display;
                // this page goes with the legacy set (stage 3d).
                SingleAccountBarCards()
                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Multi-Profile Mode Warning Card

struct MultiProfileModeWarningCard: View {
    let onDisableMultiProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("appearance.multiprofile_locked_title".localized)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("appearance.multiprofile_locked_description".localized)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Button(action: onDisableMultiProfile) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10))
                    Text("appearance.disable_multiprofile".localized)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.orange, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(DesignTokens.Spacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Previews

#Preview {
    AppearanceSettingsView()
        .frame(width: 520, height: 600)
}
