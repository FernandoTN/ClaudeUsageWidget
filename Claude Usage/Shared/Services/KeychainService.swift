//
//  KeychainService.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-28.
//

import Foundation
import Security

/// Service for secure storage and retrieval of sensitive data using macOS Keychain
class KeychainService {
    static let shared = KeychainService()

    private init() {}

    /// Keychain item identifiers
    enum KeychainKey: String {
        case apiSessionKey = "com.claudeusagetracker.api-session-key"
        case claudeSessionKey = "com.claudeusagetracker.claude-session-key"

        var service: String {
            return rawValue
        }

        var account: String {
            return "session-key"
        }
    }

    // MARK: - Public Methods

    /// Saves a string value to the Keychain
    /// - Parameters:
    ///   - value: The string value to save
    ///   - key: The keychain key identifier
    /// - Throws: KeychainError if save fails
    func save(_ value: String, for key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // First, try to update existing item
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            LoggingService.shared.log("Keychain: Updated \(key.service)")
            return
        }

        // If update fails because item doesn't exist, add new item
        if updateStatus == errSecItemNotFound {
            // Create access control that doesn't require password
            var accessControlError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlocked,
                [],
                &accessControlError
            ) else {
                if let error = accessControlError?.takeRetainedValue() {
                    LoggingService.shared.log("Failed to create access control: \(error)")
                }
                throw KeychainError.saveFailed(status: errSecParam)
            }

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: key.service,
                kSecAttrAccount as String: key.account,
                kSecValueData as String: data,
                kSecAttrAccessControl as String: accessControl,
                kSecAttrSynchronizable as String: false
            ]

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

            if addStatus == errSecSuccess {
                LoggingService.shared.log("Keychain: Added \(key.service)")
                return
            } else {
                throw KeychainError.saveFailed(status: addStatus)
            }
        } else {
            throw KeychainError.saveFailed(status: updateStatus)
        }
    }

    /// Loads a string value from the Keychain
    /// - Parameter key: The keychain key identifier
    /// - Returns: The stored string value, or nil if not found
    /// - Throws: KeychainError if load fails (other than item not found)
    func load(for key: KeychainKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            LoggingService.shared.log("Keychain: Loaded \(key.service)")
            return value
        } else if status == errSecItemNotFound {
            LoggingService.shared.log("Keychain: Item not found \(key.service)")
            return nil
        } else {
            throw KeychainError.loadFailed(status: status)
        }
    }

    /// Deletes a value from the Keychain
    /// - Parameter key: The keychain key identifier
    /// - Throws: KeychainError if delete fails (ignores item not found)
    func delete(for key: KeychainKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess {
            LoggingService.shared.log("Keychain: Deleted \(key.service)")
        } else if status == errSecItemNotFound {
            // Item not found is not an error for delete
            LoggingService.shared.log("Keychain: Item not found for deletion \(key.service)")
        } else {
            throw KeychainError.deleteFailed(status: status)
        }
    }

    // MARK: - Per-Profile Credential Storage

    /// Creates a permissive `SecAccess` that lets every application read the item
    /// without a confirmation prompt.
    ///
    /// This is required because the app is **ad-hoc signed** — its code signature
    /// changes on every build. Keychain ACLs identify trusted apps by signature, so
    /// a default ACL would be invalidated by the next rebuild and trigger a modal
    /// SecurityAgent prompt. If that read happens on the main thread, the prompt
    /// deadlocks the whole UI (it needs the very thread that is blocked waiting for it).
    /// Returns `nil` if the (legacy, deprecated) ACL API is unavailable, in which case
    /// callers fall back to the standard accessibility attribute.
    ///
    /// Also reused by `ClaudeCodeSyncService` for the shared `Claude Code-credentials` item.
    func makeUnrestrictedAccess(label: String) -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, nil, &access) == errSecSuccess,
              let access else {
            return nil
        }
        var aclListCF: CFArray?
        guard SecAccessCopyACLList(access, &aclListCF) == errSecSuccess,
              let aclList = aclListCF as? [SecACL] else {
            return access
        }
        for acl in aclList {
            // nil trusted-applications == every application is trusted;
            // an empty prompt selector (rawValue 0) == never show a confirmation prompt.
            SecACLSetContents(acl, nil, label as CFString, SecKeychainPromptSelector(rawValue: 0))
        }
        return access
    }

    // MARK: security-CLI backend
    //
    // Per-profile items are stored and read EXCLUSIVELY through /usr/bin/security,
    // never through SecItem*. Reason: this app is ad-hoc signed, so every rebuild
    // has a new cdhash. macOS stamps a Keychain item's partition list with the
    // creator's identity — for an ad-hoc app that is `cdhash:<this build>` — and
    // any LATER build fails the partition check, raising one SecurityAgent prompt
    // PER ITEM on every rebuild ("Always Allow" only whitelists the clicking
    // build; SecAccessCreate cannot influence the partition list at all). The
    // security CLI is Apple-signed and lives in the `apple-tool:` partition:
    // items it creates it can always access silently, no matter how often this
    // app is rebuilt. Same approach as the shared `Claude Code-credentials` item
    // in ClaudeCodeSyncService. These calls shell out — keep them off the main
    // thread (ProfileStore routes them through its keychainQueue).

    private static let profileCredentialAccount = "profile-credential"

    private func profileCredentialService(profileId: UUID, key: String) -> String {
        "com.claudewidget.\(key)-\(profileId.uuidString)"
    }

    @discardableResult
    private func runSecurityTool(_ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let out = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }

    /// `find-generic-password -w` prints the value hex-encoded when it contains
    /// bytes outside printable ASCII (e.g. pretty-printed JSON with newlines,
    /// like a stored auth.json copy). Detect that and decode; verified to
    /// round-trip byte-identically for both compact and multiline JSON.
    private func decodeSecurityToolPassword(_ rawOutput: String) -> String {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
        guard !trimmed.isEmpty, trimmed.count % 2 == 0,
              trimmed.unicodeScalars.allSatisfy({ hexDigits.contains($0) }),
              // Only JSON blobs can contain the non-printable bytes that make the
              // CLI hex-encode, so only decode when the payload starts with "{"
              // (hex 7b). A plain credential that happens to look like hex stays as-is.
              trimmed.hasPrefix("7b") else {
            return trimmed
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return trimmed }
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Saves a per-profile credential string to the Keychain via the security CLI
    /// - Parameters:
    ///   - value: The credential string to save
    ///   - profileId: The UUID of the profile
    ///   - key: A short key name (e.g. "claude-key", "api-key", "cli-creds")
    func saveProfileCredential(_ value: String, profileId: UUID, key: String) {
        let service = profileCredentialService(profileId: profileId, key: key)
        var result = runSecurityTool([
            "add-generic-password", "-U",
            "-s", service,
            "-a", Self.profileCredentialAccount,
            "-l", "Claude Usage credential",
            "-w", value
        ])
        if result.status != 0 {
            // A legacy SecItem-created item can refuse the in-place update; replace it.
            deleteProfileCredential(profileId: profileId, key: key)
            result = runSecurityTool([
                "add-generic-password",
                "-s", service,
                "-a", Self.profileCredentialAccount,
                "-l", "Claude Usage credential",
                "-w", value
            ])
        }
        if result.status == 0 {
            LoggingService.shared.log("Keychain: Saved profile credential \(key) for \(profileId.uuidString.prefix(8))")
        } else {
            LoggingService.shared.logError("Keychain: Failed to save profile credential \(key), status: \(result.status) \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Loads a per-profile credential string from the Keychain via the security CLI
    /// - Parameters:
    ///   - profileId: The UUID of the profile
    ///   - key: A short key name (e.g. "claude-key", "api-key", "cli-creds")
    /// - Returns: The stored credential string, or nil if not found
    func loadProfileCredential(profileId: UUID, key: String) -> String? {
        let service = profileCredentialService(profileId: profileId, key: key)
        let result = runSecurityTool([
            "find-generic-password",
            "-s", service,
            "-a", Self.profileCredentialAccount,
            "-w"
        ])
        guard result.status == 0 else {
            // 44 = item not found; anything else is a real failure worth logging.
            if result.status != 44 {
                LoggingService.shared.logError("Keychain: Failed to read profile credential \(key), status: \(result.status)")
            }
            return nil
        }
        let value = decodeSecurityToolPassword(result.stdout)
        return value.isEmpty ? nil : value
    }

    /// Deletes one per-profile credential item (security CLI first, SecItemDelete
    /// as fallback for items created by older builds with signature-bound ACLs).
    func deleteProfileCredential(profileId: UUID, key: String) {
        let service = profileCredentialService(profileId: profileId, key: key)
        let result = runSecurityTool([
            "delete-generic-password",
            "-s", service,
            "-a", Self.profileCredentialAccount
        ])
        if result.status == 0 {
            LoggingService.shared.log("Keychain: Deleted profile credential \(key) for \(profileId.uuidString.prefix(8))")
            return
        }
        // Deleting is not gated on the partition list the way reading is, so the
        // API fallback cleans up items the CLI could not see.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.profileCredentialAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            LoggingService.shared.log("Keychain: Deleted profile credential \(key) for \(profileId.uuidString.prefix(8)) (API fallback)")
        } else if status != errSecItemNotFound && result.status != 44 {
            LoggingService.shared.logError("Keychain: Failed to delete profile credential \(key), status: \(status)")
        }
    }

    /// Deletes all per-profile credentials from the Keychain
    /// - Parameter profileId: The UUID of the profile whose credentials should be deleted
    func deleteProfileCredentials(profileId: UUID) {
        for key in ["claude-key", "api-key", "cli-creds", "codex-creds", "grok-creds"] {
            deleteProfileCredential(profileId: profileId, key: key)
        }
    }

    /// Checks if a value exists in the Keychain
    /// - Parameter key: The keychain key identifier
    /// - Returns: true if the item exists, false otherwise
    func exists(for key: KeychainKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

}

// MARK: - KeychainError

enum KeychainError: Error, LocalizedError {
    case invalidData
    case saveFailed(status: OSStatus)
    case loadFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid data format for Keychain storage"
        case .saveFailed(let status):
            return "Failed to save to Keychain (status: \(status))"
        case .loadFailed(let status):
            return "Failed to load from Keychain (status: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain (status: \(status))"
        }
    }
}
