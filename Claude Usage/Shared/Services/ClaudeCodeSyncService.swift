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

    /// Reads Claude Code credentials using a fallback chain:
    /// 1. ~/.claude/.credentials.json (always complete, not subject to keychain truncation)
    /// 2. System Keychain (may be truncated for large payloads >2KB)
    /// 3. Regex extraction of accessToken from truncated keychain data (last resort)
    func readSystemCredentials() throws -> String? {
        // 1. Try credentials file first (most reliable)
        if let fileJSON = readCredentialsFile() {
            LoggingService.shared.log("Read credentials from .credentials.json file")
            return fileJSON
        }

        // 2. Try keychain
        let keychainData = try readKeychainCredentials()

        guard let rawJSON = keychainData else {
            // No credentials anywhere
            return nil
        }

        // 3. Validate keychain JSON
        if let data = rawJSON.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return rawJSON
        }

        // 4. Keychain data is truncated/invalid — try regex extraction
        LoggingService.shared.log("Keychain JSON is invalid (likely truncated), attempting regex extraction")
        if let token = extractAccessTokenViaRegex(from: rawJSON) {
            let minimalJSON = "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}"
            LoggingService.shared.log("Built minimal credentials from regex-extracted token")
            return minimalJSON
        }

        // 5. All attempts failed
        throw ClaudeCodeError.invalidJSON
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

    /// Writes Claude Code credentials to system Keychain AND ~/.claude/.credentials.json.
    /// Both targets are updated so that readSystemCredentials() (which reads the file first)
    /// and Claude Code CLI (which also reads the file) stay in sync with profile switches.
    func writeSystemCredentials(_ jsonData: String) throws {
        let serviceName = resolveServiceName()
        LoggingService.shared.log("Writing credentials to keychain via Security framework (service: \(serviceName))")

        guard let passwordData = jsonData.data(using: .utf8) else {
            throw ClaudeCodeError.invalidJSON
        }

        // Query to find existing item
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: NSUserName()
        ]

        // Attributes for the credential
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        // Try to update existing item first
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            // Item doesn't exist yet — add it
            var addQuery = query
            addQuery[kSecValueData as String] = passwordData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status == errSecSuccess {
            LoggingService.shared.log("Added Claude Code system credentials successfully via Security framework")
        } else {
            LoggingService.shared.log("Failed to write credentials (status: \(status))")
            throw ClaudeCodeError.keychainWriteFailed(status: status)
        }

        // Also write to ~/.claude/.credentials.json so the file stays in sync.
        // readSystemCredentials() reads this file first, and Claude Code CLI does too.
        writeCredentialsFile(jsonData)
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

        LoggingService.shared.log("📦 Found CLI credentials, writing to keychain...")
        try writeSystemCredentials(jsonData)

        LoggingService.shared.log("✅ Applied profile CLI credentials to system: \(profileId)")
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
        }
    }
}
