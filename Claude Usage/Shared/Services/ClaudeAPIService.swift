import Foundation

/// Service for fetching usage data directly from Claude's API
class ClaudeAPIService {
    // MARK: - Types

    /// Authentication method for API requests (CLI OAuth only)
    private enum AuthenticationType {
        case cliOAuth(String)              // Authorization: Bearer ... (with anthropic-beta header)
    }

    // MARK: - Initialization

    init() {}

    // MARK: - Authentication

    /// Gets the best available authentication method with fallback support
    /// Priority: 1) saved CLI OAuth → 2) system Keychain CLI OAuth
    /// Async so the system Keychain fallback can shell out to `security` OFF the main
    /// thread (see the CLAUDE.md rule about Keychain reads on the main thread).
    private func getAuthentication() async throws -> AuthenticationType {
        guard let activeProfile = ProfileManager.shared.activeProfile else {
            LoggingService.shared.logError("ClaudeAPIService.getAuthentication: No active profile")
            throw AppError.sessionKeyNotFound()
        }

        // Prefer saved CLI OAuth token if available and not expired
        if let cliJSON = activeProfile.cliCredentialsJSON {
            if !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON),
               let accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: cliJSON) {
                LoggingService.shared.log("ClaudeAPIService: Using saved CLI OAuth token")
                return .cliOAuth(accessToken)
            } else {
                LoggingService.shared.log("ClaudeAPIService: Saved CLI OAuth token is expired or invalid")
            }
        }

        // Fall back to reading CLI credentials directly from system Keychain
        do {
            if let systemCredentials = try await ClaudeCodeSyncService.shared.readSystemCredentialsOffMain() {
                LoggingService.shared.log("ClaudeAPIService: Found CLI credentials in system Keychain")

                // Validate token is not expired
                if ClaudeCodeSyncService.shared.isTokenExpired(systemCredentials) {
                    LoggingService.shared.log("ClaudeAPIService: System Keychain CLI token is expired")
                } else if let accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: systemCredentials) {
                    LoggingService.shared.log("ClaudeAPIService: Using CLI credentials from system Keychain")
                    return .cliOAuth(accessToken)
                } else {
                    LoggingService.shared.log("ClaudeAPIService: Could not extract access token from system Keychain credentials")
                }
            } else {
                LoggingService.shared.log("ClaudeAPIService: No CLI credentials found in system Keychain")
            }
        } catch {
            LoggingService.shared.log("ClaudeAPIService: Could not read system CLI credentials: \(error.localizedDescription)")
        }

        LoggingService.shared.logError("ClaudeAPIService.getAuthentication: No valid credentials for usage data")
        throw AppError.sessionKeyNotFound()
    }

    /// Builds an authenticated request with the appropriate headers for the auth type
    private func buildAuthenticatedRequest(url: URL, auth: AuthenticationType) -> URLRequest {
        var request = URLRequest(url: url)

        switch auth {
        case .cliOAuth(let accessToken):
            // CLI OAuth authentication (requires specific headers)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            request.setValue("ClaudeUsageWidget/\(version)", forHTTPHeaderField: "User-Agent")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }

        return request
    }

    // MARK: - API Requests

    /// Fetches usage data via OAuth access token (CLI credential flow)
    func fetchUsageData(oauthAccessToken: String) async throws -> ClaudeUsage {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw AppError(code: .urlMalformed, message: "Invalid OAuth usage endpoint", isRecoverable: false)
        }

        var request = buildAuthenticatedRequest(url: url, auth: .cliOAuth(oauthAccessToken))
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(code: .apiInvalidResponse, message: "Invalid response from OAuth endpoint", isRecoverable: true)
        }

        guard httpResponse.statusCode == 200 else {
            // A 429 here can be ACCOUNT-level: a heavily-used account throttles
            // its own usage endpoint (with a Retry-After of minutes), so the
            // caller must be able to tell this apart from a generic failure —
            // it IS the "this account is out of capacity" signal.
            if httpResponse.statusCode == 429 {
                var rateLimited = AppError.apiRateLimited()
                rateLimited.retryAfterSeconds = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                throw rateLimited
            }
            throw AppError(
                code: httpResponse.statusCode == 401 || httpResponse.statusCode == 403
                    ? .apiUnauthorized : .apiGenericError,
                message: "OAuth fetch failed (status \(httpResponse.statusCode))",
                isRecoverable: true
            )
        }

        return try parseUsageResponse(data)
    }

    /// Fetches real usage data from Claude's API using the active profile's CLI OAuth credentials
    func fetchUsageData() async throws -> ClaudeUsage {
        let auth = try await getAuthentication()

        // The dedicated OAuth usage endpoint (api.anthropic.com/api/oauth/usage) is disabled
        // for the active-profile path in some environments. Instead, make a minimal Messages
        // API call and extract usage from response headers.
        LoggingService.shared.log("ClaudeAPIService: Fetching usage via Messages API headers (OAuth)")

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AppError(
                code: .urlMalformed,
                message: "Invalid Messages API endpoint",
                isRecoverable: false
            )
        }

        var request = buildAuthenticatedRequest(url: url, auth: auth)
        request.httpMethod = "POST"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        // IMPORTANT: This sends a real (minimal) API message because no dedicated
        // OAuth usage endpoint exists. We use the cheapest model, max_tokens=1, and
        // the shortest possible prompt to minimize cost. Usage data is extracted from
        // the rate-limit response headers rather than the message content.
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(
                code: .apiInvalidResponse,
                message: "Invalid response from Messages API",
                isRecoverable: true
            )
        }

        guard httpResponse.statusCode == 200 else {
            let responsePreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to read response"
            throw AppError(
                code: .apiUnauthorized,
                message: "OAuth Messages API request failed",
                technicalDetails: "Status: \(httpResponse.statusCode)\nResponse: \(responsePreview)",
                isRecoverable: true,
                recoverySuggestion: "Please re-sync your CLI account in Settings"
            )
        }

        return parseUsageFromRateLimitHeaders(httpResponse)
    }

    // MARK: - Date Formatters (cached)

    /// ISO 8601 formatter with fractional seconds (primary)
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// ISO 8601 formatter without fractional seconds (fallback)
    private static let iso8601FallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses an ISO 8601 date string, trying fractional seconds first then falling back
    private static func parseISO8601Date(_ string: String) -> Date? {
        return iso8601Formatter.date(from: string)
            ?? iso8601FallbackFormatter.date(from: string)
    }

    // MARK: - Response Parsing

    private func parseUsageResponse(_ data: Data) throws -> ClaudeUsage {
        // Parse Claude's actual API response structure

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // A window that rolled over while the account was idle is reported
            // with zero utilization and NO resets_at (there is no active window).
            // Store the sentinel and let healMissingResetStamps carry the last
            // known boundary forward — never invent one here (the old "next
            // Monday 12:59pm" guess fabricated phantom soonest-resets that
            // mis-ranked auto-switch candidates; real incident).

            // Extract session usage (five_hour)
            var sessionPercentage = 0.0
            var sessionResetTime = ClaudeUsage.unknownResetSentinel
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let utilization = fiveHour["utilization"] {
                    sessionPercentage = parseUtilization(utilization)
                }
                if let resetsAt = fiveHour["resets_at"] as? String {
                    sessionResetTime = Self.parseISO8601Date(resetsAt) ?? sessionResetTime
                }
            }

            // Extract weekly usage (seven_day)
            var weeklyPercentage = 0.0
            var weeklyResetTime = ClaudeUsage.unknownResetSentinel
            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let utilization = sevenDay["utilization"] {
                    weeklyPercentage = parseUtilization(utilization)
                }
                if let resetsAt = sevenDay["resets_at"] as? String {
                    weeklyResetTime = Self.parseISO8601Date(resetsAt) ?? weeklyResetTime
                }
            }

            // Extract Opus weekly usage (seven_day_opus)
            var opusPercentage = 0.0
            if let sevenDayOpus = json["seven_day_opus"] as? [String: Any] {
                if let utilization = sevenDayOpus["utilization"] {
                    opusPercentage = parseUtilization(utilization)
                }
            }

            // Extract Sonnet weekly usage (seven_day_sonnet)
            var sonnetPercentage = 0.0
            var sonnetResetTime: Date? = nil
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                if let utilization = sevenDaySonnet["utilization"] {
                    sonnetPercentage = parseUtilization(utilization)
                }
                if let resetsAt = sevenDaySonnet["resets_at"] as? String {
                    sonnetResetTime = Self.parseISO8601Date(resetsAt)
                }
            }

            // Extract Fable weekly usage. Fable has no `seven_day_fable` object;
            // it is reported as a scoped weekly limit inside the `limits` array:
            // {"kind": "weekly_scoped", "percent": N, "resets_at": ...,
            //  "scope": {"model": {"display_name": "Fable"}}}
            var fablePercentage: Double? = nil
            var fableResetTime: Date? = nil
            if let limits = json["limits"] as? [[String: Any]] {
                for limit in limits {
                    guard (limit["kind"] as? String) == "weekly_scoped",
                          let scope = limit["scope"] as? [String: Any],
                          let model = scope["model"] as? [String: Any],
                          (model["display_name"] as? String) == "Fable" else { continue }
                    if let percent = limit["percent"] {
                        fablePercentage = parseUtilization(percent)
                    }
                    if let resetsAt = limit["resets_at"] as? String {
                        fableResetTime = Self.parseISO8601Date(resetsAt)
                    }
                }
            }

            // We don't know user's plan, so we use 0 for limits we can't determine
            let weeklyLimit = Constants.weeklyLimit

            // Calculate token counts from percentages (using weekly limit as reference)
            let sessionTokens = 0  // Can't calculate without knowing plan
            let sessionLimit = 0   // Unknown without plan
            let weeklyTokens = Int(Double(weeklyLimit) * (weeklyPercentage / 100.0))
            let opusTokens = Int(Double(weeklyLimit) * (opusPercentage / 100.0))
            let sonnetTokens = Int(Double(weeklyLimit) * (sonnetPercentage / 100.0))

            let usage = ClaudeUsage(
                sessionTokensUsed: sessionTokens,
                sessionLimit: sessionLimit,
                sessionPercentage: sessionPercentage,
                sessionResetTime: sessionResetTime,
                weeklyTokensUsed: weeklyTokens,
                weeklyLimit: weeklyLimit,
                weeklyPercentage: weeklyPercentage,
                weeklyResetTime: weeklyResetTime,
                opusWeeklyTokensUsed: opusTokens,
                opusWeeklyPercentage: opusPercentage,
                sonnetWeeklyTokensUsed: sonnetTokens,
                sonnetWeeklyPercentage: sonnetPercentage,
                sonnetWeeklyResetTime: sonnetResetTime,
                fableWeeklyPercentage: fablePercentage,
                fableWeeklyResetTime: fableResetTime,
                costUsed: nil,
                costLimit: nil,
                costCurrency: nil,
                lastUpdated: Date(),
                userTimezone: .current
            )

            return usage
        }

        // Log the actual response for debugging
        if SharedDataStore.shared.loadDebugAPILoggingEnabled() {
            if let responseString = String(data: data, encoding: .utf8) {
                LoggingService.shared.logDebug("Failed to parse usage response: \(responseString)")
            }
        }

        throw AppError(
            code: .apiParsingFailed,
            message: "Failed to parse usage data",
            technicalDetails: "Unable to parse JSON response structure",
            isRecoverable: false,
            recoverySuggestion: "Please check the error log and report this issue"
        )
    }

    // MARK: - Rate Limit Header Parsing

    /// Parses usage data from Messages API rate limit response headers.
    /// Headers use format: anthropic-ratelimit-unified-{window}-{field}
    /// Utilization values are 0.0-1.0 (converted to 0-100 percentage).
    private func parseUsageFromRateLimitHeaders(_ response: HTTPURLResponse) -> ClaudeUsage {
        func headerDouble(_ name: String) -> Double? {
            if let value = response.value(forHTTPHeaderField: name) {
                return Double(value)
            }
            return nil
        }

        // Session (5h) usage — utilization is 0.0-1.0, convert to 0-100
        let sessionUtilization = headerDouble("anthropic-ratelimit-unified-5h-utilization") ?? 0
        var sessionPercentage = sessionUtilization * 100.0

        // Missing reset headers get the sentinel (see parseUsageResponse) — the
        // caller's healMissingResetStamps carries the last known boundary forward.
        let sessionResetTimestamp = headerDouble("anthropic-ratelimit-unified-5h-reset") ?? 0
        let sessionResetTime = sessionResetTimestamp > 0
            ? Date(timeIntervalSince1970: sessionResetTimestamp)
            : ClaudeUsage.unknownResetSentinel

        // If the 5-hour window has already expired, the session has reset
        // (an unknown boundary is not "expired" — don't zero on the sentinel)
        if sessionResetTime != ClaudeUsage.unknownResetSentinel, sessionResetTime < Date() {
            sessionPercentage = 0.0
        }

        // Weekly (7d) usage
        let weeklyUtilization = headerDouble("anthropic-ratelimit-unified-7d-utilization") ?? 0
        let weeklyPercentage = weeklyUtilization * 100.0

        let weeklyResetTimestamp = headerDouble("anthropic-ratelimit-unified-7d-reset") ?? 0
        let weeklyResetTime = weeklyResetTimestamp > 0
            ? Date(timeIntervalSince1970: weeklyResetTimestamp)
            : ClaudeUsage.unknownResetSentinel

        // Per-model breakdowns not available in rate limit headers
        let weeklyLimit = Constants.weeklyLimit
        let weeklyTokens = Int(Double(weeklyLimit) * (weeklyPercentage / 100.0))

        LoggingService.shared.log("ClaudeAPIService: Parsed usage from headers - session: \(String(format: "%.1f", sessionPercentage))%, weekly: \(String(format: "%.1f", weeklyPercentage))%")

        return ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: sessionPercentage,
            sessionResetTime: sessionResetTime,
            weeklyTokensUsed: weeklyTokens,
            weeklyLimit: weeklyLimit,
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

    // MARK: - Parsing Helpers

    /// Robust utilization parser that handles Int, Double, or String types
    /// - Parameter value: The utilization value from API (can be Int, Double, or String)
    /// - Returns: Parsed percentage as Double, or 0.0 if parsing fails
    private func parseUtilization(_ value: Any) -> Double {
        // Try Int first (most common)
        if let intValue = value as? Int {
            return Double(intValue)
        }

        // Try Double
        if let doubleValue = value as? Double {
            return doubleValue
        }

        // Try String
        if let stringValue = value as? String {
            // Remove any percentage symbols or whitespace
            let cleaned = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")

            if let parsed = Double(cleaned) {
                return parsed
            }
        }

        // Log warning if we couldn't parse
        LoggingService.shared.logWarning("Failed to parse utilization value: \(value) (type: \(type(of: value)))")
        return 0.0
    }

}
