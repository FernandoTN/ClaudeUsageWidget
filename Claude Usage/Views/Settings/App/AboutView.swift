//
//  AboutView.swift
//  Claude Usage - About and Credits
//
//  Created by Claude Code on 2025-12-20.
//

import SwiftUI
import AppKit

/// About page with app information
struct AboutView: View {
    @State private var showResetConfirmation = false

    private var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "Unknown"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.Spacing.section) {
                // Header with App Info
                VStack(spacing: DesignTokens.Spacing.medium) {
                    Image("AboutLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)

                    VStack(spacing: DesignTokens.Spacing.extraSmall) {
                        Text("app.name".localized)
                            .font(DesignTokens.Typography.pageTitle)

                        Text("about.version".localized(with: appVersion))
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, DesignTokens.Spacing.cardPadding)

                Divider()

                // Links
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                    Text("about.links".localized)
                        .font(DesignTokens.Typography.sectionTitle)

                    VStack(spacing: DesignTokens.Spacing.small) {
                        LinkButton(title: "about.run_setup_wizard".localized, icon: "wand.and.stars") {
                            LoggingService.shared.log("AboutView: Setup Wizard button clicked - posting notification")
                            NotificationCenter.default.post(name: .showSetupWizard, object: nil)
                        }

                        LinkButton(title: "about.reset_app_data".localized, icon: "trash") {
                            showResetConfirmation = true
                        }
                    }
                }
                .alert("about.reset_confirmation_title".localized, isPresented: $showResetConfirmation) {
                    Button("common.cancel".localized, role: .cancel) { }
                    Button("about.reset_confirm".localized, role: .destructive) {
                        resetAppData()
                    }
                } message: {
                    Text("about.reset_confirmation_message".localized)
                }

                // Footer
                VStack(spacing: DesignTokens.Spacing.extraSmall) {
                    Text("about.mit_license".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.Spacing.medium)

                Spacer()
            }
            .padding(28)
        }
    }

    private func resetAppData() {
        LoggingService.shared.log("AboutView: Resetting app data...")

        // Reset all app data (standard container only)
        MigrationService.shared.resetAppData()

        // Quit the app - user will need to relaunch and set up again
        LoggingService.shared.log("AboutView: App data reset complete, quitting app")
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Link Button

struct LinkButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.iconText) {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.Icons.small))
                    .foregroundColor(.secondary)
                    .frame(width: DesignTokens.Spacing.cardPadding)

                Text(title)
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview {
    AboutView()
        .frame(width: 520, height: 600)
}
