//
//  Profile.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

/// Represents a complete isolated profile with all credentials and settings
struct Profile: Codable, Identifiable, Equatable {
    // MARK: - Identity
    let id: UUID
    var name: String

    // MARK: - Credentials (stored directly in profile)
    var claudeSessionKey: String?
    var organizationId: String?
    var apiSessionKey: String?
    var apiOrganizationId: String?
    var apiSessionKeyExpiry: Date?
    var cliCredentialsJSON: String?

    // MARK: - CLI Account Sync Metadata
    var hasCliAccount: Bool
    var cliAccountSyncedAt: Date?

    // MARK: - Codex Account (OpenAI Codex CLI)
    /// Full contents of the account's ~/.codex/auth.json — Keychain-only, never
    /// serialized to UserDefaults (excluded from CodingKeys, like the other secrets).
    var codexCredentialsJSON: String?
    /// Display metadata (non-secret, persisted normally).
    var codexEmail: String?
    var codexAccountSyncedAt: Date?

    // MARK: - Usage Data (Per-Profile)
    var claudeUsage: ClaudeUsage?
    var apiUsage: APIUsage?

    // MARK: - Appearance Settings (Per-Profile)
    var iconConfig: MenuBarIconConfiguration

    // MARK: - Behavior Settings (Per-Profile)
    var refreshInterval: TimeInterval
    var checkOverageLimitEnabled: Bool

    // MARK: - Notification Settings (Per-Profile)
    var notificationSettings: NotificationSettings

    // MARK: - Display Configuration
    var isSelectedForDisplay: Bool  // For multi-profile menu bar mode

    // MARK: - Auto-Switch Eligibility
    /// Whether this profile may be chosen as a TARGET by the session-limit
    /// auto-switch. Stored as an Optional so profiles saved before this field
    /// existed decode as nil — which means enabled. Use `isAutoSwitchEnabled`.
    var includeInAutoSwitch: Bool?

    /// Auto-switch eligibility with the nil-means-enabled default applied.
    var isAutoSwitchEnabled: Bool {
        get { includeInAutoSwitch ?? true }
        set { includeInAutoSwitch = newValue }
    }

    // MARK: - Metadata
    var createdAt: Date
    var lastUsedAt: Date

    // MARK: - Codable
    // Credentials (claudeSessionKey, apiSessionKey, cliCredentialsJSON) are deliberately
    // EXCLUDED from CodingKeys so they are never serialized into the UserDefaults JSON.
    // They live only in the Keychain and are re-hydrated by ProfileStore on load.
    // The excluded properties are all Optional, so the synthesized init(from:) defaults
    // them to nil — no custom decoder needed.
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case organizationId
        case apiOrganizationId
        case apiSessionKeyExpiry
        case hasCliAccount
        case cliAccountSyncedAt
        case codexEmail
        case codexAccountSyncedAt
        case claudeUsage
        case apiUsage
        case iconConfig
        case refreshInterval
        case checkOverageLimitEnabled
        case notificationSettings
        case isSelectedForDisplay
        case includeInAutoSwitch
        case createdAt
        case lastUsedAt
        // EXCLUDED (Keychain-only): claudeSessionKey, apiSessionKey, cliCredentialsJSON,
        // codexCredentialsJSON
    }

    init(
        id: UUID = UUID(),
        name: String,
        claudeSessionKey: String? = nil,
        organizationId: String? = nil,
        apiSessionKey: String? = nil,
        apiOrganizationId: String? = nil,
        apiSessionKeyExpiry: Date? = nil,
        cliCredentialsJSON: String? = nil,
        hasCliAccount: Bool = false,
        cliAccountSyncedAt: Date? = nil,
        codexCredentialsJSON: String? = nil,
        codexEmail: String? = nil,
        codexAccountSyncedAt: Date? = nil,
        claudeUsage: ClaudeUsage? = nil,
        apiUsage: APIUsage? = nil,
        iconConfig: MenuBarIconConfiguration = .default,
        refreshInterval: TimeInterval = 30.0,
        checkOverageLimitEnabled: Bool = true,
        notificationSettings: NotificationSettings = NotificationSettings(),
        isSelectedForDisplay: Bool = true,
        includeInAutoSwitch: Bool? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.claudeSessionKey = claudeSessionKey
        self.organizationId = organizationId
        self.apiSessionKey = apiSessionKey
        self.apiOrganizationId = apiOrganizationId
        self.apiSessionKeyExpiry = apiSessionKeyExpiry
        self.cliCredentialsJSON = cliCredentialsJSON
        self.hasCliAccount = hasCliAccount
        self.cliAccountSyncedAt = cliAccountSyncedAt
        self.codexCredentialsJSON = codexCredentialsJSON
        self.codexEmail = codexEmail
        self.codexAccountSyncedAt = codexAccountSyncedAt
        self.claudeUsage = claudeUsage
        self.apiUsage = apiUsage
        self.iconConfig = iconConfig
        self.refreshInterval = refreshInterval
        self.checkOverageLimitEnabled = checkOverageLimitEnabled
        self.notificationSettings = notificationSettings
        self.isSelectedForDisplay = isSelectedForDisplay
        self.includeInAutoSwitch = includeInAutoSwitch
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    // MARK: - Computed Properties
    var hasClaudeAI: Bool {
        claudeSessionKey != nil && organizationId != nil
    }

    var hasAPIConsole: Bool {
        apiSessionKey != nil && apiOrganizationId != nil
    }

    /// True if this profile holds a Codex CLI account
    var hasCodexAccount: Bool {
        codexCredentialsJSON != nil
    }

    /// True if this profile's ONLY usage source is a Codex account. Such profiles
    /// fetch from the ChatGPT backend instead of the Claude endpoints, and are never
    /// valid targets for the Claude session-limit auto-switch.
    var isCodexOnlyProfile: Bool {
        hasCodexAccount && !hasClaudeUsageSource
    }

    /// True if profile can fetch CLAUDE usage (claude.ai session, API Console, or CLI OAuth)
    var hasClaudeUsageSource: Bool {
        hasClaudeAI || hasAPIConsole || hasUsableCLIOAuth
    }

    /// True if profile has credentials that can fetch usage data (Claude.ai, CLI OAuth,
    /// API Console, or a Codex account)
    /// Note: System keychain fallback is handled in ClaudeAPIService.getAuthentication() during actual API calls
    var hasUsageCredentials: Bool {
        hasClaudeUsageSource || hasCodexAccount
    }

    /// True if profile has CLI OAuth credentials that are not expired
    var hasValidCLIOAuth: Bool {
        guard let cliJSON = cliCredentialsJSON else { return false }
        return !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON)
    }

    /// True if the CLI OAuth credentials can be used for a usage fetch: either the
    /// access token is still valid, or it carries a refresh token the app redeems
    /// itself before fetching (ClaudeCodeSyncService.ensureFreshCredentials). An
    /// expired-but-refreshable profile must NOT be treated as credential-less — that
    /// was the bug where usage silently froze until a manual CLI resync.
    var hasUsableCLIOAuth: Bool {
        guard let cliJSON = cliCredentialsJSON else { return false }
        return !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON)
            || ClaudeCodeSyncService.shared.extractRefreshToken(from: cliJSON) != nil
    }

    var hasAnyCredentials: Bool {
        hasClaudeAI || hasAPIConsole || cliCredentialsJSON != nil || codexCredentialsJSON != nil
    }

    // MARK: - Provider Exclusivity
    // A profile belongs to ONE provider: Claude (claude.ai / API Console / CLI) or
    // Codex. Settings hides the other provider's credential sections based on these.
    // They also consult the persisted metadata (hasCliAccount, organizationId,
    // codexEmail, …) so the answer is right even before the background Keychain
    // hydration fills in the credential fields.

    /// True if this profile carries anything Claude-side.
    var carriesClaudeAccount: Bool {
        hasClaudeAI || hasAPIConsole || cliCredentialsJSON != nil
            || hasCliAccount || organizationId != nil || apiOrganizationId != nil
    }

    /// True if this profile carries a Codex account.
    var carriesCodexAccount: Bool {
        hasCodexAccount || codexEmail != nil
    }
}

// MARK: - ProfileCredentials (for compatibility)
/// Simple struct for passing credentials around
struct ProfileCredentials {
    var claudeSessionKey: String?
    var organizationId: String?
    var apiSessionKey: String?
    var apiOrganizationId: String?
    var apiSessionKeyExpiry: Date?
    var cliCredentialsJSON: String?
    var codexCredentialsJSON: String?

    var hasClaudeAI: Bool {
        claudeSessionKey != nil && organizationId != nil
    }

    var hasAPIConsole: Bool {
        apiSessionKey != nil && apiOrganizationId != nil
    }

    var hasCLI: Bool {
        cliCredentialsJSON != nil
    }
}
