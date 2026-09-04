import SwiftUI
import AppKit

// MARK: - Setup Mode (CLI detect → confirm → done)

enum SetupMode {
    case loading
    case cliDetected(credentials: String)
    case cliNotFound
}

/// A non-Claude provider login found on disk while the wizard was detecting.
/// The app auto-imports these into their own profiles, but the wizard used to
/// say nothing about them at all — so a Codex-only install was told "Claude
/// Code login required" with no sign its account had been recognised.
struct DetectedProviderAccount: Identifiable, Equatable {
    let id: String
    let providerName: String
    let account: String?
    let symbolName: String
}

/// Setup wizard: detect Claude Code CLI credentials → confirm → done.
/// The legacy pasted-cookie claude.ai session-key flow has been removed.
struct SetupWizardView: View {
    @Environment(\.dismiss) var dismiss
    @State private var setupMode: SetupMode = .loading
    @State private var otherProviders: [DetectedProviderAccount] = []

    var body: some View {
        switch setupMode {
        case .loading:
            VStack(spacing: 16) {
                ProgressView()
                Text("setup.cli_detecting".localized)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(width: 580, height: 680)
            .onAppear { detectCLICredentials() }

        case .cliDetected(let credentials):
            CLIDetectedSetupView(
                credentials: credentials,
                otherProviders: otherProviders,
                onStartTracking: { startTrackingWithCLI(credentials: credentials) }
            )

        case .cliNotFound:
            CLINotFoundSetupView(
                otherProviders: otherProviders,
                onRetry: { detectCLICredentials() },
                onDismiss: { dismiss() }
            )
        }
    }

    /// Detects CLI credentials and sets the appropriate setup mode
    private func detectCLICredentials() {
        setupMode = .loading
        Task {
            let others = Self.detectOtherProviderLogins()
            do {
                if let credentials = try ClaudeCodeSyncService.shared.readSystemCredentials(),
                   let _ = ClaudeCodeSyncService.shared.extractAccessToken(from: credentials),
                   !ClaudeCodeSyncService.shared.isTokenExpired(credentials) {
                    await MainActor.run {
                        otherProviders = others
                        setupMode = .cliDetected(credentials: credentials)
                    }
                    return
                }
            } catch { }

            await MainActor.run {
                otherProviders = others
                setupMode = .cliNotFound
            }
        }
    }

    /// Codex and Grok CLI logins present on disk. File reads only — the
    /// Keychain is never touched here.
    static func detectOtherProviderLogins() -> [DetectedProviderAccount] {
        var found: [DetectedProviderAccount] = []
        let codex = CodexUsageService.shared
        if let json = codex.readAuthFile(), codex.extractAccessToken(from: json) != nil {
            found.append(DetectedProviderAccount(
                id: "codex",
                providerName: "Codex",
                account: codex.extractEmail(from: json),
                symbolName: "chevron.left.forwardslash.chevron.right"
            ))
        }
        let grok = GrokUsageService.shared
        if let json = grok.readAuthFile(), grok.extractAccessToken(from: json) != nil {
            found.append(DetectedProviderAccount(
                id: "grok",
                providerName: "Grok",
                account: grok.extractEmail(from: json),
                symbolName: "bolt.fill"
            ))
        }
        return found
    }

    /// Saves CLI credentials to the active profile and dismisses the wizard
    private func startTrackingWithCLI(credentials: String) {
        guard let profileId = ProfileManager.shared.activeProfile?.id else {
            setupMode = .cliNotFound
            return
        }

        do {
            try ClaudeCodeSyncService.shared.syncToProfile(profileId)
            // The profile now holds a copy of the Claude Code CLI's current
            // login, so it OWNS the shared login from here on — same claim the
            // CLI Account page makes after its Sync. Without it the Claude
            // pointer stayed behind and the first switch re-adopted the login
            // into whichever profile the pointer named (focus-authority list #28).
            ProfileManager.shared.claimActiveClaudeOwnership(profileId)
            // Learn WHOSE login was just synced (the CLI Account page does the
            // same after its Sync) so adoption stays account-matched from the
            // first sweep instead of waiting for the sweep-end identity pass.
            Task { await ClaudeCodeSyncService.shared.stampAccountIdentity(for: profileId, force: true) }
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            dismiss()
        } catch {
            LoggingService.shared.logError("Failed to sync CLI credentials: \(error)")
            setupMode = .cliNotFound
        }
    }
}

// MARK: - Detected Provider Row

/// One "we found this account" line. Used for the non-Claude providers, whose
/// profiles the app imports on its own.
struct DetectedProviderRow: View {
    let provider: DetectedProviderAccount

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.green)
            Image(systemName: provider.symbolName)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(provider.providerName) account detected")
                    .font(.system(size: 13, weight: .medium))
                if let account = provider.account {
                    Text(account)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

// MARK: - CLI Detected Setup View
struct CLIDetectedSetupView: View {
    let credentials: String
    var otherProviders: [DetectedProviderAccount] = []
    let onStartTracking: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Terminal icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 80, height: 80)

                    Image(systemName: "terminal.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                }

                // Title
                Text("setup.cli_detected.title".localized)
                    .font(.system(size: 24, weight: .bold))

                // Description
                Text("setup.cli_detected.description".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)

                // Other provider logins found on disk — imported as their own
                // profiles, shown here so the user knows they were seen.
                if !otherProviders.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(otherProviders) { DetectedProviderRow(provider: $0) }
                    }
                    .padding(.horizontal, 60)
                }

                // Start tracking button
                Button(action: onStartTracking) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill")
                        Text("setup.cli_detected.start".localized)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()
        }
        .frame(width: 580, height: 680)
    }
}

// MARK: - CLI Not Found Setup View
struct CLINotFoundSetupView: View {
    var otherProviders: [DetectedProviderAccount] = []
    let onRetry: () -> Void
    let onDismiss: () -> Void

    /// A Codex- or Grok-only install is set up, not unfinished: the app has
    /// imported those logins as their own profiles and can track them without
    /// any Claude credential. Saying "Claude Code login required" and nothing
    /// else was the whole H9 complaint.
    private var hasOtherProvider: Bool { !otherProviders.isEmpty }

    private var retryLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise")
            Text(hasOtherProvider ? "Check again for Claude Code" : "Check again")
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill((hasOtherProvider ? Color.green : Color.orange).opacity(0.12))
                        .frame(width: 80, height: 80)

                    Image(systemName: hasOtherProvider ? "checkmark.circle" : "terminal")
                        .font(.system(size: 36))
                        .foregroundColor(hasOtherProvider ? .green : .orange)
                }

                Text(hasOtherProvider ? "You're ready to track usage" : "Claude Code login required")
                    .font(.system(size: 24, weight: .bold))

                Text(hasOtherProvider
                     ? "No Claude Code login was found, but these accounts were. Add Claude later with `claude login`."
                     : "Sign in with the Claude Code CLI (`claude login`), then return here to start tracking usage.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)

                if hasOtherProvider {
                    VStack(spacing: 8) {
                        ForEach(otherProviders) { DetectedProviderRow(provider: $0) }
                    }
                    .padding(.horizontal, 60)

                    Button(action: onDismiss) {
                        HStack(spacing: 8) {
                            Image(systemName: "chart.bar.fill")
                            Text("setup.cli_detected.start".localized)
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                // Only one prominent call to action: with other accounts
                // detected, "start tracking" above is it and this drops to
                // a plain bordered button.
                if hasOtherProvider {
                    Button(action: onRetry) { retryLabel }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                } else {
                    Button(action: onRetry) { retryLabel }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }

                Button(action: onDismiss) {
                    Text("common.cancel".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(width: 580, height: 680)
    }
}

#Preview {
    SetupWizardView()
}
