//
//  CodexUsageService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-07-05.
//

import Foundation

/// Manages OpenAI Codex CLI accounts: reads/writes `~/.codex/auth.json`, refreshes
/// OAuth tokens, and fetches session (5h) + weekly usage from the ChatGPT backend.
///
/// Mirrors the ClaudeCodeSyncService design so multiple Codex accounts work the same
/// way as multiple Claude accounts: each profile stores its own copy of the Codex
/// credentials (Keychain-backed `codexCredentialsJSON`, which is the full auth.json
/// content), and activating a profile writes that copy to `~/.codex/auth.json` so the
/// `codex` CLI switches accounts too.
///
/// Endpoints (verified against Codex CLI v0.4x behavior):
/// - Usage:   GET https://chatgpt.com/backend-api/wham/usage
///            Headers: `Authorization: Bearer <access_token>`,
///                     `ChatGPT-Account-Id: <tokens.account_id>`
///            Response: rate_limit.primary_window (5h: used_percent, reset_at) and
///                      rate_limit.secondary_window (weekly), plus email/plan_type.
/// - Refresh: POST https://auth.openai.com/oauth/token
///            JSON {client_id, grant_type: refresh_token, refresh_token, scope}
///            client_id is the Codex CLI's public app id (not a secret).
class CodexUsageService {
    static let shared = CodexUsageService()

    private static let oauthClientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let oauthTokenEndpoint = "https://auth.openai.com/oauth/token"
    private static let usageEndpoint = "https://chatgpt.com/backend-api/wham/usage"

    private var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")
    }

    private init() {}

    // MARK: - auth.json Access

    /// Reads the raw contents of ~/.codex/auth.json (nil if absent/unreadable).
    func readAuthFile() -> String? {
        guard let data = try? Data(contentsOf: authFileURL),
              let json = String(data: data, encoding: .utf8),
              !json.isEmpty,
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
            return nil
        }
        return json
    }

    /// Writes credentials JSON to ~/.codex/auth.json (0600, like the CLI's own file).
    private func writeAuthFile(_ json: String) throws {
        let dir = authFileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try json.write(to: authFileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFileURL.path)
    }

    // MARK: - Credential Introspection

    private func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func tokens(from json: String) -> [String: Any]? {
        parse(json)?["tokens"] as? [String: Any]
    }

    func extractAccessToken(from json: String) -> String? {
        tokens(from: json)?["access_token"] as? String
    }

    func extractRefreshToken(from json: String) -> String? {
        tokens(from: json)?["refresh_token"] as? String
    }

    func extractAccountId(from json: String) -> String? {
        tokens(from: json)?["account_id"] as? String
    }

    /// Access-token expiry, decoded from the JWT `exp` claim (no signature check —
    /// we only need the timestamp, the backend does the real verification).
    func extractTokenExpiry(from json: String) -> Date? {
        guard let accessToken = extractAccessToken(from: json),
              let exp = decodeJWTClaims(accessToken)?["exp"] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    /// The account email, from the id_token claims (for display only).
    func extractEmail(from json: String) -> String? {
        guard let idToken = tokens(from: json)?["id_token"] as? String else { return nil }
        return decodeJWTClaims(idToken)?["email"] as? String
    }

    func isTokenExpired(_ json: String) -> Bool {
        guard let expiry = extractTokenExpiry(from: json) else { return false }
        return Date() > expiry
    }

    /// Decodes the payload segment of a JWT (base64url) into its claims dictionary.
    private func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let segments = jwt.components(separatedBy: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Profile Sync Operations

    /// Copies the current ~/.codex/auth.json into a profile (one-time sync, same
    /// gesture as ClaudeCodeSyncService.syncToProfile).
    func syncToProfile(_ profileId: UUID) throws {
        guard let json = readAuthFile(), extractAccessToken(from: json) != nil else {
            throw CodexError.noCredentialsFound
        }

        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw CodexError.profileNotFound
        }

        profiles[index].codexCredentialsJSON = json
        profiles[index].codexEmail = extractEmail(from: json)
        profiles[index].codexAccountSyncedAt = Date()
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("Codex: Synced CLI credentials to profile \(profileId)")
    }

    /// Writes a profile's Codex credentials to ~/.codex/auth.json so the `codex` CLI
    /// switches to that account (the multi-account switching path).
    func applyProfileCredentials(_ profileId: UUID) throws {
        let profiles = ProfileStore.shared.loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileId }),
              let json = profile.codexCredentialsJSON else {
            throw CodexError.noProfileCredentials
        }
        try writeAuthFile(json)
        LoggingService.shared.log("Codex: Applied profile credentials to auth.json for \(profileId)")
    }

    /// Removes Codex credentials from a profile (does not touch auth.json).
    func removeFromProfile(_ profileId: UUID) throws {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw CodexError.profileNotFound
        }
        profiles[index].codexCredentialsJSON = nil
        profiles[index].codexEmail = nil
        profiles[index].codexAccountSyncedAt = nil
        profiles[index].claudeUsage = nil
        ProfileStore.shared.saveProfiles(profiles)
        LoggingService.shared.log("Codex: Removed credentials from profile \(profileId)")
    }

    /// Re-adopts auth.json into the profile IF it holds the SAME account and a
    /// later-expiring token (the `codex` CLI refreshes tokens silently in that file,
    /// exactly like Claude Code does in the Keychain). Safe to call when leaving a
    /// profile or before a fetch — the account_id match prevents cross-account mixups.
    /// Returns true if the stored credentials changed.
    @discardableResult
    func adoptAuthFileIfSameAccount(for profileId: UUID) -> Bool {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }),
              let stored = profiles[index].codexCredentialsJSON,
              let fileJSON = readAuthFile(),
              let fileAccount = extractAccountId(from: fileJSON),
              fileAccount == extractAccountId(from: stored),
              let fileExpiry = extractTokenExpiry(from: fileJSON),
              fileExpiry > (extractTokenExpiry(from: stored) ?? .distantPast) else {
            return false
        }

        profiles[index].codexCredentialsJSON = fileJSON
        profiles[index].codexAccountSyncedAt = Date()
        ProfileStore.shared.saveProfiles(profiles)
        LoggingService.shared.log("Codex: Adopted fresher token from auth.json (expires \(fileExpiry))")
        return true
    }

    // MARK: - OAuth Token Refresh

    /// Exchanges the refresh token for new tokens, like the CLI's silent refresh.
    /// Returns the full credentials JSON with the rotated tokens merged in.
    /// NOTE: OpenAI rotates the refresh token — the caller must persist the result
    /// everywhere the old one lived (profile store, and auth.json when this account
    /// is the one the CLI is logged into).
    func refreshOAuthToken(credentialsJSON: String) async throws -> String {
        guard var root = parse(credentialsJSON),
              var toks = root["tokens"] as? [String: Any],
              let refreshToken = toks["refresh_token"] as? String,
              let url = URL(string: Self.oauthTokenEndpoint) else {
            throw CodexError.invalidJSON
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.oauthClientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email"
        ])

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexError.tokenRefreshFailed(status: -1)
        }
        guard httpResponse.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let accessToken = payload["access_token"] as? String else {
            LoggingService.shared.log("Codex: OAuth token refresh failed (HTTP \(httpResponse.statusCode))")
            throw CodexError.tokenRefreshFailed(status: httpResponse.statusCode)
        }

        toks["access_token"] = accessToken
        if let rotated = payload["refresh_token"] as? String { toks["refresh_token"] = rotated }
        if let idToken = payload["id_token"] as? String { toks["id_token"] = idToken }
        root["tokens"] = toks
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let merged = try JSONSerialization.data(withJSONObject: root)
        guard let mergedString = String(data: merged, encoding: .utf8) else {
            throw CodexError.invalidJSON
        }
        LoggingService.shared.log("Codex: OAuth token refreshed (new expiry: \(extractTokenExpiry(from: mergedString)?.description ?? "unknown"))")
        return mergedString
    }

    /// Makes sure a profile's Codex access token is usable: adopt a fresher token
    /// from auth.json (same-account only), else redeem the refresh token. Persists
    /// changes to the profile store; a refreshed token is also written back to
    /// auth.json when that file holds the same account, so the CLI never ends up
    /// with a consumed refresh token. Returns true if stored credentials changed.
    func ensureFreshCredentials(for profileId: UUID) async -> Bool {
        var changed = adoptAuthFileIfSameAccount(for: profileId)

        guard let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
              let currentJSON = profile.codexCredentialsJSON else {
            return changed
        }

        let expiry = extractTokenExpiry(from: currentJSON) ?? .distantPast
        if expiry < Date().addingTimeInterval(120), extractRefreshToken(from: currentJSON) != nil {
            do {
                let refreshed = try await refreshOAuthToken(credentialsJSON: currentJSON)

                var profiles = ProfileStore.shared.loadProfiles()
                if let index = profiles.firstIndex(where: { $0.id == profileId }) {
                    profiles[index].codexCredentialsJSON = refreshed
                    profiles[index].codexAccountSyncedAt = Date()
                    ProfileStore.shared.saveProfiles(profiles)
                }

                // Keep the CLI working: its refresh token was just rotated away.
                if let fileJSON = readAuthFile(),
                   extractAccountId(from: fileJSON) == extractAccountId(from: refreshed) {
                    try? writeAuthFile(refreshed)
                }
                changed = true
            } catch {
                LoggingService.shared.logError("Codex: token refresh failed (non-fatal)", error: error)
            }
        }

        return changed
    }

    // MARK: - Usage Fetch

    /// Fetches session (5h) + weekly usage for a profile's Codex account and maps it
    /// onto the app's usage model (primary window → session, secondary → weekly).
    /// Self-heals a stale token first.
    func fetchUsage(for profileId: UUID) async throws -> ClaudeUsage {
        _ = await ensureFreshCredentials(for: profileId)

        guard let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
              let json = profile.codexCredentialsJSON,
              let accessToken = extractAccessToken(from: json) else {
            throw CodexError.noProfileCredentials
        }

        guard let url = URL(string: Self.usageEndpoint) else {
            throw CodexError.invalidJSON
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = extractAccountId(from: json) {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        request.setValue("ClaudeUsageWidget/\(version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        LoggingService.shared.logAPIRequest("codex/wham/usage")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(code: .apiInvalidResponse, message: "Invalid response from Codex usage endpoint", isRecoverable: true)
        }
        LoggingService.shared.logAPIResponse("codex/wham/usage", statusCode: httpResponse.statusCode)

        guard httpResponse.statusCode == 200 else {
            throw AppError(
                code: httpResponse.statusCode == 401 || httpResponse.statusCode == 403
                    ? .apiUnauthorized : .apiGenericError,
                message: "Codex usage fetch failed (status \(httpResponse.statusCode))",
                isRecoverable: true,
                recoverySuggestion: "Please re-sync your Codex account in Settings"
            )
        }

        return try parseUsageResponse(data)
    }

    /// Maps the wham/usage payload onto ClaudeUsage. Only the unified session/weekly
    /// windows are populated — Opus/Sonnet/Fable breakdowns are Claude-specific.
    private func parseUsageResponse(_ data: Data) throws -> ClaudeUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = json["rate_limit"] as? [String: Any] else {
            throw AppError(code: .apiParsingFailed, message: "Failed to parse Codex usage data", isRecoverable: false)
        }

        func window(_ key: String) -> (percent: Double, reset: Date)? {
            guard let w = rateLimit[key] as? [String: Any] else { return nil }
            let percent = (w["used_percent"] as? Double) ?? Double(w["used_percent"] as? Int ?? 0)
            guard let resetAt = w["reset_at"] as? TimeInterval else {
                return (percent, Date().addingTimeInterval((w["reset_after_seconds"] as? TimeInterval) ?? 0))
            }
            return (percent, Date(timeIntervalSince1970: resetAt))
        }

        let primary = window("primary_window")
        let secondary = window("secondary_window")

        let sessionPercentage = primary?.percent ?? 0
        let sessionResetTime = primary?.reset ?? Date().addingTimeInterval(5 * 3600)
        let weeklyPercentage = secondary?.percent ?? 0
        let weeklyResetTime = secondary?.reset ?? Date().addingTimeInterval(7 * 24 * 3600)

        LoggingService.shared.log("Codex: usage parsed - session: \(sessionPercentage)%, weekly: \(weeklyPercentage)% (plan: \(json["plan_type"] as? String ?? "?"))")

        return ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: sessionPercentage,
            sessionResetTime: sessionResetTime,
            weeklyTokensUsed: 0,
            weeklyLimit: Constants.weeklyLimit,
            weeklyPercentage: weeklyPercentage,
            weeklyResetTime: weeklyResetTime,
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
    }

    /// Plan type ("pro", "plus", …) from the last usage response is not cached;
    /// this reads the display info available offline from the stored credentials.
    func accountSummary(from json: String) -> (email: String?, accountId: String?) {
        (extractEmail(from: json), extractAccountId(from: json))
    }
}

// MARK: - CodexError

enum CodexError: LocalizedError {
    case noCredentialsFound
    case noProfileCredentials
    case profileNotFound
    case invalidJSON
    case tokenRefreshFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .noCredentialsFound:
            return "No Codex credentials found at ~/.codex/auth.json. Please log in with the codex CLI first."
        case .noProfileCredentials:
            return "This profile has no synced Codex account."
        case .profileNotFound:
            return "Profile not found."
        case .invalidJSON:
            return "Codex credentials are corrupted or invalid."
        case .tokenRefreshFailed(let status):
            return "Failed to refresh the Codex OAuth token (HTTP \(status)). Please re-sync your Codex account."
        }
    }
}
