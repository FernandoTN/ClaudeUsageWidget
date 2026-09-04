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
                                    // The multi-account path: `codex login` in the
                                    // default ~/.codex revokes whatever is already
                                    // there, so extra accounts are logged in under
                                    // their own CODEX_HOME and imported from it.
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

/// Picks a CODEX_HOME, shows the account it holds (email + account-id suffix —
/// no token is ever rendered), and imports it into the viewed profile.
///
/// Why this exists: `codex login` revokes whatever credentials already sit in
/// the home it runs in, so a second `codex login` in the default `~/.codex`
/// kills the account the widget applied there. Each extra account is logged in
/// under its own home and brought here instead.
private struct CodexHomeImportSheet: View {
    let profileId: UUID
    let onImported: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var path: String = ""
    @State private var detected: CodexUsageService.CodexHomeAccount?
    @State private var duplicateHolder: String?
    @State private var problem: String?
    @State private var isImporting = false
    /// Serial number of the latest inspect, so a slow read for an
    /// already-replaced path cannot overwrite a newer result. A reference box
    /// because the completion closure must see the CURRENT value, not the copy
    /// captured when it was created.
    @State private var inspectGeneration = Generation()

    private final class Generation { var value = 0 }

    private var canImport: Bool {
        detected != nil && duplicateHolder == nil && !isImporting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("codex.import_title".localized)
                .font(DesignTokens.Typography.sectionTitle)
            Text("codex.import_subtitle".localized)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.iconText) {
                TextField("~/.codex-accounts/work", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.monospaced)
                    .onSubmit(inspect)
                Button("codex.import_choose".localized, action: chooseFolder)
                    .controlSize(.regular)
            }
            .onChange(of: path) { _, _ in inspect() }

            if let detected {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    HStack(spacing: DesignTokens.Spacing.small) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text(detected.email ?? "codex.import_detected".localized)
                            .font(DesignTokens.Typography.body)
                    }
                    if let suffix = detected.accountIdSuffix {
                        Text("codex.import_account_suffix".localized(with: suffix))
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("codex.import_no_account_id".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            if let duplicateHolder {
                warning(CodexError.accountAlreadySynced(profileName: duplicateHolder).localizedDescription)
            } else if let problem {
                warning(problem)
            }

            Text("codex.import_hint".localized)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("common.cancel".localized) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("codex.import_action".localized, action: performImport)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .padding()
        .frame(width: 520)
        .onAppear {
            let root = CodexUsageService.isolatedHomesRoot
            if FileManager.default.fileExists(atPath: root.path) {
                path = root.path
            }
        }
    }

    private func warning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Spacing.iconText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .cornerRadius(DesignTokens.Radius.small)
    }

    private func homeURL() -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // The homes are dot-directories; without this the user cannot see them.
        panel.showsHiddenFiles = true
        panel.prompt = "codex.import_panel_prompt".localized
        let root = CodexUsageService.isolatedHomesRoot
        panel.directoryURL = FileManager.default.fileExists(atPath: root.path)
            ? root
            : FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path  // onChange runs inspect()
    }

    /// Reads the chosen home and resolves the duplicate guard, so the refusal
    /// is on screen before the Import button is clickable.
    private func inspect() {
        detected = nil
        duplicateHolder = nil
        problem = nil
        guard let home = homeURL() else { return }

        let target = profileId
        let generation = inspectGeneration
        generation.value += 1
        let mine = generation.value

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CodexUsageService.shared.inspectCodexHome(home) }
            let holder = CodexUsageService.shared.duplicateHolderName(forHome: home, target: target)

            DispatchQueue.main.async {
                // The path may have moved on while this read was in flight.
                guard generation.value == mine else { return }
                switch result {
                case .success(let account):
                    detected = account
                    duplicateHolder = holder
                case .failure(let error):
                    problem = error.localizedDescription
                }
            }
        }
    }

    private func performImport() {
        guard canImport, let home = homeURL() else { return }
        isImporting = true
        problem = nil

        let target = profileId
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CodexUsageService.shared.importFromCodexHome(home, into: target) }

            DispatchQueue.main.async {
                isImporting = false
                switch result {
                case .success:
                    onImported()
                    dismiss()
                case .failure(let error):
                    problem = error.localizedDescription
                    LoggingService.shared.logError("CodexAccountView: import failed - \(error.localizedDescription)")
                }
            }
        }
    }
}
