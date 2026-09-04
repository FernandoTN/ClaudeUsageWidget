//
//  CodexAccountSheets.swift
//  Claude Usage
//
//  The two ways an extra Codex account gets in without revoking the one that is
//  already applied to the default home: run `codex login` under a fresh
//  CODEX_HOME, or import a home the user logged into themselves.
//

import AppKit
import SwiftUI

/// Adds a Codex account by running `codex login` under a fresh, isolated
/// CODEX_HOME, then importing the result — so the account currently applied to
/// `~/.codex` is never logged out. The default home is neither read nor written
/// anywhere in this flow.
struct CodexLoginSheet: View {
    /// Offered as a destination only when it holds no Codex account yet.
    let viewedProfile: Profile?
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var useViewedProfile = false
    @State private var isRunning = false
    @State private var problem: String?
    @State private var run: CodexLoginRun?

    /// A profile with no Codex account is a legitimate destination; one that
    /// already has an account is not (a profile holds exactly one).
    private var reusableProfile: Profile? {
        guard let viewedProfile, !viewedProfile.carriesCodexAccount else { return nil }
        return viewedProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("codex.login.title".localized)
                .font(DesignTokens.Typography.sectionTitle)
            Text("codex.login.subtitle".localized)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isRunning {
                HStack(spacing: DesignTokens.Spacing.small) {
                    ProgressView().scaleEffect(0.8)
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                        Text("codex.login.waiting".localized)
                            .font(DesignTokens.Typography.body)
                        Text("codex.login.waiting_detail".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    Text("codex.login.label_field".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                    TextField("work", text: $label)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(startLogin)
                    Text("codex.login.label_hint".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                }

                if let reusableProfile {
                    Toggle(isOn: $useViewedProfile) {
                        Text("codex.login.use_this_profile".localized)
                            .font(DesignTokens.Typography.caption)
                    }
                    .toggleStyle(.checkbox)
                    .help(reusableProfile.name)
                }
            }

            if let problem {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(problem)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(DesignTokens.Spacing.iconText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .cornerRadius(DesignTokens.Radius.small)
            }

            HStack {
                Spacer()
                Button("common.cancel".localized) {
                    run?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if !isRunning {
                    Button("codex.login.start".localized, action: startLogin)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(CodexLoginService.slug(for: label) == nil)
                }
            }
        }
        .padding()
        .frame(width: 520)
    }

    private func startLogin() {
        guard !isRunning else { return }
        guard let slug = CodexLoginService.slug(for: label) else {
            problem = CodexLoginError.invalidLabel.localizedDescription
            return
        }
        problem = nil
        isRunning = true

        // The preparation blocks (it creates a directory and may spawn a login
        // shell to find the binary); the completion arrives on the main queue.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let started = try CodexLoginService.shared.startLogin(slug: slug) { result, logTail in
                    finishLogin(result, logTail: logTail)
                }
                DispatchQueue.main.async { run = started }
            } catch {
                DispatchQueue.main.async {
                    isRunning = false
                    problem = error.localizedDescription
                }
            }
        }
    }

    private func finishLogin(_ result: Result<URL, CodexLoginError>, logTail: String) {
        isRunning = false
        run = nil

        switch result {
        case .failure(let error):
            var message = error.localizedDescription
            if !logTail.isEmpty { message += "\n\n" + logTail }
            problem = message
            LoggingService.shared.logError("CodexAccountView: isolated-home login failed - \(error.localizedDescription)")

        case .success(let home):
            // Resolve the duplicate guard BEFORE creating anything, so a login
            // for an account we already track cannot leave an empty profile
            // behind. `UUID()` excludes nothing, so any holder matches.
            if let holder = CodexUsageService.shared.duplicateHolderName(forHome: home, target: UUID()) {
                problem = CodexError.accountAlreadySynced(profileName: holder).localizedDescription
                return
            }

            let destination: UUID
            if useViewedProfile, let reusableProfile {
                destination = reusableProfile.id
            } else {
                destination = ProfileManager.shared.createProfile(name: label).id
            }

            do {
                try CodexUsageService.shared.importFromCodexHome(home, into: destination)
                onFinished()
                dismiss()
            } catch {
                problem = error.localizedDescription
                LoggingService.shared.logError("CodexAccountView: import after login failed - \(error.localizedDescription)")
            }
        }
    }
}

/// Picks a CODEX_HOME, shows the account it holds (email + account-id suffix —
/// no token is ever rendered), and imports it into the viewed profile.
///
/// Why this exists: `codex login` revokes whatever credentials already sit in
/// the home it runs in, so a second `codex login` in the default `~/.codex`
/// kills the account the widget applied there. Each extra account is logged in
/// under its own home and brought here instead.
struct CodexHomeImportSheet: View {
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
