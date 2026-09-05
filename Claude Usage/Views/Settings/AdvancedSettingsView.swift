//
//  AdvancedSettingsView.swift
//  Claude Usage
//
//  Settings › Advanced (docs/specs/ux-revamp.md §5.1; design pass §12.5): launch
//  at login, keyboard shortcuts, diagnostics (the first UI for the debug API
//  logging switch, plus the log command), the persisted dead-login flags with a
//  way to forget them, and the stored-settings registry with its "not
//  registered" alarm.
//

import SwiftUI
import AppKit

struct AdvancedSettingsView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var launchAtLogin = LaunchAtLoginManager.shared.isEnabled
    @State private var deadRows: [DeadLoginFlagRow] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(title: "advanced.title".localized, subtitle: "advanced.subtitle".localized)
                SettingsSectionCard(title: "advanced.startup_title".localized, subtitle: "general.launch_at_login.description".localized) {
                    SettingToggle(title: "general.launch_at_login".localized, description: "general.launch_at_login.description".localized, isOn: $launchAtLogin)
                }
                SettingsSectionCard(title: "shortcuts.title".localized, subtitle: "shortcuts.subtitle".localized) {
                    ShortcutRowsCard()
                }
                SettingsSectionCard(title: "advanced.diagnostics_title".localized, subtitle: "advanced.diagnostics_subtitle".localized) {
                    AdvancedDiagnosticsCard()
                }
                SettingsSectionCard(title: "advanced.codex_daemon_title".localized, subtitle: "advanced.codex_daemon_subtitle".localized) {
                    CodexDaemonCard()
                }
                SettingsSectionCard(title: "advanced.dead_title".localized, subtitle: "advanced.dead_subtitle".localized) {
                    DeadLoginFlagsCard(rows: deadRows) { row in
                        DeadLoginFlags.forget(row)
                        deadRows = DeadLoginFlags.rows(profiles: profileManager.profiles)
                    }
                }
                SettingsSectionCard(title: "advanced.keys_title".localized, subtitle: "advanced.keys_subtitle".localized) {
                    StoredSettingsCard()
                }
            }
            .padding()
        }
        .onChange(of: launchAtLogin) { _, value in LaunchAtLoginManager.shared.setEnabled(value) }
        .onAppear { deadRows = DeadLoginFlags.rows(profiles: profileManager.profiles) }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsChanged)) { _ in
            deadRows = DeadLoginFlags.rows(profiles: profileManager.profiles)
        }
    }
}

// MARK: - Diagnostics

struct AdvancedDiagnosticsCard: View {
    @State private var debugLogging = SharedDataStore.shared.loadDebugAPILoggingEnabled()
    private let logCommand = "log show --predicate 'subsystem == \"\(Bundle.main.bundleIdentifier ?? "com.claudeusagewidget.app")\"' --info --last 10m"

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "advanced.version".localized(with: version, build)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
            SettingToggle(
                title: "advanced.debug_logging".localized,
                description: "advanced.debug_logging_desc".localized,
                isOn: Binding(get: { debugLogging }, set: { on in
                    debugLogging = on
                    SharedDataStore.shared.saveDebugAPILoggingEnabled(on)
                })
            )
            Divider()
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("advanced.log_hint".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                HStack {
                    Text(logCommand).font(DesignTokens.Typography.captionMono).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("advanced.copy".localized) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(logCommand, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            Text(versionLine).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - Codex daemon (docs/specs/codex-daemon-awareness.md)

/// The opt-in restart-on-switch toggle, a live status line, and the manual
/// restart. The status comes from one `ps` scan off the main actor on appear
/// and on "Check"; nothing here watches anything.
struct CodexDaemonCard: View {
    @State private var restartOnSwitch = SharedDataStore.shared.loadCodexDaemonRestartOnSwitch()
    @State private var status: CodexDaemon.Status? = CodexDaemonService.shared.lastStatus
    @State private var checking = false

    private var statusLine: String {
        guard let status else { return "advanced.codex_daemon_status_unknown".localized }
        guard let daemon = status.daemon else { return "advanced.codex_daemon_status_not_running".localized }
        return "advanced.codex_daemon_status_running".localized(with: Int(daemon.pid), status.attachedSessions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
            SettingToggle(
                title: "advanced.codex_daemon_restart_on_switch".localized,
                description: "advanced.codex_daemon_restart_on_switch_desc".localized,
                isOn: Binding(get: { restartOnSwitch }, set: { on in
                    restartOnSwitch = on
                    SharedDataStore.shared.saveCodexDaemonRestartOnSwitch(on)
                })
            )
            Divider()
            HStack(spacing: 8) {
                Text(statusLine).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                Spacer()
                Button("advanced.codex_daemon_check".localized) { Task { await refresh() } }
                    .controlSize(.small)
                    .disabled(checking)
                Button("advanced.codex_daemon_restart_now".localized) {
                    Task {
                        await CodexDaemonService.shared.restartDaemon(reason: "Settings › Advanced")
                        await refresh()
                    }
                }
                .controlSize(.small)
                .disabled(checking || status?.isRunning != true)
                .help("advanced.codex_daemon_restart_now_help".localized)
            }
            Text(CodexDaemonService.shared.terminalsText).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        checking = true
        status = await CodexDaemonService.shared.currentStatus()
        checking = false
    }
}

// MARK: - Dead-login flags

struct DeadLoginFlagRow: Hashable {
    let id: UUID
    let name: String
    let provider: Profile.ProviderKind
}

enum DeadLoginFlags {
    /// Profiles whose stored login is flagged dead by its provider's service.
    static func rows(profiles: [Profile]) -> [DeadLoginFlagRow] {
        profiles.compactMap { profile in
            let dead: Bool
            switch profile.providerKind {
            case .claude: dead = ClaudeCodeSyncService.shared.isLoginMarkedDead(profile.id)
            case .codex: dead = CodexUsageService.shared.isLoginMarkedDead(profile.id)
            case .grok: dead = GrokUsageService.shared.isLoginMarkedDead(profile.id)
            }
            return dead ? DeadLoginFlagRow(id: profile.id, name: profile.name, provider: profile.providerKind) : nil
        }
    }

    /// Clears the flag through the service that owns it, so the next sweep
    /// re-checks the login and the notification is re-armed. Nothing about the
    /// credentials changes.
    static func forget(_ row: DeadLoginFlagRow) {
        switch row.provider {
        case .claude: ClaudeCodeSyncService.shared.markLoginRevived(row.id)
        case .codex: CodexUsageService.shared.markLoginRevived(row.id)
        case .grok: GrokUsageService.shared.forgetProfile(row.id)
        }
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }
}

struct DeadLoginFlagsCard: View {
    let rows: [DeadLoginFlagRow]
    let onForget: (DeadLoginFlagRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            if rows.isEmpty {
                Text("advanced.dead_none".localized).font(DesignTokens.Typography.body).foregroundColor(.secondary)
            } else {
                ForEach(rows, id: \.id) { row in
                    HStack(spacing: DesignTokens.Spacing.small) {
                        Text(DesignGlyph.dead).foregroundColor(DesignRole.blocking.color)
                        Text(row.name).font(DesignTokens.Typography.bodyMedium).lineLimit(1)
                        Text(ActiveVocabulary.providerName(row.provider)).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("advanced.dead_forget".localized) { onForget(row) }.controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
            Text("advanced.dead_note".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Stored settings (the registry)

struct StoredSettingsCard: View {
    @State private var expanded = false
    private let present = Set(SettingsKeyRegistry.present())
    private var unregistered: [String] { SettingsKeyRegistry.unregistered(in: present) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text("advanced.keys_counts".localized(with: SettingsKeyRegistry.live.count, SettingsKeyRegistry.all.count, present.count))
                .font(DesignTokens.Typography.body).foregroundColor(.secondary)
            if !unregistered.isEmpty {
                Text("advanced.keys_unregistered".localized(with: unregistered.joined(separator: ", ")))
                    .font(DesignTokens.Typography.caption).foregroundColor(DesignRole.caution.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsKeyRegistry.all.sorted { ($0.status.rawValue, $0.key) < ($1.status.rawValue, $1.key) }, id: \.key) { entry in
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Text(entry.key).font(DesignTokens.Typography.captionMono).lineLimit(1)
                            Text(present.contains(entry.key) ? DesignGlyph.ready : DesignGlyph.unmeasured)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(present.contains(entry.key) ? DesignRole.ready.color : .secondary)
                                .help(present.contains(entry.key) ? "advanced.keys_on_disk".localized : "advanced.keys_absent".localized)
                            Spacer()
                            Text(entry.ui ?? entry.status.rawValue).font(DesignTokens.Typography.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("advanced.keys_show".localized).font(DesignTokens.Typography.caption)
            }
        }
    }
}
