//
//  CodexAccountView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-07-05.
//

import AppKit
import SwiftUI

/// Settings page for the OpenAI Codex CLI account attached to the active profile.
/// Mirrors CLIAccountView: syncs ~/.codex/auth.json into the profile, shows account
/// details, and supports re-sync / removal. To track a second Codex account, log
/// into it with `codex`, create a new profile, and sync there.
struct CodexAccountView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var showingImportSheet = false
    @State private var showingLoginSheet = false

    /// Provider exclusivity: a profile that already holds a Claude account can never
    /// be given a Codex one (the sidebar hides this page for such profiles; this is
    /// the belt-and-braces check in case it is reached anyway).
    private var isProviderLocked: Bool {
        guard let profile = profileManager.activeProfile else { return false }
        return profile.carriesClaudeAccount && !profile.carriesCodexAccount
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "codex.title".localized,
                    subtitle: "codex.subtitle".localized
                )

                if let profile = profileManager.activeProfile {
                    // Status Card
                    HStack(spacing: DesignTokens.Spacing.medium) {
                        Circle()
                            .fill(profile.hasCodexAccount ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: DesignTokens.StatusDot.standard, height: DesignTokens.StatusDot.standard)

                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                            Text(profile.hasCodexAccount ? "codex.synced".localized : "codex.not_synced".localized)
                                .font(DesignTokens.Typography.bodyMedium)

                            if profile.hasCodexAccount, let syncedAt = profile.codexAccountSyncedAt {
                                Text(syncedAt, style: .relative)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(DesignTokens.Spacing.medium)
                    .background(DesignTokens.Colors.cardBackground)
                    .cornerRadius(DesignTokens.Radius.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                            .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
                    )

                    // Account & Actions Card
                    SettingsSectionCard(
                        title: "codex.account_details".localized,
                        subtitle: profile.hasCodexAccount ? "codex.credentials_synced".localized : "codex.no_credentials".localized
                    ) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                            if profile.hasCodexAccount {
                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                                    if let email = profile.codexEmail {
                                        HStack(spacing: DesignTokens.Spacing.iconText) {
                                            Image(systemName: "person.badge.key")
                                                .font(.system(size: DesignTokens.Icons.standard))
                                                .foregroundColor(.accentColor)
                                                .frame(width: DesignTokens.Spacing.iconFrame)

                                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                                                Text("codex.account".localized)
                                                    .font(DesignTokens.Typography.caption)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(.secondary)
                                                Text(email)
                                                    .font(DesignTokens.Typography.body)
                                                    .foregroundColor(.primary)
                                            }
                                        }
                                    }

                                    if let home = profile.codexHomePath {
                                        HStack(spacing: DesignTokens.Spacing.iconText) {
                                            Image(systemName: "folder")
                                                .font(.system(size: DesignTokens.Icons.standard))
                                                .foregroundColor(.accentColor)
                                                .frame(width: DesignTokens.Spacing.iconFrame)

                                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                                                Text("codex.import_path_label".localized)
                                                    .font(DesignTokens.Typography.caption)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(.secondary)
                                                Text(home)
                                                    .font(DesignTokens.Typography.monospaced)
                                                    .foregroundColor(.primary)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }

                                    if let json = profile.codexCredentialsJSON,
                                       let token = CodexUsageService.shared.extractAccessToken(from: json) {
                                        HStack(spacing: DesignTokens.Spacing.iconText) {
                                            Image(systemName: "key")
                                                .font(.system(size: DesignTokens.Icons.standard))
                                                .foregroundColor(.accentColor)
                                                .frame(width: DesignTokens.Spacing.iconFrame)

                                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                                                Text("codex.access_token".localized)
                                                    .font(DesignTokens.Typography.caption)
                                                    .fontWeight(.medium)
                                                    .foregroundColor(.secondary)
                                                Text(maskCredential(token))
                                                    .font(DesignTokens.Typography.monospaced)
                                                    .foregroundColor(.primary)
                                            }
                                        }
                                    }
                                }
                            } else {
                                HStack(spacing: DesignTokens.Spacing.small) {
                                    Image(systemName: isProviderLocked ? "lock.fill" : "info.circle")
                                        .font(.system(size: DesignTokens.Icons.standard))
                                        .foregroundColor(.orange)
                                    Text((isProviderLocked ? "codex.locked_claude_profile" : "codex.sync_instructions").localized)
                                        .font(DesignTokens.Typography.body)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            if let error = syncError {
                                HStack(spacing: DesignTokens.Spacing.small) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                        .font(.system(size: DesignTokens.Icons.standard))
                                    Text(error)
                                        .font(DesignTokens.Typography.body)
                                        .foregroundColor(.red)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(DesignTokens.Spacing.iconText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08))
                                .cornerRadius(DesignTokens.Radius.small)
                            }

                            HStack(spacing: DesignTokens.Spacing.iconText) {
                                if !isProviderLocked {
                                    Button(action: syncFromCodexCLI) {
                                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                            if isSyncing {
                                                ProgressView()
                                                    .scaleEffect(0.8)
                                                    .frame(width: DesignTokens.Icons.small, height: DesignTokens.Icons.small)
                                            } else {
                                                Image(systemName: "arrow.triangle.2.circlepath")
                                                    .font(.system(size: DesignTokens.Icons.small))
                                            }
                                            Text(profile.hasCodexAccount ? "codex.resync".localized : "codex.sync_from_cli".localized)
                                                .font(DesignTokens.Typography.body)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)
                                    .disabled(isSyncing)
                                }

                                if !isProviderLocked {
                                    // The safe way to ADD an account: the CLI is
                                    // run with CODEX_HOME pointed at a fresh
                                    // folder, so its login has nothing to revoke.
                                    Button { showingLoginSheet = true } label: {
                                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                            Image(systemName: "person.badge.plus")
                                                .font(.system(size: DesignTokens.Icons.small))
                                            Text("codex.login_new_account".localized)
                                                .font(DesignTokens.Typography.body)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                    .disabled(isSyncing)
                                }

                                if !isProviderLocked {
                                    // The same account brought in from a home the
                                    // user logged into themselves.
                                    Button { showingImportSheet = true } label: {
                                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                            Image(systemName: "folder.badge.plus")
                                                .font(.system(size: DesignTokens.Icons.small))
                                            Text("codex.import_from_home".localized)
                                                .font(DesignTokens.Typography.body)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                    .disabled(isSyncing)
                                }

                                if profile.hasCodexAccount {
                                    Button(action: removeSync) {
                                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                            Image(systemName: "trash")
                                                .font(.system(size: DesignTokens.Icons.small))
                                            Text("common.remove".localized)
                                                .font(DesignTokens.Typography.body)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                    .foregroundColor(.red)
                                }

                                Spacer()
                            }

                            if !isProviderLocked {
                                Text("codex.cli_hazard".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    // Info Card
                    SettingsContentCard {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                            HStack(spacing: DesignTokens.Spacing.small) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: DesignTokens.Icons.standard))
                                Text("codex.about_title".localized)
                                    .font(DesignTokens.Typography.sectionTitle)
                            }

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                                BulletPoint("codex.benefit_1".localized)
                                BulletPoint("codex.benefit_2".localized)
                                BulletPoint("codex.benefit_3".localized)
                            }
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)

                            Text("codex.multi_account_note".localized)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.orange)
                                .padding(DesignTokens.Spacing.small)
                                .background(Color.orange.opacity(0.08))
                                .cornerRadius(DesignTokens.Radius.tiny)
                        }
                    }
                }
            }
            .padding()
        }
        .onChange(of: profileManager.activeProfile?.id) { _, _ in
            syncError = nil
        }
        .sheet(isPresented: $showingLoginSheet) {
            CodexLoginSheet(
                viewedProfile: isProviderLocked ? nil : profileManager.activeProfile,
                onFinished: {
                    profileManager.loadProfiles()
                    // Like Import, the login writes nothing to ~/.codex, so the
                    // Codex owner pointer is left where it is.
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    LoggingService.shared.log("CodexAccountView: isolated-home login complete")
                }
            )
        }
        .sheet(isPresented: $showingImportSheet) {
            if let profileId = profileManager.activeProfile?.id {
                CodexHomeImportSheet(profileId: profileId) {
                    profileManager.loadProfiles()
                    // Deliberately NOT claimActiveCodexOwnership: an import does
                    // not write ~/.codex/auth.json, so the imported account is
                    // not the CLI's login until this profile is activated.
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    LoggingService.shared.log("CodexAccountView: Codex import from a separate home complete")
                }
            }
        }
    }

    private func syncFromCodexCLI() {
        guard let profileId = profileManager.activeProfile?.id, !isProviderLocked else { return }

        isSyncing = true
        syncError = nil

        // File I/O only, but keep it off the main thread for consistency
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CodexUsageService.shared.syncToProfile(profileId) }

            DispatchQueue.main.async {
                switch result {
                case .success:
                    profileManager.loadProfiles()
                    // The profile now holds a copy of auth.json, i.e. the codex CLI's
                    // current login — so it owns the shared login from here on.
                    profileManager.claimActiveCodexOwnership(profileId)
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    LoggingService.shared.log("CodexAccountView: Codex sync complete")
                case .failure(let error):
                    syncError = error.localizedDescription
                    LoggingService.shared.logError("CodexAccountView: sync failed - \(error.localizedDescription)")
                }
                isSyncing = false
            }
        }
    }

    private func removeSync() {
        guard let profileId = profileManager.activeProfile?.id else { return }

        do {
            try CodexUsageService.shared.removeFromProfile(profileId)
            profileManager.loadProfiles()
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            LoggingService.shared.log("CodexAccountView: Codex credentials removed from profile")
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func maskCredential(_ credential: String) -> String {
        guard credential.count > 20 else { return "•••••••••" }
        return "\(credential.prefix(12))•••••\(credential.suffix(4))"
    }
}
