import Foundation

/// Fetches usage for xAI Grok CLI accounts (SuperGrok subscriptions) — the
/// third provider, mirroring CodexUsageService's design:
///
/// - **Credentials**: a full copy of `~/.grok/auth.json` (Keychain key
///   `grok-creds`). The file is a dict keyed by `"<issuer>::<client_id>"`
///   whose entry holds the OIDC login: `key` (JWT access token, ~6h life),
///   rotating `refresh_token`, ISO-8601 `expires_at`, plus identity
///   (`user_id`, `email`, `team_id`) and the refresh coordinates
///   (`oidc_issuer`, `oidc_client_id`).
/// - **Usage**: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
///   (Bearer + `x-grok-client-mode` — the exact call the CLI's billing
///   extension makes, verified live). The response's `config` carries a
///   `currentPeriod` (weekly for SuperGrok) and `creditUsagePercent` /
///   `includedUsed` / `monthlyLimit` (omitted while zero). It maps into
///   ClaudeUsage's WEEKLY window so every existing rendering/ranking path
///   works unchanged; Grok has no 5-hour session concept, so the session
///   window reports 0%.
/// - **Refresh**: standard OAuth `POST https://auth.x.ai/oauth2/token`
///   (from the issuer's OIDC discovery document) with the entry's client_id.
///   Refresh tokens may rotate — results are persisted to the profile store
///   AND back to auth.json when it holds the same account, exactly like the
///   Codex twin.
class GrokUsageService {
    static let shared = GrokUsageService()

    private static let usageEndpoint = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    private static let tokenEndpoint = "https://auth.x.ai/oauth2/token"
    private static let clientMode = "grok-build"

    enum GrokError: Error {
        case invalidJSON
        case noCredentials
        case tokenRefreshFailed(status: Int)
        case usageFetchFailed(status: Int)
    }

    // MARK: - auth.json access

    private var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    func readAuthFile() -> String? {
        try? String(contentsOf: authFileURL, encoding: .utf8)
    }

    private func writeAuthFile(_ json: String) throws {
        try json.write(to: authFileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFileURL.path)
    }

    // MARK: - Credential parsing

    private func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The single OIDC entry inside the issuer-keyed root dict (the CLI stores
    /// one login; take the first entry if several ever appear).
    private func entry(from json: String) -> (key: String, value: [String: Any])? {
        guard let root = parse(json) else { return nil }
        for (k, v) in root {
            if let dict = v as? [String: Any], dict["key"] != nil {
                return (k, dict)
            }
        }
        return nil
    }

    func extractAccessToken(from json: String) -> String? {
        entry(from: json)?.value["key"] as? String
    }

    func extractRefreshToken(from json: String) -> String? {
        entry(from: json)?.value["refresh_token"] as? String
    }

    func extractUserId(from json: String) -> String? {
        entry(from: json)?.value["user_id"] as? String
    }

    func extractEmail(from json: String) -> String? {
        entry(from: json)?.value["email"] as? String
    }

    func extractTokenExpiry(from json: String) -> Date? {
        (entry(from: json)?.value["expires_at"] as? String).flatMap(Self.parseISODate)
    }

    func isTokenExpired(_ json: String) -> Bool {
        guard let expiry = extractTokenExpiry(from: json) else { return true }
        return expiry <= Date()
    }

    /// xAI timestamps carry 6-digit fractional seconds ("2026-07-17T22:38:23.372161+00:00"),
    /// which ISO8601DateFormatter's withFractionalSeconds (3-digit) rejects —
    /// normalize the fraction before parsing. Static for unit tests.
    nonisolated static func parseISODate(_ raw: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: raw) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        // Trim the fraction to milliseconds: split at '.', keep 3 digits, keep tz suffix.
        if let dot = raw.firstIndex(of: ".") {
            let tail = raw[raw.index(after: dot)...]
            if let tzStart = tail.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
                let digits = String(tail[..<tzStart]).prefix(3)
                let rebuilt = String(raw[..<dot]) + "." + digits + String(tail[tzStart...])
                return fractional.date(from: rebuilt)
            }
        }
        return nil
    }

    // MARK: - Token refresh

    /// Redeems the refresh token at auth.x.ai and returns the updated auth.json
    /// string (same shape, entry updated in place). The refresh token ROTATES
    /// when the server returns a new one — callers must persist the result.
    func refreshOAuthToken(credentialsJSON: String) async throws -> String {
        guard var root = parse(credentialsJSON),
              let (entryKey, entryValue) = entry(from: credentialsJSON),
              let refreshToken = entryValue["refresh_token"] as? String,
              let clientId = entryValue["oidc_client_id"] as? String,
              let url = URL(string: Self.tokenEndpoint) else {
            throw GrokError.invalidJSON
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GrokError.tokenRefreshFailed(status: -1)
        }
        guard httpResponse.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let accessToken = payload["access_token"] as? String else {
            LoggingService.shared.log("Grok: OAuth token refresh failed (HTTP \(httpResponse.statusCode))")
            throw GrokError.tokenRefreshFailed(status: httpResponse.statusCode)
        }

        var updated = entryValue
        updated["key"] = accessToken
        if let rotated = payload["refresh_token"] as? String { updated["refresh_token"] = rotated }
        let lifetime = (payload["expires_in"] as? Double) ?? 6 * 3600
        let expiryFormatter = ISO8601DateFormatter()
        expiryFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        updated["expires_at"] = expiryFormatter.string(from: Date().addingTimeInterval(lifetime))
        root[entryKey] = updated

        let merged = try JSONSerialization.data(withJSONObject: root)
        guard let mergedString = String(data: merged, encoding: .utf8) else {
            throw GrokError.invalidJSON
        }
        LoggingService.shared.log("Grok: OAuth token refreshed (new expiry in \(Int(lifetime))s)")
        return mergedString
    }

    /// Per-profile refresh mutex — concurrent redemptions of one refresh token
    /// make the loser 4xx (see the Codex twin).
    private var refreshInFlight: Set<UUID> = []

    /// Makes sure a profile's Grok access token is usable: adopt a fresher token
    /// from auth.json (same-account only), else redeem the refresh token.
    /// Persists changes to the profile store; a refreshed token is written back
    /// to auth.json when it holds the same account, so the CLI never ends up
    /// with a consumed refresh token. Returns true if stored credentials changed.
    func ensureFreshCredentials(for profileId: UUID, freshFor: TimeInterval = 120) async -> Bool {
        guard !refreshInFlight.contains(profileId) else { return false }
        refreshInFlight.insert(profileId)
        defer { refreshInFlight.remove(profileId) }

        var changed = adoptAuthFileIfSameAccount(for: profileId)

        guard let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
              let currentJSON = profile.grokCredentialsJSON else {
            return changed
        }

        let expiry = extractTokenExpiry(from: currentJSON) ?? .distantPast
        if expiry < Date().addingTimeInterval(freshFor), extractRefreshToken(from: currentJSON) != nil {
            do {
                let refreshed = try await refreshOAuthToken(credentialsJSON: currentJSON)

                var profiles = ProfileStore.shared.loadProfiles()
                if let index = profiles.firstIndex(where: { $0.id == profileId }) {
                    profiles[index].grokCredentialsJSON = refreshed
                    profiles[index].grokAccountSyncedAt = Date()
                    ProfileStore.shared.saveProfiles(profiles)
                    // The redemption may have CONSUMED the old refresh token —
                    // get the rotated one on disk before anything can kill us.
                    await ProfileStore.shared.flushKeychainWrites()
                }

                if let fileJSON = readAuthFile(),
                   extractUserId(from: fileJSON) == extractUserId(from: refreshed) {
                    try? writeAuthFile(refreshed)
                }
                changed = true
            } catch {
                LoggingService.shared.logError("Grok: token refresh failed (non-fatal)", error: error)
            }
        }

        return changed
    }

    /// If ~/.grok/auth.json holds a FRESHER token for the SAME account (the CLI
    /// refreshed it during its own use), adopt it into the profile.
    @discardableResult
    func adoptAuthFileIfSameAccount(for profileId: UUID) -> Bool {
        guard let fileJSON = readAuthFile(),
              let fileUserId = extractUserId(from: fileJSON) else { return false }
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }),
              let profileJSON = profiles[index].grokCredentialsJSON,
              extractUserId(from: profileJSON) == fileUserId,
              profileJSON != fileJSON else { return false }
        let fileExpiry = extractTokenExpiry(from: fileJSON) ?? .distantPast
        let profileExpiry = extractTokenExpiry(from: profileJSON) ?? .distantPast
        guard fileExpiry > profileExpiry else { return false }
        profiles[index].grokCredentialsJSON = fileJSON
        profiles[index].grokAccountSyncedAt = Date()
        ProfileStore.shared.saveProfiles(profiles)
        LoggingService.shared.log("Grok: adopted fresher CLI token from auth.json for profile \(profileId.uuidString.prefix(8))")
        return true
    }

    // MARK: - Usage fetch

    func fetchUsage(for profileId: UUID, isRetryAfterRefresh: Bool = false) async throws -> ClaudeUsage {
        _ = await ensureFreshCredentials(for: profileId)

        guard let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
              let credsJSON = profile.grokCredentialsJSON,
              let token = extractAccessToken(from: credsJSON),
              let url = URL(string: Self.usageEndpoint) else {
            throw GrokError.noCredentials
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.clientMode, forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GrokError.usageFetchFailed(status: -1)
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseBillingResponse(data)
        case 401, 403:
            // Stale/revoked access token: one forced refresh + retry.
            if !isRetryAfterRefresh, let refreshable = profile.grokCredentialsJSON,
               extractRefreshToken(from: refreshable) != nil {
                _ = await ensureFreshCredentials(for: profileId, freshFor: 24 * 3600)
                return try await fetchUsage(for: profileId, isRetryAfterRefresh: true)
            }
            throw AppError.apiUnauthorized()
        case 429:
            // Same shape as the Claude account-level throttle: carry Retry-After
            // so the sweep's stampAccountThrottleIfNeeded can mark the account.
            var rateLimited = AppError.apiRateLimited()
            rateLimited.retryAfterSeconds = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw rateLimited
        default:
            throw GrokError.usageFetchFailed(status: httpResponse.statusCode)
        }
    }

    /// Maps the billing config onto ClaudeUsage. Numeric fields may arrive as
    /// plain numbers or `{"val": n}` wrappers, and are OMITTED entirely while
    /// zero (fresh accounts) — missing means 0. Static for unit tests.
    nonisolated static func parseBillingResponse(_ data: Data, now: Date = Date()) throws -> ClaudeUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else {
            throw GrokError.invalidJSON
        }

        func number(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            if let wrapped = any as? [String: Any] { return number(wrapped["val"]) }
            if let s = any as? String { return Double(s) }
            return nil
        }

        let period = config["currentPeriod"] as? [String: Any]
        let periodEnd = (period?["end"] as? String).flatMap(parseISODate)
            ?? now.addingTimeInterval(7 * 24 * 3600)

        var percent = number(config["creditUsagePercent"]) ?? 0
        if percent == 0,
           let used = number(config["includedUsed"]), used > 0,
           let limit = number(config["monthlyLimit"]), limit > 0 {
            percent = min(100, used / limit * 100)
        }

        return ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: 0,
            // Grok has no 5h session window; a future reset keeps
            // effectiveSessionPercentage at the raw 0%.
            sessionResetTime: periodEnd,
            weeklyTokensUsed: Int(number(config["totalUsed"]) ?? 0),
            weeklyLimit: Int(number(config["monthlyLimit"]) ?? 0),
            weeklyPercentage: percent,
            weeklyResetTime: periodEnd,
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: number(config["prepaidBalance"]),
            overageBalanceCurrency: nil,
            lastUpdated: now,
            userTimezone: .current
        )
    }
}
