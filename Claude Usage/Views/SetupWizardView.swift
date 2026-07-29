import SwiftUI
import AppKit

// MARK: - Setup Mode (CLI detect → confirm → done)

enum SetupMode {
    case loading
    case cliDetected(credentials: String)
    case cliNotFound
}

/// Setup wizard: detect Claude Code CLI credentials → confirm → done.
/// The legacy pasted-cookie claude.ai session-key flow has been removed.
struct SetupWizardView: View {
    @Environment(\.dismiss) var dismiss
    @State private var setupMode: SetupMode = .loading

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
                onStartTracking: { startTrackingWithCLI(credentials: credentials) }
            )

        case .cliNotFound:
            CLINotFoundSetupView(
                onRetry: { detectCLICredentials() },
                onDismiss: { dismiss() }
            )
        }
    }

    /// Detects CLI credentials and sets the appropriate setup mode
    private func detectCLICredentials() {
        setupMode = .loading
        Task {
            do {
                if let credentials = try ClaudeCodeSyncService.shared.readSystemCredentials(),
                   let _ = ClaudeCodeSyncService.shared.extractAccessToken(from: credentials),
                   !ClaudeCodeSyncService.shared.isTokenExpired(credentials) {
                    await MainActor.run {
                        setupMode = .cliDetected(credentials: credentials)
                    }
                    return
                }
            } catch { }

            await MainActor.run {
                setupMode = .cliNotFound
            }
        }
    }

    /// Saves CLI credentials to the active profile and dismisses the wizard
    private func startTrackingWithCLI(credentials: String) {
        guard let profileId = ProfileManager.shared.activeProfile?.id else {
            setupMode = .cliNotFound
            return
        }

        do {
            try ClaudeCodeSyncService.shared.syncToProfile(profileId)
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            dismiss()
        } catch {
            LoggingService.shared.logError("Failed to sync CLI credentials: \(error)")
            setupMode = .cliNotFound
        }
    }
}

// MARK: - CLI Detected Setup View
struct CLIDetectedSetupView: View {
    let credentials: String
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
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 80, height: 80)

                    Image(systemName: "terminal")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)
                }

                Text("Claude Code login required")
                    .font(.system(size: 24, weight: .bold))

                Text("Sign in with the Claude Code CLI (`claude login`), then return here to start tracking usage.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)

                Button(action: onRetry) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Check again")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

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
