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

/// Adds a Codex account by running the Codex CLI's login under a fresh,
/// isolated CODEX_HOME, then importing the result — so the account currently
/// applied to `~/.codex` is never logged out. The default home is neither read
/// nor written anywhere in this flow.
///
/// The default flow is DEVICE CODE (`codex login --device-auth`), which opens
/// no browser at all: the CLI prints a link and a one-time code, both shown
/// here with a Copy button, and the user finishes the sign-in in whatever
/// browser session already holds the account they want. The browser flow is
/// still one toggle away, and even then the link it prints is shown — its
/// automatic browser opening lands in whichever session that browser holds,
/// which is exactly what goes wrong when adding a SECOND account.
struct CodexLoginSheet: View {
    /// The profile whose Codex page the button was pressed on. It is the
    /// DESTINATION whenever it has no Codex account or its login is dead —
    /// which is the common case, because that is exactly when a user goes
    /// looking for this button.
    let viewedProfile: Profile?
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var isRunning = false
    @State private var problem: String?
    @State private var run: CodexLoginRun?
    /// Off by default: device code is the flow that lets the user choose the
    /// browser session.
    @State private var useBrowserFlow = false
    /// The link and one-time code, as the CLI reveals them.
    @State private var instructions = CodexLoginService.LoginInstructions()
    /// Which field was just copied, for the momentary confirmation.
    @State private var copied: CopiedField?

    /// Set once the login has landed in a profile that can be made the CLI's
    /// account right here. Nil for every other outcome, so the sheet closes as
    /// it always did.
    @State private var signedInProfile: Profile?

    private enum CopiedField: Equatable { case link, code }

    private var mode: CodexLoginService.Mode { useBrowserFlow ? .browser : .deviceCode }

    /// True when the viewed profile's stored Codex login has been flagged dead.
    private var viewedLoginIsDead: Bool {
        guard let viewedProfile else { return false }
        return CodexUsageService.shared.isLoginMarkedDead(viewedProfile.id)
    }

    /// The viewed profile, when this login belongs to it.
    private var destinationProfile: Profile? {
        guard let viewedProfile else { return nil }
        let target = CodexLoginService.loginTarget(
            carriesCodexAccount: viewedProfile.carriesCodexAccount,
            loginIsDead: viewedLoginIsDead
        )
        return target == .viewedProfile ? viewedProfile : nil
    }

    /// The isolated home this login will run in. For the viewed profile it is
    /// the one the profile already remembers, else one named after the profile;
    /// for a new profile it comes from the typed label.
    private var loginHome: URL? {
        if let destinationProfile {
            return CodexLoginService.loginHome(
                existingHomePath: destinationProfile.codexHomePath,
                profileName: destinationProfile.name
            )
        }
        return CodexLoginService.slug(for: label).map(CodexLoginService.home(forSlug:))
    }

    var body: some View {
        if let signedInProfile {
            CodexActivationOffer(profile: signedInProfile) { dismiss() }
        } else {
            loginForm
        }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("codex.login.title".localized)
                .font(DesignTokens.Typography.sectionTitle)
            Text((useBrowserFlow ? "codex.login.subtitle_browser" : "codex.login.subtitle_device").localized)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isRunning {
                runningSection
            } else if let destinationProfile {
                // No label to type: the destination is decided, and the folder
                // is named after it.
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    HStack(spacing: DesignTokens.Spacing.small) {
                        Image(systemName: viewedLoginIsDead ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                            .foregroundColor(.accentColor)
                        Text((viewedLoginIsDead ? "codex.login.replaces_dead" : "codex.login.fills_empty")
                            .localized(with: destinationProfile.name))
                            .font(DesignTokens.Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let loginHome {
                        Text("codex.login.home_path".localized(with: loginHome.path))
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                    }
                    if viewedLoginIsDead {
                        Text("codex.login.activate_after".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                // The viewed profile holds a working account, so this login
                // needs a profile of its own.
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !isRunning {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    Toggle("codex.login.mode_browser".localized, isOn: $useBrowserFlow)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text("codex.login.mode_hint".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                        .disabled(loginHome == nil)
                }
            }
        }
        .padding()
        .frame(width: 520)
    }

    // MARK: - While the CLI is running

    @ViewBuilder
    private var runningSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            HStack(spacing: DesignTokens.Spacing.small) {
                ProgressView().scaleEffect(0.8)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    Text((mode == .deviceCode ? "codex.login.waiting_device" : "codex.login.waiting").localized)
                        .font(DesignTokens.Typography.body)
                    Text((mode == .deviceCode
                          ? "codex.login.waiting_device_detail"
                          : "codex.login.waiting_detail").localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if instructions.isEmpty {
                Text("codex.login.preparing".localized)
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)
            } else {
                instructionCard
            }
        }
    }

    /// The link and the code, each selectable and each with a Copy button —
    /// the whole point of the feature: nothing here depends on the default
    /// browser having the right session.
    @ViewBuilder
    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            if let url = instructions.verificationURL {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    Text((mode == .deviceCode ? "codex.login.step_link" : "codex.login.browser_link").localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.iconText) {
                        Text(url)
                            .font(DesignTokens.Typography.monospaced)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("codex.login.copy_link".localized) { copy(url, as: .link) }
                            .controlSize(.small)
                        Button("codex.login.open_link".localized) {
                            if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                        }
                        .controlSize(.small)
                    }
                    if copied == .link {
                        Text("codex.login.copied".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.green)
                    }
                }
            }

            if let code = instructions.userCode {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    Text("codex.login.step_code".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .center, spacing: DesignTokens.Spacing.iconText) {
                        Text(code)
                            .font(.system(.title2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("codex.login.copy_code".localized) { copy(code, as: .code) }
                            .controlSize(.small)
                    }
                    if copied == .code {
                        Text("codex.login.copied".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.iconText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(DesignTokens.Radius.small)
    }

    private func copy(_ value: String, as field: CopiedField) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = field
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copied == field { copied = nil }
        }
    }

    // MARK: - Running the login

    private func startLogin() {
        guard !isRunning else { return }
        guard let home = loginHome else {
            problem = CodexLoginError.invalidLabel.localizedDescription
            return
        }
        problem = nil
        instructions = CodexLoginService.LoginInstructions()
        copied = nil
        isRunning = true

        // The preparation blocks (it creates a directory and may spawn a login
        // shell to find the binary); both callbacks arrive on the main queue.
        let chosenMode = mode
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let started = try CodexLoginService.shared.startLogin(
                    home: home,
                    mode: chosenMode,
                    onInstructions: { revealed in instructions = revealed }
                ) { result, logTail in
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
        instructions = CodexLoginService.LoginInstructions()

        switch result {
        case .failure(let error):
            // `logTail` is already redacted of the link and the code — a live
            // one-time credential never leaves the fields above.
            var message = error.localizedDescription
            if !logTail.isEmpty { message += "\n\n" + logTail }
            problem = message
            LoggingService.shared.logError("CodexAccountView: isolated-home login failed - \(error.localizedDescription)")

        case .success(let home):
            // Resolve the duplicate guard BEFORE creating anything, so a login
            // for an account another profile already holds cannot leave an
            // empty profile behind. The destination is excluded from the check:
            // re-logging the SAME account into the profile that holds it is the
            // repair, not a duplicate.
            let destinationId = destinationProfile?.id
            if let holder = CodexUsageService.shared.duplicateHolderName(
                forHome: home,
                target: destinationId ?? UUID()
            ) {
                problem = CodexError.accountAlreadySynced(profileName: holder).localizedDescription
                return
            }

            let destination = destinationId ?? ProfileManager.shared.createProfile(name: label).id

            do {
                try CodexUsageService.shared.importFromCodexHome(home, into: destination)
                onFinished()
                // The login is stored, but the `codex` CLI is still signed in as
                // whoever owns auth.json — repairing a dead login leaves exactly
                // that gap. Offer to close it here instead of sending the user
                // back to the menu to click the profile they are already on.
                if let offer = CodexActivationOffer.destination(destination) {
                    signedInProfile = offer
                } else {
                    dismiss()
                }
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
    /// Set once the import has landed in a profile that can be made the CLI's
    /// account right here (see `CodexActivationOffer`).
    @State private var signedInProfile: Profile?
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
        if let signedInProfile {
            CodexActivationOffer(profile: signedInProfile) { dismiss() }
        } else {
            importForm
        }
    }

    private var importForm: some View {
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
                    // Same gap the login flow leaves: the account is stored but
                    // ~/.codex/auth.json still holds somebody else's login.
                    if let offer = CodexActivationOffer.destination(target) {
                        signedInProfile = offer
                    } else {
                        dismiss()
                    }
                case .failure(let error):
                    problem = error.localizedDescription
                    LoggingService.shared.logError("CodexAccountView: import failed - \(error.localizedDescription)")
                }
            }
        }
    }
}

/// The last step of an in-app Codex repair: the account is signed in and stored
/// on the profile, but `~/.codex/auth.json` still holds whoever owned it before,
/// so the `codex` CLI has not moved.
///
/// Why it is offered here rather than left to the menu: the profile a repair
/// happens on is the FOCUSED one (both sheets operate on `activeProfile`), and
/// clicking a focused profile used to be answered "already active" with nothing
/// applied — the user could not finish the switch at all. `ProfileManager`
/// now completes it, and this button is the same call from where the repair
/// already is. Declining is a normal outcome: the stored login is safe either
/// way, and the hint repeats how to apply it later.
struct CodexActivationOffer: View {
    let profile: Profile
    /// Called when the user is done, whichever button they pressed.
    let onDone: () -> Void

    @State private var isActivating = false
    @State private var problem: String?

    /// The profile to offer activation for, or nil when there is nothing to
    /// offer: activation is only worth a button when the destination is the
    /// FOCUSED profile (a login sent to a brand-new profile is not) and it does
    /// not already own the Codex login.
    @MainActor
    static func destination(_ profileId: UUID) -> Profile? {
        let manager = ProfileManager.shared
        guard manager.activeProfile?.id == profileId,
              manager.activeCodexProfileId != profileId else { return nil }
        return manager.profiles.first(where: { $0.id == profileId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("codex.activate.title".localized)
                .font(DesignTokens.Typography.sectionTitle)

            HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text("codex.activate.prompt".localized(with: profile.name))
                    .font(DesignTokens.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The switch's cost and both sides, as every switch confirmation
            // states them (design round 1): the current owner keeps its login
            // until this button is pressed.
            Text(DashboardFormatting.switchCost(.codex) + " " + (ProfileManager.shared.activeCodexProfileId
                .flatMap { id in ProfileManager.shared.profiles.first { $0.id == id }?.name }
                .map { "codex.activate.from_owner".localized(with: $0) } ?? ""))
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The same sentence the sheet shows before the login, kept for the
            // Not-now path: declining here is not a dead end.
            Text("codex.login.activate_after".localized)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(problem)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DesignTokens.Spacing.iconText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .cornerRadius(DesignTokens.Radius.small)
            }

            HStack(spacing: DesignTokens.Spacing.small) {
                Spacer()
                if isActivating {
                    ProgressView().scaleEffect(0.6)
                }
                Button("codex.activate.later".localized, action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isActivating)
                Button("codex.activate.now".localized, action: activate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isActivating)
            }
        }
        .padding()
        .frame(width: 520)
    }

    private func activate() {
        guard !isActivating else { return }
        isActivating = true
        problem = nil
        Task {
            let landed = await ProfileManager.shared.activateProfile(profile.id, userInitiated: true)
            isActivating = false
            if landed {
                onDone()
            } else {
                // The liveness gate refused the fresh login, or another switch
                // held the semaphore. Say so rather than dismissing on a switch
                // that did not happen — the stored login is untouched either way.
                problem = "codex.activate.failed".localized
                LoggingService.shared.log("CodexActivationOffer: activation of '\(profile.name)' did not land")
            }
        }
    }
}
