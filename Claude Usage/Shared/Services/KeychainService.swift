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

    /// Saves a per-profile credential string to the Keychain
    /// - Parameters:
    ///   - value: The credential string to save
    ///   - profileId: The UUID of the profile
    ///   - key: A short key name (e.g. "claude-key", "api-key", "cli-creds")
    func saveProfileCredential(_ value: String, profileId: UUID, key: String) {
        guard let data = value.data(using: .utf8) else {
            LoggingService.shared.logError("Keychain: Invalid UTF-8 data for profile credential \(key)")
            return
        }

        let service = "com.claudewidget.\(key)-\(profileId.uuidString)"
        let account = "profile-credential"

        // First, try to update existing item
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            LoggingService.shared.log("Keychain: Updated profile credential \(key) for \(profileId.uuidString.prefix(8))")
            return
        }

        // If update fails because item doesn't exist, add a new item with a
        // permissive ACL so a changed code signature never triggers a prompt.
        if updateStatus == errSecItemNotFound {
            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrSynchronizable as String: false
            ]

            if let access = makeUnrestrictedAccess(label: "Claude Usage credential") {
                addQuery[kSecAttrAccess as String] = access
            } else {
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            }

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

            if addStatus == errSecSuccess {
                LoggingService.shared.log("Keychain: Added profile credential \(key) for \(profileId.uuidString.prefix(8))")
            } else {
                LoggingService.shared.logError("Keychain: Failed to save profile credential \(key), status: \(addStatus)")
            }
        } else {
            LoggingService.shared.logError("Keychain: Failed to update profile credential \(key), status: \(updateStatus)")
        }
    }

    /// Loads a per-profile credential string from the Keychain
    /// - Parameters:
    ///   - profileId: The UUID of the profile
    ///   - key: A short key name (e.g. "claude-key", "api-key", "cli-creds")
    /// - Returns: The stored credential string, or nil if not found
    func loadProfileCredential(profileId: UUID, key: String) -> String? {
        let service = "com.claudewidget.\(key)-\(profileId.uuidString)"
        let account = "profile-credential"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        } else {
            return nil
        }
    }

    /// Deletes all per-profile credentials from the Keychain
    /// - Parameter profileId: The UUID of the profile whose credentials should be deleted
    func deleteProfileCredentials(profileId: UUID) {
        for key in ["claude-key", "api-key", "cli-creds", "codex-creds"] {
            let service = "com.claudewidget.\(key)-\(profileId.uuidString)"
            let account = "profile-credential"

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]

            let status = SecItemDelete(query as CFDictionary)

            if status == errSecSuccess {
                LoggingService.shared.log("Keychain: Deleted profile credential \(key) for \(profileId.uuidString.prefix(8))")
            } else if status != errSecItemNotFound {
                LoggingService.shared.logError("Keychain: Failed to delete profile credential \(key), status: \(status)")
            }
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
