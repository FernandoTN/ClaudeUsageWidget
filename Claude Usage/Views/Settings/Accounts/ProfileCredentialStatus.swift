//
//  ProfileCredentialStatus.swift
//  Claude Usage
//
//  Stored-login health for the roster and the Login tab: the per-profile status memo
//  (`ProfileCredentialStatusCache`), `StoredTokenStatus` and its badge.
//

import SwiftUI

// MARK: - Credential status memo

/// Main-actor memo for per-row credential status used by settings rows and the
/// popover switcher. Avoids re-parsing credentials JSON + reformatting dates on
/// every SwiftUI body evaluation during a publish storm.
///
/// Invalidated wholesale on `.credentialsChanged` and profile add/remove; also
/// keyed by a cheap credentials fingerprint so a rotated token refreshes without
/// an explicit notification.
@MainActor
enum ProfileCredentialStatusCache {
    private struct Entry {
        let fingerprint: Int
        let claudeStatus: StoredTokenStatus?
        let codexStatus: StoredTokenStatus?
        let createdAtFormatted: String
        let profileInfo: String
        let hasDeadLogin: Bool
    }

    private static var cache: [UUID: Entry] = [:]
    private static var observerInstalled = false

    static func invalidateAll() {
        cache.removeAll()
    }

    /// True once Keychain warm has finished (ready or failed). While loading,
    /// nil credentials mean "not hydrated yet" and must not be memoized.
    private static var isCredentialHydrationSettled: Bool {
        ProfileStore.shared.credentialHydrationState != .loading
    }

    private static func ensureObserver() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                invalidateAll()
            }
        }
    }

    /// Constant-cost fingerprint: the store's credential REVISION (bumped on
    /// every cache mutation — rotation-proof, unlike hashing or sampling the
    /// multi-KB blobs) + identity/dead flags.
    private static func fingerprint(for profile: Profile) -> Int {
        var hasher = Hasher()
        hasher.combine(ProfileStore.shared.credentialRevision(for: profile.id))
        hasher.combine(profile.createdAt)
        hasher.combine(profile.hasCliAccount)
        hasher.combine(profile.hasCodexAccount)
        hasher.combine(profile.codexEmail)
        hasher.combine(ClaudeCodeSyncService.shared.isLoginMarkedDead(profile.id))
        hasher.combine(CodexUsageService.shared.isLoginMarkedDead(profile.id))
        return hasher.finalize()
    }

    private static func entry(for profile: Profile) -> Entry {
        ensureObserver()
        let fp = fingerprint(for: profile)
        if let existing = cache[profile.id], existing.fingerprint == fp {
            return existing
        }

        let claudeDead = ClaudeCodeSyncService.shared.isLoginMarkedDead(profile.id)
        let codexDead = CodexUsageService.shared.isLoginMarkedDead(profile.id)

        let claudeStatus: StoredTokenStatus?
        if let json = profile.cliCredentialsJSON {
            if claudeDead {
                claudeStatus = .expired
            } else {
                // extractTokenExpiry / extractRefreshToken share an internal parse helper
                claudeStatus = StoredTokenStatus(
                    expiry: ClaudeCodeSyncService.shared.extractTokenExpiry(from: json),
                    hasRefreshToken: ClaudeCodeSyncService.shared.extractRefreshToken(from: json) != nil
                )
            }
        } else {
            claudeStatus = nil
        }

        let codexStatus: StoredTokenStatus?
        if let json = profile.codexCredentialsJSON {
            if codexDead {
                codexStatus = .expired
            } else {
                codexStatus = StoredTokenStatus(
                    expiry: CodexUsageService.shared.extractTokenExpiry(from: json),
                    hasRefreshToken: CodexUsageService.shared.extractRefreshToken(from: json) != nil
                )
            }
        } else {
            codexStatus = nil
        }

        let createdAtFormatted = profile.createdAt.formatted(date: .abbreviated, time: .omitted)

        var parts: [String] = []
        if profile.hasCliAccount {
            parts.append("profiles.cli_synced".localized)
        }
        if profile.hasCodexAccount {
            parts.append(profile.codexEmail.map { "Codex: \($0)" } ?? "profiles.codex_synced".localized)
        }
        parts.append("\("profiles.created".localized) \(createdAtFormatted)")
        let profileInfo = parts.joined(separator: " • ")

        var hasDeadLogin = false
        if profile.cliCredentialsJSON != nil {
            if claudeDead { hasDeadLogin = true }
            else if case .expired = claudeStatus { hasDeadLogin = true }
        }
        if !hasDeadLogin, profile.codexCredentialsJSON != nil {
            if codexDead { hasDeadLogin = true }
            else if case .expired = codexStatus { hasDeadLogin = true }
        }

        let built = Entry(
            fingerprint: fp,
            claudeStatus: claudeStatus,
            codexStatus: codexStatus,
            createdAtFormatted: createdAtFormatted,
            profileInfo: profileInfo,
            hasDeadLogin: hasDeadLogin
        )
        cache[profile.id] = built
        return built
    }

    static func claudeTokenStatus(for profile: Profile) -> StoredTokenStatus? {
        // While hydrating, do not negative-cache unhydrated (nil) credentials.
        guard isCredentialHydrationSettled else { return nil }
        return entry(for: profile).claudeStatus
    }

    static func codexTokenStatus(for profile: Profile) -> StoredTokenStatus? {
        guard isCredentialHydrationSettled else { return nil }
        return entry(for: profile).codexStatus
    }

    static func profileInfo(for profile: Profile) -> String {
        // profileInfo is mostly non-secret flags + created date; still avoid
        // memoizing while credentials are mid-hydrate so a later fingerprint
        // change is not racing a half-built entry.
        guard isCredentialHydrationSettled else {
            let created = profile.createdAt.formatted(date: .abbreviated, time: .omitted)
            return "\("profiles.created".localized) \(created)"
        }
        return entry(for: profile).profileInfo
    }

    static func hasDeadLogin(_ profile: Profile) -> Bool {
        // Unhydrated profiles are not dead — credentials simply have not loaded.
        guard isCredentialHydrationSettled else { return false }
        return entry(for: profile).hasDeadLogin
    }
}

// MARK: - Stored login health

/// Lifecycle state of a stored OAuth login. An expired access token with a live
/// refresh token on file is NOT a problem — the app redeems it on the next fetch —
/// so it renders as "renews automatically", not as an error.
enum StoredTokenStatus {
    case valid(until: Date)
    case autoRenews
    case expired

    init(expiry: Date?, hasRefreshToken: Bool) {
        if let expiry, expiry > Date() {
            self = .valid(until: expiry)
        } else if hasRefreshToken {
            self = .autoRenews
        } else {
            self = .expired
        }
    }

    private static let relativeFormatter = RelativeDateTimeFormatter()

    var color: Color {
        switch self {
        case .valid: return .green
        // Neutral, not a warning: an expired access token with a live refresh
        // token is the NORMAL resting state of every inactive profile (access
        // tokens are short-lived) — orange here would paint a healthy 5-account
        // list as four problems. Orange/red are reserved for real trouble.
        case .autoRenews: return .secondary
        case .expired: return .red
        }
    }

    var text: String {
        switch self {
        case .valid(let until):
            let relative = Self.relativeFormatter.localizedString(for: until, relativeTo: Date())
            return String(format: "profiles.token_valid".localized, relative)
        case .autoRenews:
            return "profiles.token_auto_renews".localized
        case .expired:
            return "profiles.token_expired".localized
        }
    }
}

struct CredentialStatusBadge: View {
    let provider: String
    let status: StoredTokenStatus

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(status.color)
                .frame(width: 5, height: 5)

            Text("\(provider): \(status.text)")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(status.color.opacity(0.12))
        .cornerRadius(4)
    }
}
