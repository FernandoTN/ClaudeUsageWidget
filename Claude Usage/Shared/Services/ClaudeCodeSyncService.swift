//
//  ClaudeCodeSyncService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Security

/// Manages synchronization of Claude Code CLI credentials between system Keychain and profiles
class ClaudeCodeSyncService {
    static let shared = ClaudeCodeSyncService()

    /// Cached resolved keychain service name (cleared per app session)
    private var resolvedServiceName: String?

    private init() {}

    // MARK: - System Credentials Access (Fallback Chain)

    /// Reads Claude Code credentials, preferring the source the CLI itself trusts:
    /// 1. System Keychain item — the CLI's source of truth. A CLI login or silent
    ///    token refresh updates ONLY this item, never the plaintext file.
    /// 2. ~/.claude/.credentials.json — the CLI's plaintext fallback. This app also
    ///    rewrites it on every profile switch, so it must never shadow a fresher
    ///    Keychain item (reading it first re-ingests our own stale write).
    ///    When both sources hold valid JSON, the later-expiring token wins;
    ///    ties go to the Keychain.
    /// 3. Regex extraction of accessToken from truncated Keychain data (last resort).
    ///
    /// Shells out to `security` — never call on the main thread; use
    /// `readSystemCredentialsOffMain()` from main-actor contexts.
    func readSystemCredentials() throws -> String? {
        var keychainRaw: String?
        var keychainError: Error?
        do {
            keychainRaw = try readKeychainCredentials()
        } catch {
            keychainError = error
        }

        // Accept the keychain payload only if it is complete, valid JSON
        var keychainJSON: String?
        if let raw = keychainRaw,
           let data = raw.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil {
            keychainJSON = raw
        }

        let fileJSON = readCredentialsFile()

        switch (keychainJSON, fileJSON) {
        case let (keychain?, file?):
            let keychainExpiry = extractTokenExpiry(from: keychain) ?? .distantPast
            let fileExpiry = extractTokenExpiry(from: file) ?? .distantPast
            if fileExpiry > keychainExpiry {
                LoggingService.shared.log("Using credentials file (token outlives Keychain's: \(fileExpiry) vs \(keychainExpiry))")
                return file
            }
            LoggingService.shared.log("Using system Keychain credentials (expires \(keychainExpiry))")
            return keychain
        case let (keychain?, nil):
            LoggingService.shared.log("Using system Keychain credentials (no credentials file)")
            return keychain
        case let (nil, file?):
            LoggingService.shared.log("Using credentials file (Keychain unavailable)")
            return file
        case (nil, nil):
            break
        }

        // Keychain data present but invalid (likely truncated >2KB) — try regex extraction
        if let raw = keychainRaw {
            LoggingService.shared.log("Keychain JSON is invalid (likely truncated), attempting regex extraction")
            if let token = extractAccessTokenViaRegex(from: raw) {
                let minimalJSON = "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}"
                LoggingService.shared.log("Built minimal credentials from regex-extracted token")
                return minimalJSON
            }
            throw ClaudeCodeError.invalidJSON
        }

        // No credentials anywhere; surface a keychain read failure if one occurred
        if let keychainError {
            throw keychainError
        }
        return nil
    }

    /// Reads system credentials on a background queue and *suspends* — rather than
    /// blocks — the calling actor. Safe to call from the main actor.
    func readSystemCredentialsOffMain() async throws -> String? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.readSystemCredentials() })
            }
        }
    }

    // MARK: - Private Credential Sources

    /// Reads credentials from ~/.claude/.credentials.json or ~/.claude/credentials.json file
    private func readCredentialsFile() -> String? {
        let paths = [
            Constants.ClaudePaths.claudeDirectory.appendingPathComponent(".credentials.json"),
            Constants.ClaudePaths.claudeDirectory.appendingPathComponent("credentials.json")
        ]

        for fileURL in paths {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else {
                LoggingService.shared.log("credentials file exists but could not be read: \(fileURL.lastPathComponent)")
                continue
            }

            // Validate it's actually valid JSON
            guard let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                LoggingService.shared.log("credentials file contains invalid JSON: \(fileURL.lastPathComponent)")
                continue
            }

            LoggingService.shared.log("Read credentials from \(fileURL.lastPathComponent)")
            return jsonString
        }

        return nil
    }

    /// Reads Claude Code credentials from system Keychain using security command
    private func readKeychainCredentials() throws -> String? {
        let serviceName = resolveServiceName()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w"  // Print password only
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let exitCode = process.terminationStatus

        if exitCode == 0 {
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let value = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }
            return value
        } else if exitCode == 44 {
            // Exit code 44 = item not found
            return nil
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            LoggingService.shared.log("Failed to read keychain: \(errorString)")
            throw ClaudeCodeError.keychainReadFailed(status: OSStatus(exitCode))
        }
    }

    /// Extracts accessToken from potentially truncated JSON using regex
    private func extractAccessTokenViaRegex(from rawString: String) -> String? {
        let pattern = "\"accessToken\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawString, range: NSRange(rawString.startIndex..., in: rawString)),
              let tokenRange = Range(match.range(at: 1), in: rawString) else {
            return nil
        }
        return String(rawString[tokenRange])
    }

    // MARK: - Keychain Service Name Discovery

    private static let legacyServiceName = "Claude Code-credentials"

    /// Resolves the correct keychain service name for Claude Code credentials.
    /// Claude Code v2.1.52+ changed from "Claude Code-credentials" to "Claude Code-credentials-HASH".
    /// Tries legacy name first, then falls back to prefix search.
    private func resolveServiceName() -> String {
        if let cached = resolvedServiceName {
            return cached
        }

        // Try legacy name first (fast path)
        if keychainItemExists(serviceName: Self.legacyServiceName) {
            resolvedServiceName = Self.legacyServiceName
            return Self.legacyServiceName
        }

        // Fall back to searching for "Claude Code-credentials-" prefix
        if let hashedName = findHashedServiceName() {
            resolvedServiceName = hashedName
            LoggingService.shared.log("Resolved hashed keychain service name: \(hashedName)")
            return hashedName
        }

        // Default to legacy name (will fail gracefully if not found)
        resolvedServiceName = Self.legacyServiceName
        return Self.legacyServiceName
    }

    /// Checks if a keychain item exists with the given service name
    private func keychainItemExists(serviceName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", serviceName, "-a", NSUserName()]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Searches the keychain for a hashed service name matching "Claude Code-credentials-*"
    private func findHashedServiceName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["dump-keychain"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let prefix = "Claude Code-credentials-"

        // Parse service names from dump-keychain output (format: "svce"<blob>="ServiceName")
        for line in output.components(separatedBy: "\n") {
            guard line.contains("\"svce\""), line.contains(prefix) else { continue }
            // Extract the value between quotes after the =
            if let equalsRange = line.range(of: "=\""),
               let endQuoteRange = line.range(of: "\"", range: equalsRange.upperBound..<line.endIndex) {
                let name = String(line[equalsRange.upperBound..<endQuoteRange.lowerBound])
                if name.hasPrefix(prefix) {
                    return name
                }
            }
        }
        return nil
    }

    /// Invalidates the cached service name, forcing re-discovery on next access
    func invalidateServiceNameCache() {
        resolvedServiceName = nil
    }

    /// Syncs Claude Code credentials to BOTH `~/.claude/.credentials.json` and the
    /// shared `Claude Code-credentials` system Keychain item — the Claude Code CLI
    /// reads the Keychain as its source of truth, so the item must be updated for an
    /// in-app account switch to take effect in the CLI.
    ///
    /// The Keychain update shells out to `/usr/bin/security` rather than using the
    /// `SecItem*` API. The item's ACL is bound to the Claude Code CLI's code signature
    /// and macOS adds a partition-list restriction (`apple-tool:`) on top. A `SecItem*`
    /// write from this app — ad-hoc signed and NOT in the `apple-tool:` partition —
    /// raises a SecurityAgent password prompt on every call, and "Always Allow" never
    /// sticks (the ad-hoc signature changes on every build). The `security` CLI tool,
    /// however, runs *inside* the `apple-tool:` partition, so its `-U` (update)
    /// succeeds silently.
    func writeSystemCredentials(_ jsonData: String) throws {
        guard jsonData.data(using: .utf8) != nil else {
            throw ClaudeCodeError.invalidJSON
        }
        writeCredentialsFile(jsonData)
        updateSystemKeychainViaSecurityTool(jsonData)
    }

    /// Updates the `Claude Code-credentials` Keychain item via the `security` CLI.
    /// Best-effort: a failure here is logged but does not fail the profile switch.
    private func updateSystemKeychainViaSecurityTool(_ jsonData: String) {
        let serviceName = resolveServiceName()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password",
            "-U",                       // update the item if it already exists
            "-s", serviceName,
            "-a", NSUserName(),
            "-w", jsonData
        ]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                LoggingService.shared.log("Updated Claude Code system Keychain item via security CLI")
            } else {
                let err = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
                LoggingService.shared.log("security CLI keychain update failed (status \(process.terminationStatus)): \(err)")
            }
        } catch {
            LoggingService.shared.logError("Failed to launch security CLI for keychain update", error: error)
        }
    }

    /// Writes credentials to ~/.claude/.credentials.json (best-effort).
    /// Keeps the file in sync with the system keychain so that readSystemCredentials()
    /// and Claude Code CLI both see the active profile's credentials.
    private func writeCredentialsFile(_ jsonData: String) {
        let fileURL = Constants.ClaudePaths.credentialsFile
        let dirURL = Constants.ClaudePaths.claudeDirectory

        // Ensure ~/.claude/ directory exists
        if !FileManager.default.fileExists(atPath: dirURL.path) {
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            } catch {
                LoggingService.shared.logError("Failed to create .claude directory: \(error.localizedDescription)")
                return
            }
        }

        do {
            try jsonData.write(to: fileURL, atomically: true, encoding: .utf8)
            LoggingService.shared.log("Wrote credentials to \(fileURL.lastPathComponent)")
        } catch {
            LoggingService.shared.logError("Failed to write credentials file (non-fatal): \(error.localizedDescription)")
        }
    }

    // MARK: - Profile Sync Operations

    /// Syncs credentials from system to profile (one-time copy)
    func syncToProfile(_ profileId: UUID) throws {
        guard let jsonData = try readSystemCredentials() else {
            throw ClaudeCodeError.noCredentialsFound
        }

        // Validate JSON format
        guard let data = jsonData.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCodeError.invalidJSON
        }

        // Save to profile directly
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ClaudeCodeError.noProfileCredentials
        }

        profiles[index].cliCredentialsJSON = jsonData
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("Synced CLI credentials to profile: \(profileId)")
    }

    /// Applies profile's CLI credentials to system (overwrites current login)
    func applyProfileCredentials(_ profileId: UUID) throws {
        LoggingService.shared.log("🔄 Applying CLI credentials for profile: \(profileId)")

        let profiles = ProfileStore.shared.loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileId }),
              let jsonData = profile.cliCredentialsJSON else {
            LoggingService.shared.log("❌ No CLI credentials found for profile: \(profileId)")
            throw ClaudeCodeError.noProfileCredentials
        }

        LoggingService.shared.log("📦 Found CLI credentials, syncing to ~/.claude/.credentials.json...")
        try writeSystemCredentials(jsonData)

        LoggingService.shared.log("✅ Applied profile CLI credentials: \(profileId)")
    }

    /// Removes CLI credentials from profile (doesn't affect system)
    func removeFromProfile(_ profileId: UUID) throws {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ClaudeCodeError.noProfileCredentials
        }

        profiles[index].cliCredentialsJSON = nil
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("Removed CLI credentials from profile: \(profileId)")
    }

    // MARK: - Access Token Extraction

    func extractAccessToken(from jsonData: String) -> String? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }
        return token
    }

    func extractSubscriptionInfo(from jsonData: String) -> (type: String, scopes: [String])? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }

        let subType = oauth["subscriptionType"] as? String ?? "unknown"
        let scopes = oauth["scopes"] as? [String] ?? []

        return (subType, scopes)
    }

    /// Extracts the token expiry date from CLI credentials JSON
    func extractTokenExpiry(from jsonData: String) -> Date? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let expiresAt = oauth["expiresAt"] as? TimeInterval else {
            return nil
        }
        // Claude Code CLI stores expiresAt in milliseconds since epoch
        // Values > 1e12 are definitely milliseconds (year 2001+ in ms vs year 33658 in seconds)
        let epochSeconds = expiresAt > 1e12 ? expiresAt / 1000.0 : expiresAt
        return Date(timeIntervalSince1970: epochSeconds)
    }

    /// Checks if the OAuth token in the credentials JSON is expired
    func isTokenExpired(_ jsonData: String) -> Bool {
        guard let expiryDate = extractTokenExpiry(from: jsonData) else {
            // No expiry info = assume valid
            return false
        }
        return Date() > expiryDate
    }

    /// Extracts the OAuth refresh token from CLI credentials JSON
    func extractRefreshToken(from jsonData: String) -> String? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["refreshToken"] as? String else {
            return nil
        }
        return token
    }

    // MARK: - OAuth Token Refresh

    /// Claude Code's public OAuth client ID. The token endpoint requires it for the
    /// refresh_token grant; it is the same value the CLI sends and is not a secret.
    private static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let oauthTokenEndpoint = "https://console.anthropic.com/v1/oauth/token"

    /// Exchanges the refresh token for a new access token — the same silent refresh
    /// the CLI performs. Returns the full credentials JSON with the rotated tokens
    /// merged in (scopes / subscriptionType are preserved).
    ///
    /// NOTE: the refresh token ROTATES on success. The caller must persist the
    /// returned JSON everywhere the old one lived (profile store, and — for the
    /// active profile — the system Keychain + credentials file), otherwise the CLI
    /// is left holding a consumed refresh token and forces a re-login.
    func refreshOAuthToken(credentialsJSON: String) async throws -> String {
        guard let data = credentialsJSON.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String,
              let url = URL(string: Self.oauthTokenEndpoint) else {
            throw ClaudeCodeError.invalidJSON
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientId
        ])

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeCodeError.tokenRefreshFailed(status: -1)
        }
        guard httpResponse.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let accessToken = payload["access_token"] as? String else {
            LoggingService.shared.log("OAuth token refresh failed (HTTP \(httpResponse.statusCode))")
            throw ClaudeCodeError.tokenRefreshFailed(status: httpResponse.statusCode)
        }

        oauth["accessToken"] = accessToken
        if let rotated = payload["refresh_token"] as? String {
            oauth["refreshToken"] = rotated
        }
        if let expiresIn = payload["expires_in"] as? Double {
            // CLI stores expiresAt as integer milliseconds since epoch
            oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + expiresIn) * 1000.0)
        }
        if let scope = payload["scope"] as? String, !scope.isEmpty {
            oauth["scopes"] = scope.components(separatedBy: " ")
        }
        root["claudeAiOauth"] = oauth

        let merged = try JSONSerialization.data(withJSONObject: root)
        guard let mergedString = String(data: merged, encoding: .utf8) else {
            throw ClaudeCodeError.invalidJSON
        }
        LoggingService.shared.log("OAuth token refreshed via refresh_token grant (new expiry: \(extractTokenExpiry(from: mergedString)?.description ?? "unknown"))")
        return mergedString
    }

    /// Makes sure a profile's stored CLI credentials hold a usable access token,
    /// self-healing a stale one without user interaction:
    ///
    /// 1. `adoptSystemKeychain` (active profile only!): the CLI silently refreshes
    ///    its token in the shared Keychain item while an account is in use, and that
    ///    item always belongs to the ACTIVE account — adopt it if it expires later.
    /// 2. If the token is still expired (or about to), redeem the refresh token via
    ///    the OAuth endpoint, exactly like the CLI would.
    ///
    /// Any update is persisted to the profile store; when `syncToSystem` is set, an
    /// OAuth-refreshed token is also written back to the system Keychain +
    /// credentials file so the CLI never holds a consumed refresh token.
    /// Returns true if the stored credentials changed (callers should reload profiles).
    func ensureFreshCredentials(for profileId: UUID, adoptSystemKeychain: Bool, syncToSystem: Bool) async -> Bool {
        guard let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
              var workingJSON = profile.cliCredentialsJSON else {
            return false
        }

        var changed = false

        if adoptSystemKeychain,
           let systemJSON = try? await readSystemCredentialsOffMain(),
           let systemExpiry = extractTokenExpiry(from: systemJSON),
           systemExpiry > (extractTokenExpiry(from: workingJSON) ?? .distantPast) {
            workingJSON = systemJSON
            changed = true
            LoggingService.shared.log("ensureFreshCredentials: adopted fresher token from system Keychain (expires \(systemExpiry))")
        }

        var didOAuthRefresh = false
        let expiry = extractTokenExpiry(from: workingJSON) ?? .distantPast
        if expiry < Date().addingTimeInterval(120), extractRefreshToken(from: workingJSON) != nil {
            do {
                workingJSON = try await refreshOAuthToken(credentialsJSON: workingJSON)
                changed = true
                didOAuthRefresh = true
            } catch {
                LoggingService.shared.logError("ensureFreshCredentials: OAuth token refresh failed (non-fatal)", error: error)
            }
        }

        guard changed else { return false }

        var profiles = ProfileStore.shared.loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].cliCredentialsJSON = workingJSON
            profiles[index].cliAccountSyncedAt = Date()
            ProfileStore.shared.saveProfiles(profiles)
        }

        if syncToSystem && didOAuthRefresh {
            let json = workingJSON
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try self.writeSystemCredentials(json)
                    } catch {
                        LoggingService.shared.logError("ensureFreshCredentials: failed to sync refreshed token to system (non-fatal)", error: error)
                    }
                    continuation.resume()
                }
            }
        }

        return true
    }

    // MARK: - Auto Re-sync Before Switching

    /// Re-syncs credentials from system Keychain before profile switching
    /// This ensures we always have the latest CLI login when switching profiles
    func resyncBeforeSwitching(for profileId: UUID) throws {
        LoggingService.shared.log("Re-syncing CLI credentials before profile switch: \(profileId)")

        // Read fresh credentials from system (if user is logged in)
        guard let freshJSON = try readSystemCredentials() else {
            // No credentials in system - user not logged into CLI anymore
            LoggingService.shared.log("No system credentials found - skipping re-sync")
            return
        }

        // Validate JSON before saving (defense-in-depth against truncated data)
        guard let data = freshJSON.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LoggingService.shared.log("Re-synced credentials contain invalid JSON - skipping save")
            return
        }

        // Update profile's stored credentials with fresh ones
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            return
        }

        profiles[index].cliCredentialsJSON = freshJSON
        profiles[index].cliAccountSyncedAt = Date()  // Update sync timestamp
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("✓ Re-synced CLI credentials from system and updated timestamp")
    }
}

// MARK: - ClaudeCodeError

enum ClaudeCodeError: LocalizedError {
    case noCredentialsFound
    case invalidJSON
    case keychainReadFailed(status: OSStatus)
    case keychainWriteFailed(status: OSStatus)
    case noProfileCredentials
    case tokenRefreshFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .noCredentialsFound:
            return "No Claude Code credentials found in system Keychain. Please log in to Claude Code first."
        case .invalidJSON:
            return "Claude Code credentials are corrupted or invalid."
        case .keychainReadFailed(let status):
            return "Failed to read credentials from system Keychain (status: \(status))."
        case .keychainWriteFailed(let status):
            return "Failed to write credentials to system Keychain (status: \(status))."
        case .noProfileCredentials:
            return "This profile has no synced CLI account."
        case .tokenRefreshFailed(let status):
            return "Failed to refresh the Claude Code OAuth token (HTTP \(status)). Please re-sync your CLI account."
        }
    }
}
