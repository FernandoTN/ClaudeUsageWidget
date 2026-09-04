//
//  AccountLoginTab.swift
//  Claude Usage
//
//  The Accounts inspector's Login tab (docs/specs/ux-revamp.md §2.2, stage 2c):
//  the CLI Account / Codex Account behaviours rebuilt as components bound to
//  ONE profile id — never to whatever profile is viewed when an async call
//  returns — plus a Grok body of the same shape. Sync is renamed and gated
//  ("Import the CLI's current login into this profile…", `ImportGate`): it is
//  a switching action (spec R1) and says so.
//

import AppKit
import SwiftUI

struct AccountLoginTab: View {
    let profile: Profile
    @StateObject private var profileManager = ProfileManager.shared
    @State private var isBusy = false
    @State private var problem: String?
    @State private var showingLoginSheet = false
    @State private var showingImportSheet = false
    /// The account behind the CLI's current login, read when the tab appears.
    @State private var cliClaudeAccount: String?
    @State private var cliCodexAccount: String?

    // Provider exclusivity, as the legacy pages did it: a credential-less
    // profile offers every provider; one that carries an account offers its own.
    private var showsClaude: Bool { !profile.carriesCodexAccount && !profile.carriesGrokAccount }
    private var showsCodex: Bool { !profile.carriesClaudeAccount && !profile.carriesGrokAccount }
    private var showsGrok: Bool { profile.carriesGrokAccount || (!profile.carriesClaudeAccount && !profile.carriesCodexAccount) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            if let problem {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(DesignRole.blocking.color)
                    Text(problem).font(DesignTokens.Typography.caption).foregroundColor(DesignRole.blocking.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showsClaude { claudeCard }
            if showsCodex { codexCard }
            if showsGrok { grokCard }
        }
        .task(id: profile.id) {
            problem = nil
            // Small local files, read off the main actor.
            let (claude, codex) = await Task.detached(priority: .utility) { () -> (String?, String?) in
                let claude = ClaudeCodeSyncService.shared.cliCachedAccountUUID()
                let codex = CodexUsageService.shared.readAuthFile().flatMap { CodexUsageService.shared.extractAccountId(from: $0) }
                return (claude, codex)
            }.value
            cliClaudeAccount = claude
            cliCodexAccount = codex
        }
        .sheet(isPresented: $showingLoginSheet) {
            // The sheet keeps the profile it opened for; a roster change under it
            // does not retarget it (§12.2).
            CodexLoginSheet(viewedProfile: profile) {
                profileManager.loadProfiles()
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            }
        }
        .sheet(isPresented: $showingImportSheet) {
            CodexHomeImportSheet(profileId: profile.id) {
                profileManager.loadProfiles()
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            }
        }
    }

    // MARK: - Claude

    private var claudeCard: some View {
        let status = ProfileCredentialStatusCache.claudeTokenStatus(for: profile)
        let dead = ClaudeCodeSyncService.shared.isLoginMarkedDead(profile.id) || (status.map { if case .expired = $0 { return true }; return false } ?? false)
        return SettingsContentCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                providerHeader(.claude, hasLogin: profile.hasCliAccount, status: status, dead: dead)
                if profile.hasCliAccount {
                    identityLine([profile.claudeAccountEmail, profile.claudeAccountUUID.map { "accounts.account_suffix".localized(with: String($0.suffix(4))) },
                                  profile.cliAccountSyncedAt.map { "accounts.login.synced_at".localized(with: DashboardFormatting.age($0)) }])
                }
                if dead {
                    Text("accounts.login.claude_repair".localized).font(DesignTokens.Typography.caption).foregroundColor(DesignRole.blocking.color)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("accounts.login.claude_how".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(profile.hasCliAccount ? "accounts.login.reimport".localized : "accounts.login.import".localized) {
                        importClaude()
                    }
                    .disabled(isBusy)
                    .help(importHelp(decision: ImportGate.decision(cliAccount: cliClaudeAccount, profileAccount: profile.claudeAccountUUID, profileHasLogin: profile.hasCliAccount)))
                    if profile.hasCliAccount {
                        Button("common.remove".localized, role: .destructive) { removeClaude() }.disabled(isBusy)
                    }
                    if isBusy { ProgressView().scaleEffect(0.6) }
                }
            }
        }
    }

    private func importClaude() {
        let decision = ImportGate.decision(cliAccount: cliClaudeAccount, profileAccount: profile.claudeAccountUUID, profileHasLogin: profile.hasCliAccount)
        guard confirmImportIfNeeded(decision, provider: .claude) else { return }
        let id = profile.id
        isBusy = true; problem = nil
        // The sync reads the Keychain via a `security` subprocess — off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ClaudeCodeSyncService.shared.syncToProfile(id) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    profileManager.loadProfiles()
                    // Metadata by ID — never "whatever is viewed now".
                    if var updated = profileManager.profiles.first(where: { $0.id == id }) {
                        updated.hasCliAccount = true
                        updated.cliAccountSyncedAt = Date()
                        profileManager.updateProfile(updated)
                    }
                    // The profile now holds the CLI's current login → it owns the shared login.
                    profileManager.claimActiveClaudeOwnership(id)
                    Task { await ClaudeCodeSyncService.shared.stampAccountIdentity(for: id, force: true) }
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    LoggingService.shared.log("AccountLoginTab: Claude login imported into \(id)")
                case .failure(let error):
                    problem = error.localizedDescription
                }
                isBusy = false
            }
        }
    }

    private func removeClaude() {
        let id = profile.id
        do {
            try ClaudeCodeSyncService.shared.removeFromProfile(id)
            profileManager.loadProfiles()
            if var updated = profileManager.profiles.first(where: { $0.id == id }) {
                updated.hasCliAccount = false
                updated.cliAccountSyncedAt = nil
                profileManager.updateProfile(updated)
            }
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Codex

    private var codexCard: some View {
        let status = ProfileCredentialStatusCache.codexTokenStatus(for: profile)
        let dead = CodexUsageService.shared.isLoginMarkedDead(profile.id) || (status.map { if case .expired = $0 { return true }; return false } ?? false)
        return SettingsContentCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                providerHeader(.codex, hasLogin: profile.carriesCodexAccount, status: status, dead: dead)
                if profile.carriesCodexAccount {
                    identityLine([profile.codexEmail, profile.codexAccountId.map { "accounts.account_suffix".localized(with: String($0.suffix(4))) },
                                  profile.codexHomePath, profile.codexAccountSyncedAt.map { "accounts.login.synced_at".localized(with: DashboardFormatting.age($0)) }])
                }
                Text(dead ? "accounts.login.codex_repair".localized : "accounts.login.codex_how".localized)
                    .font(DesignTokens.Typography.caption).foregroundColor(dead ? DesignRole.blocking.color : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    // The repair path first: an isolated-home login never revokes another account.
                    Button("codex.login_new_account".localized) { showingLoginSheet = true }.disabled(isBusy)
                    Button("codex.import_from_home".localized) { showingImportSheet = true }.disabled(isBusy)
                }
                HStack(spacing: 8) {
                    Button(profile.carriesCodexAccount ? "accounts.login.reimport".localized : "accounts.login.import".localized) { importCodex() }
                        .disabled(isBusy)
                        .help(importHelp(decision: ImportGate.decision(cliAccount: cliCodexAccount, profileAccount: profile.codexAccountId, profileHasLogin: profile.carriesCodexAccount)))
                    if profile.carriesCodexAccount {
                        Button("common.remove".localized, role: .destructive) { removeCodex() }.disabled(isBusy)
                    }
                    if isBusy { ProgressView().scaleEffect(0.6) }
                }
                Text("codex.cli_hazard".localized).font(DesignTokens.Typography.caption).foregroundColor(DesignRole.caution.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func importCodex() {
        let decision = ImportGate.decision(cliAccount: cliCodexAccount, profileAccount: profile.codexAccountId, profileHasLogin: profile.carriesCodexAccount)
        guard confirmImportIfNeeded(decision, provider: .codex) else { return }
        let id = profile.id
        isBusy = true; problem = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CodexUsageService.shared.syncToProfile(id) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    profileManager.loadProfiles()
                    profileManager.claimActiveCodexOwnership(id)
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    LoggingService.shared.log("AccountLoginTab: Codex login imported into \(id)")
                case .failure(let error):
                    problem = error.localizedDescription
                }
                isBusy = false
            }
        }
    }

    private func removeCodex() {
        do {
            try CodexUsageService.shared.removeFromProfile(profile.id)
            profileManager.loadProfiles()
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Grok

    private var grokCard: some View {
        let json = profile.grokCredentialsJSON
        let expired = json.map { GrokUsageService.shared.isTokenExpired($0) } ?? false
        let dead = GrokUsageService.shared.isLoginMarkedDead(profile.id)
        let status: StoredTokenStatus? = json.map { j in
            StoredTokenStatus(expiry: GrokUsageService.shared.extractTokenExpiry(from: j), hasRefreshToken: !expired || !dead)
        }
        return SettingsContentCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                providerHeader(.grok, hasLogin: profile.carriesGrokAccount, status: status, dead: dead)
                if profile.carriesGrokAccount {
                    identityLine([profile.grokEmail, profile.grokAccountSyncedAt.map { "accounts.login.synced_at".localized(with: DashboardFormatting.age($0)) }])
                }
                Text("accounts.login.grok_how".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(profile.carriesGrokAccount ? "accounts.login.reimport".localized : "accounts.login.import".localized) { importGrok() }
                        .disabled(isBusy)
                    if isBusy { ProgressView().scaleEffect(0.6) }
                }
            }
        }
    }

    private func importGrok() {
        let id = profile.id
        isBusy = true; problem = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let service = GrokUsageService.shared
            let json = service.readAuthFile()
            DispatchQueue.main.async {
                defer { isBusy = false }
                guard let json, service.extractAccessToken(from: json) != nil else {
                    problem = "accounts.login.grok_missing".localized
                    return
                }
                do {
                    var credentials = try profileManager.loadCredentials(for: id)
                    credentials.grokCredentialsJSON = json
                    try profileManager.saveCredentials(for: id, credentials: credentials)
                    if var updated = profileManager.profiles.first(where: { $0.id == id }) {
                        updated.grokEmail = service.extractEmail(from: json) ?? updated.grokEmail
                        updated.grokAccountSyncedAt = Date()
                        profileManager.updateProfile(updated)
                    }
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    LoggingService.shared.log("AccountLoginTab: Grok login imported into \(id)")
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Pieces

    private func providerHeader(_ provider: Profile.ProviderKind, hasLogin: Bool, status: StoredTokenStatus?, dead: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hasLogin ? (dead ? "xmark.octagon.fill" : "checkmark.seal.fill") : "person.crop.circle.badge.questionmark")
                .foregroundColor(hasLogin ? (dead ? DesignRole.blocking.color : DesignRole.ready.color) : DesignRole.informational.color)
            Text(ActiveVocabulary.cliName(provider)).font(DesignTokens.Typography.sectionTitle)
            Spacer()
            if hasLogin, let status {
                Text(dead ? "profiles.token_expired".localized : status.text)
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(dead ? DesignRole.blocking.color : status.color)
            } else if !hasLogin {
                Text("accounts.login.none".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
            }
        }
    }

    private func identityLine(_ parts: [String?]) -> some View {
        Text(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(DesignTokens.Typography.caption).foregroundColor(.secondary).textSelection(.enabled)
    }

    private func importHelp(decision: ImportGate.Decision) -> String {
        switch decision {
        case .allowed: return "accounts.login.import_help_allowed".localized
        case .repair: return "accounts.login.import_help_repair".localized
        case .confirmDifferent(let cli, let mine):
            return "accounts.login.import_help_different".localized(with: ImportGate.suffix(cli), ImportGate.suffix(mine))
        case .confirmUnknown: return "accounts.login.import_help_unknown".localized
        }
    }

    /// The D13 gate: a silent copy only when it cannot mix accounts; otherwise an
    /// alert naming both sides, Cancel as the default.
    private func confirmImportIfNeeded(_ decision: ImportGate.Decision, provider: Profile.ProviderKind) -> Bool {
        guard decision.asksFirst else { return true }
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "accounts.login.confirm_title".localized(with: ActiveVocabulary.cliName(provider), profile.name)
        switch decision {
        case .confirmDifferent(let cli, let mine):
            alert.informativeText = "accounts.login.confirm_different".localized(
                with: ImportGate.suffix(cli), profile.name, ImportGate.suffix(mine), ActiveVocabulary.providerName(provider))
        default:
            alert.informativeText = "accounts.login.confirm_unknown".localized(with: profile.name, ActiveVocabulary.providerName(provider))
        }
        alert.addButton(withTitle: "common.cancel".localized)
        alert.addButton(withTitle: "accounts.login.confirm_import".localized)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
