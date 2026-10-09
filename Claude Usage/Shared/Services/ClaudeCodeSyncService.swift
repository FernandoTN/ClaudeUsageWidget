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

    // MARK: - Test Seams (Debug builds only)

    /// One half of the CLI's credential store, as found.
    enum StoreHalf: Equatable {
        /// Conclusively not there (no Keychain item, no file).
        case absent
        /// There, but it could not be read — what it holds is unknown.
        case unreadable
        /// The raw payload (valid JSON or not).
        case contents(String)
    }

    /// XCTest stand-in for the Claude Code CLI's store: the shared Keychain
    /// item, `~/.claude/.credentials.json` and the account metadata in
    /// `~/.claude.json`. Every read of the store goes through `readHalves`, and
    /// each half is written on its own (`writeKeychain`, `writeFile`).
    ///
    /// FAIL CLOSED: in a Debug build under XCTest an empty in-memory stand-in
    /// is installed by default, and `setCLIStoreForTesting(nil)` puts a fresh
    /// one back, so no test reaches the real store — there is no opt-in. The
    /// real primitives below refuse under XCTest as a backstop
    /// (`RealCredentialStoreGuard`). A Release build has no stand-in storage
    /// and no setters: `cliStoreSeams` is the constant nil there, so it uses the
    /// real store whatever the environment says.
    struct CLIStoreSeams {
        var readHalves: () -> (keychain: StoreHalf, file: StoreHalf)
        var writeKeychain: (String) -> Bool
        var writeFile: (String) -> Bool
        var cachedAccountUUID: () -> String? = { nil }
        var writeAccountMetadata: (_ accountUUID: String, _ email: String, _ organizationUUID: String) -> Void = { _, _, _ in }
    }

    #if DEBUG
    /// Static and `nonisolated(unsafe)` because the store is read and written
    /// off the main actor (`applyProfileCredentials` runs on a background queue).
    nonisolated(unsafe) private static var cliStoreSeams: CLIStoreSeams? =
        RealCredentialStoreGuard.isTestRun ? CLIStoreSeams.inMemory() : nil

    /// XCTest stand-in for the token endpoint: receives the refresh token being
    /// redeemed, returns the HTTP status and JSON payload. No test redeems a
    /// real refresh token.
    private var tokenEndpointForTesting: ((String) async -> (status: Int, payload: [String: Any]?))?

    /// XCTest stand-in for the account-identity endpoint.
    private var identityFetcherForTesting: ((String) async -> AccountIdentity?)?

    /// Installs a test's own stand-in; nil restores a fresh empty one. Never
    /// the real store.
    func setCLIStoreForTesting(_ seams: CLIStoreSeams?) {
        Self.cliStoreSeams = seams ?? CLIStoreSeams.inMemory()
    }

    func setTokenEndpointForTesting(_ endpoint: ((String) async -> (status: Int, payload: [String: Any]?))?) {
        tokenEndpointForTesting = endpoint
    }

    func setIdentityFetcherForTesting(_ fetcher: ((String) async -> AccountIdentity?)?) {
        identityFetcherForTesting = fetcher
    }
    #else
    private static let cliStoreSeams: CLIStoreSeams? = nil
    private let tokenEndpointForTesting: ((String) async -> (status: Int, payload: [String: Any]?))? = nil
    private let identityFetcherForTesting: ((String) async -> AccountIdentity?)? = nil
    #endif

    // MARK: - The CLI Store, Half by Half

    /// Serializes every write this app makes to the CLI's store — the
    /// activation's apply, the post-redemption repair, the file heal — so a
    /// repair's read-compare-write can never interleave with an apply.
    nonisolated private static let cliStoreWriteLock = NSLock()

    /// Both halves of the CLI's store as found. Shells out to `security`: off
    /// the main actor only.
    private func readCLIStoreHalves() -> (keychain: StoreHalf, file: StoreHalf) {
        if let seams = Self.cliStoreSeams { return seams.readHalves() }
        return (readKeychainHalf(), readFileHalf())
    }

    private func readKeychainHalf() -> StoreHalf {
        if let seams = Self.cliStoreSeams { return seams.readHalves().keychain }
        do {
            guard let raw = try readKeychainCredentials() else { return .absent }
            return .contents(raw)
        } catch {
            return .unreadable
        }
    }

    /// The CLI's file (and the legacy `credentials.json`): absent only when
    /// neither exists; a file that exists but cannot be read is unreadable.
    private func readFileHalf() -> StoreHalf {
        if let seams = Self.cliStoreSeams { return seams.readHalves().file }
        if RealCredentialStoreGuard.refuse("read ~/.claude/.credentials.json") { return .unreadable }
        for fileURL in Self.credentialFileURLs where FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return .unreadable }
            LoggingService.shared.log("Read credentials from \(fileURL.lastPathComponent)")
            return .contents(text)
        }
        return .absent
    }

    private func writeKeychainHalf(_ json: String) -> Bool {
        if let seams = Self.cliStoreSeams { return seams.writeKeychain(json) }
        return updateSystemKeychainViaSecurityTool(json)
    }

    private func writeFileHalf(_ json: String) -> Bool {
        if let seams = Self.cliStoreSeams { return seams.writeFile(json) }
        return writeCredentialsFile(json)
    }

    /// What one half says about a refresh token: its fingerprint, `.none` when
    /// the half conclusively holds no token, `.unknown` when it cannot be told
    /// (unreadable, or a payload neither JSON nor carrying a complete token).
    enum HalfToken: Equatable {
        case none
        case token(String)
        case unknown
    }

    nonisolated static func refreshTokenFingerprint(in half: StoreHalf) -> HalfToken {
        switch half {
        case .absent:
            return .none
        case .unreadable:
            return .unknown
        case .contents(let raw):
            if let data = raw.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let token = (root["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String ?? ""
                return token.isEmpty ? .none : .token(ClaudeLoginLifetime.fingerprint(token))
            }
            // Not JSON (e.g. a Keychain payload `security` truncated): only a
            // complete, quoted token is evidence; anything else is unknown.
            guard let token = ClaudeLoginLifetime.refreshToken(raw), !token.isEmpty else { return .unknown }
            return .token(ClaudeLoginLifetime.fingerprint(token))
        }
    }

    // MARK: - System Credentials Access (Fallback Chain)

    /// Reads Claude Code credentials, preferring the source the CLI itself trusts:
    /// 1. System Keychain item — the CLI's source of truth. A CLI login or silent
    ///    token refresh updates ONLY this item, never the plaintext file.
    /// 2. ~/.claude/.credentials.json — the CLI's plaintext fallback. This app also
    ///    rewrites it on every profile switch, so it must never shadow a fresher
    ///    Keychain item (reading it first re-ingests our own stale write). The
    ///    file wins only when it is a DIFFERENT, later login (its deadline is
    ///    the later one); otherwise the Keychain does (`chooseSystemLogin`).
    /// 3. Regex extraction of accessToken from truncated Keychain data (last resort).
    ///
    /// A Keychain item holding the CLI's login-expired marker means the CLI has
    /// NO live login: nil is returned, never the file. The file is this app's
    /// own last write — the very pair the CLI just found consumed — and
    /// returning it let the switch-away re-sync save that consumed pair over
    /// the profile's live one (2026-10-02 and 2026-10-09).
    ///
    /// Shells out to `security` — never call on the main thread; use
    /// `readSystemCredentialsOffMain()` from main-actor contexts.
    func readSystemCredentials() throws -> String? {
        let halves = readCLIStoreHalves()
        var keychainRaw: String?
        var keychainError: Error?
        switch halves.keychain {
        case .contents(let raw): keychainRaw = raw
        case .unreadable: keychainError = ClaudeCodeError.keychainReadFailed(status: -1)
        case .absent: break
        }

        // Accept the keychain payload only if it is complete, valid JSON
        var keychainJSON: String?
        if let raw = keychainRaw,
           let data = raw.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil {
            keychainJSON = raw
        }

        var fileJSON: String?
        if case .contents(let raw) = halves.file,
           let data = raw.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil {
            fileJSON = raw
        }

        switch Self.chooseSystemLogin(keychain: keychainJSON, file: fileJSON, now: Date()) {
        case .keychainDeadMarker:
            LoggingService.shared.log("The CLI's Keychain login holds its login-expired marker — no live system login (the credentials file is not consulted)")
            return nil
        case .file:
            guard let file = fileJSON else { return nil }
            if let keychain = keychainJSON {
                LoggingService.shared.log("Using credentials file (a later login than the Keychain's: \(ClaudeLoginLifetime.summary(file)) vs \(ClaudeLoginLifetime.summary(keychain)))")
            } else {
                LoggingService.shared.log("Using credentials file (Keychain unavailable)")
            }
            return file
        case .keychain:
            guard let keychain = keychainJSON else { return nil }
            if fileJSON != nil {
                LoggingService.shared.log("Using system Keychain credentials (expires \(extractTokenExpiry(from: keychain) ?? .distantPast))")
            } else {
                LoggingService.shared.log("Using system Keychain credentials (no credentials file)")
            }
            return keychain
        case .none:
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

    /// Which half of the CLI's store holds its current login.
    enum SystemLoginChoice: Equatable {
        case keychain
        case file
        /// The Keychain holds the CLI's login-expired marker: no live login.
        case keychainDeadMarker
        /// Neither half holds valid JSON.
        case none
    }

    /// The store read's decision, pure. Both arguments are complete, valid JSON
    /// or nil. When both halves hold a login, the file wins only when it is a
    /// DIFFERENT, later login — both deadlines known and the file's later by
    /// more than the same-login tolerance. Otherwise the Keychain wins: it is
    /// the store the CLI itself reads first and writes, and the file is this
    /// app's own last write.
    nonisolated static func chooseSystemLogin(keychain: String?, file: String?, now: Date) -> SystemLoginChoice {
        if let keychain, ClaudeLoginLifetime.isDeadMarker(keychain) { return .keychainDeadMarker }
        guard let keychain else {
            guard let file, !ClaudeLoginLifetime.isDeadMarker(file) else { return .none }
            return .file
        }
        guard let file, !ClaudeLoginLifetime.isDeadMarker(file) else { return .keychain }
        if let fileDeadline = ClaudeLoginLifetime.deadline(file),
           let keychainDeadline = ClaudeLoginLifetime.deadline(keychain),
           fileDeadline.timeIntervalSince(keychainDeadline) > ClaudeLoginLifetime.sameLoginDeadlineTolerance {
            return .file
        }
        return .keychain
    }

    /// Rewrites ~/.claude/.credentials.json from the shared Keychain item when
    /// the file has drifted. The CLI writes /login results and silent refreshes
    /// ONLY to the Keychain, while this app rewrites the file only on profile
    /// switches — so a CLI-side /login leaves the file holding the PREVIOUS
    /// account's token, and headless `claude --bg` sessions, which read the
    /// FILE, stay stuck presenting an old (possibly exhausted) login (real
    /// incident 2026-07-17: the whole background fleet kept erroring on an
    /// exhausted account's session limit after a /login to a fresh one).
    ///
    /// The file is ONLY overwritten with a Keychain payload the widget has
    /// already reconciled as the active account's login — byte-equal to the
    /// active Claude profile's stored credentials (`expectedKeychainJSON`,
    /// captured on the main actor together with the not-switching check). The
    /// original expiry-based tiebreak is deliberately GONE: it raced
    /// activateProfile's two-store write and rewrote a freshly applied login
    /// back to the OUTGOING account's token, after which identity adoption
    /// flipped the active pointer backwards (second real incident,
    /// 2026-07-17: switch to one account left the file on the previous one).
    /// Shells out to `security` — never call on the main thread.
    private func healCredentialsFileFromKeychain(expectedKeychainJSON: String) {
        Self.cliStoreWriteLock.lock()
        defer { Self.cliStoreWriteLock.unlock() }
        guard case .contents(let raw) = readKeychainHalf(),
              raw == expectedKeychainJSON,
              let data = raw.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else { return }
        if case .contents(let file) = readFileHalf(), file == raw { return }
        guard writeFileHalf(raw) else { return }
        LoggingService.shared.log("ClaudeCodeSyncService: credentials file was stale vs the Keychain login — healed so file-reading sessions see the current account")
    }

    /// Off-main wrapper for `healCredentialsFileFromKeychain` (same suspension
    /// pattern as readSystemCredentialsOffMain). Captures the switch-in-flight
    /// state and the active Claude profile's stored credentials ON THE MAIN
    /// ACTOR before hopping off — no-op while a switch is rewriting the
    /// stores, or when the widget has not yet reconciled the Keychain's login
    /// into a profile (identity adoption runs first each sweep).
    func healCredentialsFileFromKeychainOffMain() async {
        let manager = ProfileManager.shared
        guard !manager.isSwitchingProfile,
              let activeClaudeId = manager.activeClaudeProfileId,
              let expected = manager.profiles.first(where: { $0.id == activeClaudeId })?.cliCredentialsJSON else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                self.healCredentialsFileFromKeychain(expectedKeychainJSON: expected)
                continuation.resume()
            }
        }
    }

    // MARK: - Private Credential Sources

    /// The CLI's credentials file, then the legacy name.
    nonisolated private static let credentialFileURLs = [
        Constants.ClaudePaths.claudeDirectory.appendingPathComponent(".credentials.json"),
        Constants.ClaudePaths.claudeDirectory.appendingPathComponent("credentials.json")
    ]

    /// Reads Claude Code credentials from system Keychain using security command
    private func readKeychainCredentials() throws -> String? {
        // Refused under XCTest as unreadable, never as absent: absent would
        // read as "the CLI holds no token" and let a redemption through.
        if RealCredentialStoreGuard.refuse("read the Claude Code-credentials Keychain item") {
            throw ClaudeCodeError.keychainReadFailed(status: -1)
        }
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
        if RealCredentialStoreGuard.refuse("look up the Claude Code-credentials Keychain item") { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", serviceName, "-a", NSUserName()]
        // Output is unused — null devices, never undrained Pipes: a child that
        // fills an unread pipe buffer blocks forever under waitUntilExit.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
        if RealCredentialStoreGuard.refuse("dump the login Keychain") { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["dump-keychain"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        // stderr must not be an undrained Pipe: if the child fills it, it
        // blocks writing and stdout never reaches EOF (Codex review).
        process.standardError = FileHandle.nullDevice

        // Drain stdout to EOF BEFORE waitUntilExit: dump-keychain output easily
        // exceeds the 64KB pipe buffer, and waiting first deadlocks — the child
        // blocks writing a full pipe while we block waiting for it to exit.
        let outputData: Data
        do {
            try process.run()
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: outputData, encoding: .utf8) ?? ""
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
        Self.cliStoreWriteLock.lock()
        defer { Self.cliStoreWriteLock.unlock() }
        // Best-effort as before: an apply that half-failed is caught by the
        // activation's own handling and by the identity adoption at sweep end.
        _ = writeFileHalf(jsonData)
        _ = writeKeychainHalf(jsonData)
    }

    /// Updates the `Claude Code-credentials` Keychain item via the `security` CLI.
    /// Returns whether the tool reported success.
    @discardableResult
    private func updateSystemKeychainViaSecurityTool(_ jsonData: String) -> Bool {
        if RealCredentialStoreGuard.refuse("write the Claude Code-credentials Keychain item") { return false }
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
                return true
            }
            let err = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            LoggingService.shared.log("security CLI keychain update failed (status \(process.terminationStatus)): \(err)")
        } catch {
            LoggingService.shared.logError("Failed to launch security CLI for keychain update", error: error)
        }
        return false
    }

    /// Writes credentials to ~/.claude/.credentials.json. Returns whether the
    /// write succeeded. Keeps the file in sync with the system keychain so that
    /// readSystemCredentials() and Claude Code CLI both see the active
    /// profile's credentials.
    @discardableResult
    private func writeCredentialsFile(_ jsonData: String) -> Bool {
        if RealCredentialStoreGuard.refuse("write ~/.claude/.credentials.json") { return false }
        let fileURL = Constants.ClaudePaths.credentialsFile
        let dirURL = Constants.ClaudePaths.claudeDirectory

        // Ensure ~/.claude/ directory exists
        if !FileManager.default.fileExists(atPath: dirURL.path) {
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            } catch {
                LoggingService.shared.logError("Failed to create .claude directory: \(error.localizedDescription)")
                return false
            }
        }

        do {
            try jsonData.write(to: fileURL, atomically: true, encoding: .utf8)
            LoggingService.shared.log("Wrote credentials to \(fileURL.lastPathComponent)")
            return true
        } catch {
            LoggingService.shared.logError("Failed to write credentials file (non-fatal): \(error.localizedDescription)")
            return false
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

        // DUPLICATE-ACCOUNT GUARD (the Claude twin of Codex's account_id check):
        // syncing one Anthropic account into two profiles gives it two tiles for
        // ONE quota, doubles its fetch load against an endpoint that rate-limits
        // per account, and puts both copies in the same auto-switch group.
        //
        // It keys on ANOTHER profile holding the incoming account — never on
        // this profile's own previous account. An explicit sync bringing a
        // DIFFERENT account into this profile is the documented repair ("/login
        // with that account, then re-sync"), and refusing that would block the
        // only way out of a dead login.
        //
        // Evidence is the CLI's own record of who it is logged in as
        // (~/.claude.json), the exact parallel of Codex reading account_id out
        // of auth.json: local, non-secret, no network on a user-blocking path.
        // Absent or unreadable is NO EVIDENCE and permits the sync — the forced
        // re-stamp that follows every sync then surfaces a duplicate through
        // ProfileManager.duplicateClaudeAccountGroups.
        if let incoming = cliCachedAccountUUID(),
           let holder = Self.duplicateAccountHolder(
               accountUUID: incoming,
               target: profileId,
               profiles: profiles,
               accountUUIDOf: { $0.claudeAccountUUID }
           ) {
            LoggingService.shared.log("⛔️ Claude sync refused: account \(String(incoming.prefix(8))) is already held by '\(holder.name)'")
            throw ClaudeCodeError.accountAlreadySynced(profileName: holder.name)
        }

        profiles[index].cliCredentialsJSON = jsonData
        // An explicit sync may bring a DIFFERENT account's login (the user can
        // /login anywhere between syncs) — the old identity stamp no longer
        // applies. Cleared here; callers re-stamp asynchronously.
        profiles[index].claudeAccountUUID = nil
        profiles[index].claudeAccountEmail = nil
        profiles[index].claudeOrganizationUUID = nil
        // Explicit: the user chose this login for this profile, even when it
        // expires before the one it replaces (a different account's `/login`).
        ProfileStore.shared.saveProfiles(profiles, explicitCLILoginWrite: profileId)
        reloginNotifiedProfiles.remove(profileId)
        // Whatever this profile held before, it now holds the login the user
        // just chose for it — the old contamination verdict no longer describes
        // it. The re-stamp that follows re-derives the truth either way.
        markLoginUncontaminated(profileId)

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

        // Keep the CLI's DISPLAYED account in sync with the applied login (uses the
        // profile's stamped identity; skipped when the identity is not yet known —
        // the stamp task that follows every apply fills it for next time).
        if let uuid = profile.claudeAccountUUID {
            updateCLIAccountMetadata(
                accountUUID: uuid,
                email: profile.claudeAccountEmail ?? "",
                organizationUUID: profile.claudeOrganizationUUID ?? ""
            )
        }

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
        // saveProfiles never deletes on nil (stale-save protection) — remove explicitly.
        ProfileStore.shared.clearProfileCredential(profileId, key: .cliCredentials)

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

    /// Single JSON parse of the `claudeAiOauth` object — shared by token-field extractors.
    private func parseClaudeAiOauth(from jsonData: String) -> [String: Any]? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        return oauth
    }

    /// Extracts the token expiry date from CLI credentials JSON
    func extractTokenExpiry(from jsonData: String) -> Date? {
        guard let oauth = parseClaudeAiOauth(from: jsonData),
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
        guard let oauth = parseClaudeAiOauth(from: jsonData),
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

        let statusCode: Int
        let responsePayload: [String: Any]?
        if let endpoint = tokenEndpointForTesting {
            (statusCode, responsePayload) = await endpoint(refreshToken)
        } else {
            // No test redeems a refresh token over the network.
            if RealCredentialStoreGuard.refuse("token endpoint (refresh_token grant)") {
                throw ClaudeCodeError.tokenRefreshFailed(status: -1)
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
            statusCode = httpResponse.statusCode
            responsePayload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        }
        guard statusCode == 200,
              let payload = responsePayload,
              let accessToken = payload["access_token"] as? String else {
            LoggingService.shared.log("OAuth token refresh failed (HTTP \(statusCode))")
            throw ClaudeCodeError.tokenRefreshFailed(status: statusCode)
        }

        oauth["accessToken"] = accessToken
        if let rotated = payload["refresh_token"] as? String {
            oauth["refreshToken"] = rotated
        }
        if let expiresIn = payload["expires_in"] as? Double, expiresIn.isFinite {
            // CLI stores expiresAt as integer milliseconds since epoch.
            // `clampedInt` because the value is server-supplied and `Int(_:)`
            // traps outside Int64's range (audit H3).
            oauth["expiresAt"] = clampedInt((Date().timeIntervalSince1970 + expiresIn) * 1000.0)
        }
        if let scope = payload["scope"] as? String, !scope.isEmpty {
            oauth["scopes"] = scope.components(separatedBy: " ")
        }
        // The login's server deadline, stored the way the CLI stores it (from
        // `refresh_token_expires_in`, in milliseconds; the previous value is
        // kept when a response carries none). The deadline check reads this
        // field, so a refresh the widget performs must not leave it stale.
        if let lifetime = (payload["refresh_token_expires_in"] as? NSNumber)?.doubleValue,
           lifetime.isFinite, lifetime > 0 {
            oauth["refreshTokenExpiresAt"] = clampedInt((Date().timeIntervalSince1970 + lifetime) * 1000.0)
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
    ///    item always belongs to the ACTIVE account — adopt it if it is NEWER
    ///    (`ClaudeLoginLifetime.isNewer`).
    /// 2. If the token is still expired (or about to), redeem the refresh token via
    ///    the OAuth endpoint — when `ClaudeRefreshPolicy.decide` allows it.
    ///
    /// NEVER REDEEM A LOGIN THE CLI HOLDS. Redeeming a Claude refresh token
    /// revokes the access token issued with it at once, and the CLI process can
    /// be redeeming the same token concurrently. So the redemption point refuses
    /// when either half of the CLI's store holds this refresh token right now
    /// (or cannot be conclusively read), when the pointer names this profile,
    /// and while an activation is handing this login — or any profile sharing
    /// its refresh token — over. The CLI renews its own login; step 1 adopts
    /// the result. A login refused that way whose access token has expired is
    /// AWAITING CLI RENEWAL (`isAwaitingCLIRenewal`): its usage is shown stale,
    /// it is never flagged dead and never switched away from for that reason.
    ///
    /// Every store write is a compare-and-swap (`ProfileStore.replaceCLILogin`):
    /// a rotated pair is stored only if the profile still holds the pair that
    /// was redeemed, so a `/login` synced in while the request was in flight is
    /// never overwritten. Profiles that share the consumed refresh token get
    /// the rotated pair too (each by its own CAS) — the token they hold is dead.
    /// The CLI's store gets it only as a guarded repair (`repairCLIStore`).
    ///
    /// The mutex is keyed by profile AND by refresh-token fingerprint, so two
    /// profiles holding one login can never redeem it twice.
    ///
    /// `freshFor` is how long the access token must remain valid before a refresh is
    /// attempted (default 2 minutes; the candidate preflight and the activation pass
    /// `ClaudeRefreshPolicy.handoffFreshness`). `role: .handoff` is the activation
    /// renewing the login it is about to apply: it WAITS for a redemption already
    /// in flight for the same profile or token instead of skipping it.
    /// Returns true if THIS call changed the stored credentials and every repair
    /// it needed landed. A hand-off that waited on another caller's redemption can
    /// get false back while the store now holds a rotated pair, so it must re-read
    /// the store either way.
    func ensureFreshCredentials(
        for profileId: UUID,
        adoptSystemKeychain: Bool,
        freshFor: TimeInterval = ClaudeRefreshPolicy.healWindow,
        role: ClaudeRefreshPolicy.Role = .maintenance
    ) async -> Bool {
        // Per-profile and per-token mutex: the sweep, the milestone preflight
        // and a profile activation can all try to heal the same login
        // concurrently. Two concurrent redemptions of the SAME refresh token make
        // the loser 4xx — indistinguishable from a revoked token, spuriously
        // flagging the account dead. Maintenance callers skip a redemption in
        // flight. A hand-off waits for it: skipping is how a switch applied the
        // very pair a preflight was redeeming at that moment (2026-10-02).
        var profile: Profile
        var claimedToken: String?
        while true {
            guard let loaded = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
                  let json = loaded.cliCredentialsJSON else {
                return false
            }
            let token = Self.refreshTokenFingerprint(of: json)
            if refreshInFlight.contains(profileId) || (token.map { refreshInFlightTokens.contains($0) } ?? false) {
                guard role == .handoff else { return false }
                parkedHandoffs.insert(profileId)
                await waitForAnyRefreshToFinish()
                parkedHandoffs.remove(profileId)
                continue  // re-read: the redemption we waited on may have rotated it
            }
            profile = loaded
            claimedToken = token
            refreshInFlight.insert(profileId)
            if let token { refreshInFlightTokens.insert(token) }
            break
        }
        defer { finishRefresh(profileId, token: claimedToken) }

        guard var storedJSON = profile.cliCredentialsJSON else { return false }
        var changed = false

        if adoptSystemKeychain,
           let systemJSON = try? await readSystemCredentialsOffMain(),
           ClaudeLoginLifetime.isNewer(systemJSON, than: storedJSON, now: Date()),
           await adoptionAccountMatches(profileId: profileId, systemJSON: systemJSON) {
            if ProfileStore.shared.replaceCLILogin(profileId, expected: storedJSON, with: systemJSON) {
                storedJSON = systemJSON
                changed = true
                reloginNotifiedProfiles.remove(profileId)  // fresh login arrived — re-arm
                awaitingCLIRenewal.remove(profileId)
                LoggingService.shared.log("ensureFreshCredentials: adopted newer login from system Keychain (\(ClaudeLoginLifetime.summary(systemJSON)))")
            } else {
                LoggingService.shared.log("ensureFreshCredentials: did not adopt the CLI's login into '\(profile.name)' — its stored login changed meanwhile")
            }
        }

        let expiry = extractTokenExpiry(from: storedJSON) ?? .distantPast
        let refreshToken = ClaudeLoginLifetime.refreshToken(storedJSON) ?? ""
        // Back off dead logins: a revoked refresh token cannot heal itself, so
        // don't redeem it again on every sweep (that was 120 failed calls/hour).
        // The flag re-arms when fresh credentials arrive via re-sync/adoption.
        let canRedeem = !refreshToken.isEmpty && !reloginNotifiedProfiles.contains(profileId)
        let consumed = refreshToken.isEmpty ? nil : ClaudeLoginLifetime.fingerprint(refreshToken)
        var decision = ClaudeRefreshPolicy.Decision.notNeeded
        if canRedeem, let consumed, expiry.timeIntervalSinceNow < freshFor {
            // Read the CLI's store only when a redemption is otherwise due. The
            // decision follows with no await in between, so the ownership and
            // hand-off state it reads is the state the request is sent under.
            let held = await cliStoreHoldsOffMain(consumed)
            decision = ClaudeRefreshPolicy.decide(
                timeLeft: expiry.timeIntervalSinceNow,
                freshFor: freshFor,
                canRedeem: canRedeem,
                cliHoldsThisLogin: held,
                ownsCLILogin: ProfileManager.shared.isExplicitClaudeOwner(profileId),
                handoffInFlight: handoffsInFlight.contains(profileId) || handoffHolds(consumed, other: profileId),
                role: role
            )
            if decision == .refuseHandedOff {
                let reason = held == nil
                    ? "the CLI's store could not be conclusively read"
                    : "the CLI holds, owns or is being handed this login"
                LoggingService.shared.log("ensureFreshCredentials: NOT redeeming '\(profile.name)' — \(reason); a redemption would revoke the access token its sessions use (\(ClaudeLoginLifetime.summary(storedJSON)))")
            }
        }

        // Awaiting CLI renewal: refused because the CLI holds (or may hold) the
        // login, with the access token already spent. Not dead — the CLI renews
        // it the next time it runs, and the adoption above picks that up.
        if decision == .refuseHandedOff, expiry <= Date() {
            if awaitingCLIRenewal.insert(profileId).inserted {
                LoggingService.shared.log("ensureFreshCredentials: '\(profile.name)' is awaiting the CLI's own renewal — usage stays stale until then; not a dead login")
            }
        } else if expiry > Date() || decision == .redeem || changed {
            awaitingCLIRenewal.remove(profileId)
        }

        var repairFailed = false
        if decision == .redeem, let consumed {
            var successor: String?
            do {
                successor = try await refreshOAuthToken(credentialsJSON: storedJSON)
            } catch {
                LoggingService.shared.logError("ensureFreshCredentials: OAuth token refresh failed (non-fatal)", error: error)
                if case ClaudeCodeError.tokenRefreshFailed(let status) = error,
                   status == 400 || status == 401 || status == 403 {
                    // The stored refresh token is revoked — unrecoverable app-side.
                    notifyReloginNeeded(for: profileId)
                }
            }
            if let successor {
                // Compare-and-swap: store the successor only over the pair that
                // was redeemed. A login synced in while the request was in
                // flight wins, and the successor is discarded.
                if ProfileStore.shared.replaceCLILogin(profileId, expected: storedJSON, with: successor) {
                    storedJSON = successor
                    changed = true
                    reloginNotifiedProfiles.remove(profileId)
                    awaitingCLIRenewal.remove(profileId)
                } else {
                    LoggingService.shared.log("ensureFreshCredentials: discarded '\(profile.name)''s rotated pair — its stored login changed while the refresh was in flight (\(ClaudeLoginLifetime.summary(successor)))")
                }
                // Every other profile still holding the consumed token now holds
                // a dead one; the successor is its only continuation.
                shareRotation(of: consumed, successor: successor, except: profileId)
                // The redemption CONSUMED the old refresh token — make sure the
                // rotated one is on disk before anything else can kill the process.
                await ProfileStore.shared.flushKeychainWrites()
                // Repair only: the CLI gets the successor if, and only where, it
                // holds the consumed token.
                if await repairCLIStoreOffMain(consumed: consumed, successor: successor) == .failed {
                    pendingCLIRepairs[consumed] = successor
                    repairFailed = true
                    LoggingService.shared.log("ensureFreshCredentials: the CLI's store may hold '\(profile.name)''s consumed token and could not be repaired — retrying at the next sweep")
                }
            }
        }

        guard changed else { return false }
        var profiles = ProfileStore.shared.loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].cliAccountSyncedAt = Date()
            ProfileStore.shared.saveProfiles(profiles)
        }
        return !repairFailed
    }

    /// Gives every OTHER profile that still holds the consumed refresh token
    /// the successor, each by its own compare-and-swap.
    private func shareRotation(of consumed: String, successor: String, except redeemer: UUID) {
        var shared: [String] = []
        for alias in ProfileStore.shared.loadProfiles() where alias.id != redeemer {
            guard let json = alias.cliCredentialsJSON,
                  Self.refreshTokenFingerprint(of: json) == consumed,
                  ProfileStore.shared.replaceCLILogin(alias.id, expected: json, with: successor) else { continue }
            reloginNotifiedProfiles.remove(alias.id)
            awaitingCLIRenewal.remove(alias.id)
            shared.append(alias.name)
        }
        if !shared.isEmpty {
            LoggingService.shared.log("ensureFreshCredentials: shared the rotated pair with \(shared.count) profile(s) holding the same login: \(shared.joined(separator: ", "))")
        }
    }

    nonisolated static func refreshTokenFingerprint(of json: String) -> String? {
        guard let token = ClaudeLoginLifetime.refreshToken(json), !token.isEmpty else { return nil }
        return ClaudeLoginLifetime.fingerprint(token)
    }

    // MARK: - The CLI Holds This Token

    /// Whether either half of the CLI's store holds the refresh token with this
    /// fingerprint: true, false, or nil when a half could not be conclusively
    /// inspected (unreadable, or a payload with no complete token) — which the
    /// redemption point treats as held. Off the main actor only.
    private func cliStoreHolds(_ fingerprint: String) -> Bool? {
        let halves = readCLIStoreHalves()
        let tokens = [Self.refreshTokenFingerprint(in: halves.keychain), Self.refreshTokenFingerprint(in: halves.file)]
        if tokens.contains(.token(fingerprint)) { return true }
        if tokens.contains(.unknown) { return nil }
        return false
    }

    private func cliStoreHoldsOffMain(_ fingerprint: String) async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.cliStoreHolds(fingerprint))
            }
        }
    }

    // MARK: - CLI Store Repair

    enum RepairOutcome: Equatable {
        /// Neither half held the consumed token: nothing to do.
        case notNeeded
        /// Every half that held it now holds the successor (read back).
        case repaired
        /// A half that held it — or might, being unreadable — was not
        /// repaired and verified.
        case failed
    }

    /// Writes `successor` into each half of the CLI's store that holds the
    /// CONSUMED token, half by half: re-read that half, compare, write it,
    /// read it back. A file-only match never authorizes a Keychain write, and
    /// the reverse. Runs under the store write lock, so it cannot interleave
    /// with an activation's apply. Off the main actor only.
    private func repairCLIStore(consumed: String, successor: String) -> RepairOutcome {
        guard let successorToken = Self.refreshTokenFingerprint(of: successor) else { return .failed }
        Self.cliStoreWriteLock.lock()
        defer { Self.cliStoreWriteLock.unlock() }

        var outcome = RepairOutcome.notNeeded
        let halves: [(name: String, read: () -> StoreHalf, write: (String) -> Bool)] = [
            ("Keychain item", { self.readKeychainHalf() }, { self.writeKeychainHalf($0) }),
            ("credentials file", { self.readFileHalf() }, { self.writeFileHalf($0) })
        ]
        for half in halves {
            switch Self.refreshTokenFingerprint(in: half.read()) {
            case .token(consumed):
                guard half.write(successor),
                      Self.refreshTokenFingerprint(in: half.read()) == .token(successorToken) else {
                    LoggingService.shared.log("ClaudeCodeSyncService: repair of the CLI's \(half.name) did not land")
                    return .failed
                }
                LoggingService.shared.log("ClaudeCodeSyncService: the CLI's \(half.name) held a consumed token — wrote its rotated successor")
                outcome = .repaired
            case .unknown:
                return .failed
            case .token, .none:
                break
            }
        }
        return outcome
    }

    private func repairCLIStoreOffMain(consumed: String, successor: String) async -> RepairOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<RepairOutcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.repairCLIStore(consumed: consumed, successor: successor))
            }
        }
    }

    /// Repairs that did not land, by consumed-token fingerprint → successor.
    /// Retried under the same per-half compare-and-swap; an entry goes once its
    /// repair lands or no half holds the consumed token any more.
    private var pendingCLIRepairs: [String: String] = [:]

    /// Retries every pending repair (sweep end).
    func retryPendingCLIRepairs() async {
        for (consumed, successor) in pendingCLIRepairs {
            switch await repairCLIStoreOffMain(consumed: consumed, successor: successor) {
            case .repaired, .notNeeded:
                pendingCLIRepairs.removeValue(forKey: consumed)
                LoggingService.shared.log("ClaudeCodeSyncService: a pending CLI-store repair is resolved")
            case .failed:
                break
            }
        }
    }

    // MARK: - Awaiting CLI Renewal

    /// Logins refused a redemption because the CLI holds (or may hold) them,
    /// whose access token has expired. See `ensureFreshCredentials`.
    private var awaitingCLIRenewal: Set<UUID> = []

    /// True while this profile's login waits for the CLI to renew it: show its
    /// usage stale, never flag it dead, never switch away from it for that.
    func isAwaitingCLIRenewal(_ profileId: UUID) -> Bool {
        awaitingCLIRenewal.contains(profileId)
    }

    // MARK: - Hand-off State

    /// Profiles whose login an activation is handing to the CLI right now,
    /// from its pre-apply renewal until the provider pointer is claimed (or the
    /// apply is refused). Nothing but that activation may redeem their refresh
    /// token in that window — nor the token of any profile that shares it
    /// (`handoffHolds`) — because the apply runs off the main actor, and a
    /// redemption landing between it and the claim is exactly the
    /// apply-then-rotate sequence that killed two logins on 2026-10-08/09.
    private var handoffsInFlight: Set<UUID> = []

    func beginHandoff(_ profileId: UUID) {
        handoffsInFlight.insert(profileId)
    }

    func endHandoff(_ profileId: UUID) {
        handoffsInFlight.remove(profileId)
    }

    func isHandoffInFlight(_ profileId: UUID) -> Bool {
        handoffsInFlight.contains(profileId)
    }

    /// Whether a profile OTHER than `other` with a hand-off in flight holds the
    /// refresh token with this fingerprint — a hand-off of A blocks a
    /// redemption of an alias B that shares A's login.
    private func handoffHolds(_ fingerprint: String, other: UUID) -> Bool {
        guard handoffsInFlight.contains(where: { $0 != other }) else { return false }
        return ProfileStore.shared.loadProfiles().contains { candidate in
            candidate.id != other && handoffsInFlight.contains(candidate.id)
                && candidate.cliCredentialsJSON.flatMap(Self.refreshTokenFingerprint(of:)) == fingerprint
        }
    }

    // MARK: - Redemption Mutex

    /// Profiles with a heal in flight, and the refresh tokens (by fingerprint)
    /// being redeemed — two profiles sharing one login share one slot.
    private var refreshInFlight: Set<UUID> = []
    private var refreshInFlightTokens: Set<String> = []

    /// Hand-offs parked behind a redemption in flight. Woken on every finish;
    /// each re-checks whether its own profile and token are free.
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var parkedHandoffs: Set<UUID> = []

    private func waitForAnyRefreshToFinish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            refreshWaiters.append(continuation)
        }
    }

    private func finishRefresh(_ profileId: UUID, token: String?) {
        refreshInFlight.remove(profileId)
        if let token { refreshInFlightTokens.remove(token) }
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    #if DEBUG
    /// True while a hand-off is parked behind a redemption in flight — lets a
    /// test wait for that state instead of guessing a delay.
    func isHandoffParkedForTesting(_ profileId: UUID) -> Bool {
        parkedHandoffs.contains(profileId)
    }
    #endif
    // MARK: - Account Identity

    struct AccountIdentity {
        let accountUUID: String
        let organizationUUID: String
        let email: String
    }

    /// In-memory token → identity cache (identities are immutable per token;
    /// avoids refetching on every sweep). Keyed by a token suffix, never the
    /// token. Bounded: tokens rotate every few hours, so an unbounded cache
    /// grows by one dead entry per rotation for the life of the process.
    private var identityCache: [String: AccountIdentity] = [:]
    private var identityCacheOrder: [String] = []
    private static let identityCacheLimit = 64

    /// The account behind an OAuth access token, via api.anthropic.com/api/oauth/
    /// profile. The Claude credentials JSON carries NO account id (unlike Codex's
    /// account_id), so this endpoint is the only way to know WHOSE login a token
    /// is. Returns nil on any failure — callers must treat unknown identity as
    /// "no evidence", never as a mismatch.
    func fetchAccountIdentity(accessToken: String) async -> AccountIdentity? {
        if let fetch = identityFetcherForTesting { return await fetch(accessToken) }
        // No test sends a token to the identity endpoint.
        if RealCredentialStoreGuard.refuse("identity endpoint") { return nil }
        let cacheKey = String(accessToken.suffix(24))
        if let cached = identityCache[cacheKey] { return cached }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any],
              let accountUUID = account["uuid"] as? String else {
            return nil
        }
        let identity = AccountIdentity(
            accountUUID: accountUUID,
            organizationUUID: (json["organization"] as? [String: Any])?["uuid"] as? String ?? "",
            email: account["email"] as? String ?? ""
        )
        if identityCache[cacheKey] == nil {
            identityCacheOrder.append(cacheKey)
            if identityCacheOrder.count > Self.identityCacheLimit {
                identityCache.removeValue(forKey: identityCacheOrder.removeFirst())
            }
        }
        identityCache[cacheKey] = identity
        return identity
    }

    /// Persists the account identity behind a profile's stored CLI token so future
    /// adoptions can be account-matched and switches can update the CLI's cached
    /// account display. `force` overwrites (use after an explicit re-sync, where
    /// the account may have changed); otherwise stamps only missing identities.
    func stampAccountIdentity(for profileId: UUID, force: Bool = false) async {
        guard let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
              force || profile.claudeAccountUUID == nil || profile.claudeAccountEmail == nil,
              let json = profile.cliCredentialsJSON,
              let token = extractAccessToken(from: json),
              let identity = await fetchAccountIdentity(accessToken: token) else { return }

        var profiles = ProfileStore.shared.loadProfiles()
        // A profile that ALREADY carried a stamp and whose own token now reports
        // a different account did not change accounts by itself — something
        // wrote another account's login into it. Record that before the stamp is
        // healed to match the token, which is the line below that would
        // otherwise erase the only evidence. Agreement clears the flag.
        if let held = profiles.first(where: { $0.id == profileId })?.claudeAccountUUID, !held.isEmpty {
            if held == identity.accountUUID {
                markLoginUncontaminated(profileId)
            } else {
                markLoginContaminated(profileId, held: held, reported: identity.accountUUID)
            }
        }
        if let index = profiles.firstIndex(where: { $0.id == profileId }),
           profiles[index].claudeAccountUUID != identity.accountUUID
            || profiles[index].claudeAccountEmail != identity.email
            || profiles[index].claudeOrganizationUUID != identity.organizationUUID {
            profiles[index].claudeAccountUUID = identity.accountUUID
            profiles[index].claudeAccountEmail = identity.email.isEmpty ? nil : identity.email
            profiles[index].claudeOrganizationUUID = identity.organizationUUID.isEmpty ? nil : identity.organizationUUID
            ProfileStore.shared.saveProfiles(profiles)
            LoggingService.shared.log("Claude: stamped account identity for '\(profiles[index].name)'")
        }
    }

    // MARK: - Background Identity Stamping

    /// One profile's worth of the sweep-end identity pass, as plain values so
    /// the selection rule can be tested without a Keychain or a network.
    struct IdentityStampCandidate {
        let id: UUID
        /// False for anything the pass must not spend a request on: no stored
        /// login of its own, already stamped, flagged dead, or an expired
        /// access token (refreshing a background profile's token here would
        /// rotate a refresh token the CLI may still be holding).
        let isEligible: Bool
        /// When this profile's login was last synced. Oldest first; never
        /// synced (`nil`) sorts oldest of all, exactly like the background
        /// usage scheduler treats a never-attempted candidate.
        let syncedAt: Date?
    }

    /// The single profile this sweep will resolve an identity for: the oldest
    /// eligible unstamped login. One per sweep, so the pass costs at most one
    /// `api.anthropic.com` request per 30 s — well inside the per-IP budget the
    /// usage sweep already lives under — and costs NOTHING in steady state,
    /// because a stamped profile is never a candidate again.
    nonisolated static func selectIdentityStampId(candidates: [IdentityStampCandidate]) -> UUID? {
        candidates
            .filter(\.isEligible)
            .min { ($0.syncedAt ?? .distantPast) < ($1.syncedAt ?? .distantPast) }
            .map(\.id)
    }

    /// Resolves and persists the account identity of ONE unstamped Claude login
    /// per call, using that profile's OWN token.
    ///
    /// Why this exists: `stampAccountIdentity` only ever ran for the profile
    /// being APPLIED to the CLI, so a profile that was synced once and never
    /// activated carried no `claudeAccountUUID` at all — and every check built
    /// on that stamp (adoption matching, duplicate detection, the auto-switch's
    /// same-account skip) is blind on a nil. Two live profiles were found on
    /// 2026-09-03 holding logins for ONE Anthropic account, invisible to all of
    /// them because only one side was stamped.
    ///
    /// The identity endpoint is called with the PROFILE'S own stored token and
    /// never with the system Keychain fallback — that item always holds the
    /// ACTIVE account's login, so using it would stamp every unstamped profile
    /// with the active account's uuid and manufacture the very duplicates this
    /// pass is meant to find.
    ///
    /// Returns the profile stamped, or nil when there was nothing to do.
    @discardableResult
    func stampNextUnstampedIdentity() async -> UUID? {
        let profiles = ProfileStore.shared.loadProfiles()
        let candidates = profiles.map { profile in
            IdentityStampCandidate(
                id: profile.id,
                isEligible: isIdentityStampEligible(profile),
                syncedAt: profile.cliAccountSyncedAt
            )
        }
        guard let target = Self.selectIdentityStampId(candidates: candidates) else { return nil }
        await stampAccountIdentity(for: target)
        return target
    }

    /// Whether the background pass may spend a request on this profile.
    private func isIdentityStampEligible(_ profile: Profile) -> Bool {
        guard profile.carriesClaudeAccount,
              profile.claudeAccountUUID == nil,
              let json = profile.cliCredentialsJSON else { return false }
        guard !isLoginMarkedDead(profile.id) else { return false }
        // Expired means the only way to get a usable token is a refresh, and a
        // background refresh rotates the refresh token — the hazard the
        // candidate preflight is careful about. Wait for a path that already
        // refreshes this profile (activation, preflight, a manual sync).
        return !isTokenExpired(json)
    }

    /// Rewrites the CLI's cached account metadata (`oauthAccount` in ~/.claude.json)
    /// to match the login the app just applied. The CLI only updates this cache on
    /// a manual /login, so after an app-driven switch, /usage and /status would
    /// otherwise DISPLAY the previous account while every request runs as the new
    /// one — which is exactly the confusion that mislabeled a real incident.
    /// Best-effort and surgical: only the oauthAccount keys are touched.
    func updateCLIAccountMetadata(accountUUID: String, email: String, organizationUUID: String) {
        if let seams = Self.cliStoreSeams {
            seams.writeAccountMetadata(accountUUID, email, organizationUUID)
            return
        }
        if RealCredentialStoreGuard.refuse("write ~/.claude.json") { return }
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: fileURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var oauthAccount = root["oauthAccount"] as? [String: Any] else {
            return
        }
        guard (oauthAccount["accountUuid"] as? String) != accountUUID else { return }

        oauthAccount["accountUuid"] = accountUUID
        if !email.isEmpty { oauthAccount["emailAddress"] = email }
        if !organizationUUID.isEmpty { oauthAccount["organizationUuid"] = organizationUUID }
        // The org display name belongs to the OLD account — drop it rather than lie;
        // the CLI restores it on its next /login or profile fetch.
        oauthAccount["organizationName"] = email.isEmpty ? "" : "\(email)'s Organization"
        root["oauthAccount"] = oauthAccount

        guard let updated = try? JSONSerialization.data(withJSONObject: root) else { return }
        do {
            try updated.write(to: fileURL, options: .atomic)
            LoggingService.shared.log("Claude: updated CLI cached account metadata (oauthAccount) to match applied login")
        } catch {
            LoggingService.shared.logError("Claude: failed to update ~/.claude.json oauthAccount (non-fatal)", error: error)
        }
    }

    // MARK: - Identity-Verified Credential Writes

    /// What the write guard concludes for one (CLI login, target profile) pair.
    enum CredentialWriteDecision: Equatable {
        /// The identities agree: this profile really is the account behind the
        /// CLI's current login.
        case write
        /// They disagree: writing would move one account's token into another
        /// account's profile. Refuse.
        case refuse
        /// Neither side could be identified. Not a mismatch — the caller's own
        /// bookkeeping (the provider-active pointer) stands, as it always has.
        case noEvidence
    }

    /// The whole guard, as a pure decision over two identities.
    ///
    /// `stampedFromOwnToken` is what the identity pass learned from the TARGET
    /// PROFILE'S OWN token when the profile carried no stamp yet. Resolving the
    /// target that way — rather than accepting "unstamped" as permission — is
    /// the entire fix: an unstamped profile used to pass this guard on "no
    /// evidence either way", which is how the CLI's login was written into a
    /// profile holding a different account.
    nonisolated static func credentialWriteDecision(
        cliAccountUUID: String?,
        profileAccountUUID: String?,
        stampedFromOwnToken: String? = nil
    ) -> CredentialWriteDecision {
        let target = [profileAccountUUID, stampedFromOwnToken]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        guard let cli = cliAccountUUID, !cli.isEmpty, let target else { return .noEvidence }
        return cli == target ? .write : .refuse
    }

    /// The OTHER profile already stamped with `accountUUID`, if any. Pure (each
    /// profile's account is injected) so the sync guard is testable without a
    /// store, and keyed on the PERSISTED stamp so a profile still matches before
    /// the background Keychain hydration fills its credentials in — an
    /// unhydrated profile looks account-less, and a duplicate check that cannot
    /// see it happily syncs the same account a second time.
    nonisolated static func duplicateAccountHolder(
        accountUUID: String,
        target: UUID,
        profiles: [Profile],
        accountUUIDOf: (Profile) -> String?
    ) -> Profile? {
        profiles.first {
            $0.id != target && (accountUUIDOf($0).map { !$0.isEmpty && $0 == accountUUID } ?? false)
        }
    }

    /// The account behind the CLI's current login. The identity endpoint is the
    /// authority; `~/.claude.json`'s cached `oauthAccount.accountUuid` is the
    /// fallback for when it cannot be reached, so a refused network call does
    /// not silently downgrade the guard to "no evidence".
    private func cliLoginAccountUUID(systemJSON: String) async -> String? {
        if let token = extractAccessToken(from: systemJSON),
           let identity = await fetchAccountIdentity(accessToken: token) {
            return identity.accountUUID
        }
        return cliCachedAccountUUID()
    }

    /// The account the CLI itself believes it is logged into, read from
    /// `~/.claude.json`. Local file, no network. This app rewrites that key on
    /// every apply (`updateCLIAccountMetadata`) from the APPLIED profile's own
    /// stamp, so it tracks the login rather than the pointer.
    func cliCachedAccountUUID() -> String? {
        if let seams = Self.cliStoreSeams { return seams.cachedAccountUUID() }
        if RealCredentialStoreGuard.refuse("read ~/.claude.json") { return nil }
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: fileURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauthAccount = root["oauthAccount"] as? [String: Any],
              let uuid = oauthAccount["accountUuid"] as? String, !uuid.isEmpty else { return nil }
        return uuid
    }

    // MARK: - Contaminated Logins

    /// Profiles whose PERSISTED stamp disagreed with the identity their own
    /// stored token actually reports. That is the signature of a credential
    /// write that moved one account's login into another account's profile: the
    /// stamp still names who the profile is supposed to be, the token names
    /// someone else. Recorded at the moment the identity pass sees the
    /// disagreement, because the stamp is then healed to match the token and the
    /// evidence would otherwise vanish.
    ///
    /// Persisted (like the dead-login set) so the "re-login needed" caption
    /// survives a relaunch instead of waiting for the next identity resolution.
    /// The app never clears the credential itself — which profile keeps the
    /// account is the user's call.
    private var contaminatedProfiles: Set<UUID> = ClaudeCodeSyncService.loadContaminatedLogins() {
        didSet { Self.saveContaminatedLogins(contaminatedProfiles) }
    }

    private static let contaminatedLoginsKey = "claudeContaminatedLogins_v1"

    /// Where the persisted login flags (dead, contaminated) live. Same XCTest
    /// isolation as `CodexUsageService.deadLoginDefaults`: a test run must
    /// never write these into the user's real defaults domain — the running
    /// app reads them, and a leaked dead flag keeps a live account out of
    /// rotation.
    /// Debug builds only (`RealCredentialStoreGuard.isTestRun` is false in Release).
    private static let flagDefaults: UserDefaults = {
        if RealCredentialStoreGuard.isTestRun, let suite = UserDefaults(suiteName: "com.claudeusagewidget.tests") {
            return suite
        }
        return UserDefaults.standard
    }()

    private static func loadContaminatedLogins() -> Set<UUID> {
        Set((flagDefaults.stringArray(forKey: contaminatedLoginsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private static func saveContaminatedLogins(_ ids: Set<UUID>) {
        flagDefaults.set(ids.map(\.uuidString), forKey: contaminatedLoginsKey)
    }

    /// True when this profile's stored login was found to belong to a different
    /// account than the profile's own stamp claimed.
    func isLoginContaminated(_ profileId: UUID) -> Bool {
        contaminatedProfiles.contains(profileId)
    }

    /// The profile's stamp and its token agree again (a re-login, a re-sync, or
    /// an identity resolution that matched).
    func markLoginUncontaminated(_ profileId: UUID) {
        contaminatedProfiles.remove(profileId)
    }

    /// Records that a profile's stored token reports a different account than
    /// its stamp did. Called only from the identity pass, which has both.
    private func markLoginContaminated(_ profileId: UUID, held: String, reported: String) {
        guard !contaminatedProfiles.contains(profileId) else { return }
        contaminatedProfiles.insert(profileId)
        let name = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId })?.name ?? "?"
        LoggingService.shared.log(
            "⛔️ Claude: '\(name)' is stamped \(String(held.prefix(8))) but its stored token reports \(String(reported.prefix(8))) — the login in this profile belongs to another account"
        )
    }

    /// Refusals already logged, keyed by profile + the account that was refused,
    /// so a repeating sweep says it once rather than every 30 seconds.
    private var refusedWriteSignatures: Set<String> = []

    /// How many contaminating writes the guard has refused per profile this run.
    /// Surfaced in the duplicate/contamination notice
    /// (`ProfileManager.refreshDuplicateClaudeAccountGroups`): a refusal count on
    /// a profile is the strongest evidence that its stored login and the account
    /// something tried to write into it disagree.
    private(set) var refusedCredentialWrites: [UUID: Int] = [:]

    /// The Claude twin of Codex's account_id match: never copy the shared login
    /// into a profile that belongs to a different account. This is the guard
    /// against cross-account contamination (a profile silently absorbing another
    /// account's token, which then mislabels usage and auto-switch decisions).
    ///
    /// An UNSTAMPED target is no longer waved through. It is stamped from its
    /// OWN token first and only then compared, because "unstamped" was the hole
    /// the contamination came through: during the 2026-09-03 cfprefsd
    /// write-rejection episode the on-disk active-profile pointers were stale,
    /// the outgoing re-sync trusted the pointer to name the outgoing profile,
    /// and the CLI's login was written into an unstamped profile that held a
    /// different account.
    ///
    /// Shared by both automatic write paths — the pre-switch re-sync of the
    /// OUTGOING profile (`resyncBeforeSwitching`) and the Keychain adoption in
    /// `ensureFreshCredentials` — so neither can write an account into a profile
    /// that is not that account.
    private func adoptionAccountMatches(profileId: UUID, systemJSON: String) async -> Bool {
        let cliUUID = await cliLoginAccountUUID(systemJSON: systemJSON)
        var profileUUID = ProfileStore.shared.loadProfiles()
            .first(where: { $0.id == profileId })?.claudeAccountUUID

        var stamped: String? = nil
        if profileUUID?.isEmpty ?? true {
            // Resolve the TARGET from its own stored token, never from the
            // incoming credentials — stamping it from those would make every
            // comparison trivially agree and rebuild the hole.
            await stampAccountIdentity(for: profileId)
            stamped = ProfileStore.shared.loadProfiles()
                .first(where: { $0.id == profileId })?.claudeAccountUUID
            profileUUID = stamped
        }

        switch Self.credentialWriteDecision(
            cliAccountUUID: cliUUID, profileAccountUUID: profileUUID, stampedFromOwnToken: stamped
        ) {
        case .write:
            return true
        case .noEvidence:
            return true  // no evidence either way — the pointer's word stands
        case .refuse:
            recordRefusedWrite(profileId: profileId, cliAccountUUID: cliUUID, profileAccountUUID: profileUUID)
            return false
        }
    }

    /// Logs a refusal once per (profile, refused account) pair and counts it.
    private func recordRefusedWrite(profileId: UUID, cliAccountUUID: String?, profileAccountUUID: String?) {
        refusedCredentialWrites[profileId, default: 0] += 1
        let incoming = String((cliAccountUUID ?? "unknown").prefix(8))
        let held = profileAccountUUID.map { String($0.prefix(8)) } ?? "unstamped"
        guard refusedWriteSignatures.insert("\(profileId.uuidString)|\(incoming)").inserted else { return }
        let name = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId })?.name ?? "?"
        LoggingService.shared.log(
            "⛔️ Claude write guard: refusing to write account \(incoming) into profile '\(name)' which holds \(held)"
        )
    }

    // MARK: - Dead Login Notification

    /// Profiles already alerted about a dead CLI login — one notification per dead
    /// login, re-armed when a refresh succeeds or the account is re-synced.
    /// Persisted so the dead-login indicators (dropdown row, Manage Profiles
    /// badge) survive an app relaunch instead of reappearing only after the next
    /// failed refresh attempt.
    private var reloginNotifiedProfiles: Set<UUID> = ClaudeCodeSyncService.loadDeadLogins() {
        didSet { Self.saveDeadLogins(reloginNotifiedProfiles) }
    }

    private static let deadLoginsKey = "claudeDeadLogins_v1"

    private static func loadDeadLogins() -> Set<UUID> {
        Set((flagDefaults.stringArray(forKey: deadLoginsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private static func saveDeadLogins(_ ids: Set<UUID>) {
        flagDefaults.set(ids.map(\.uuidString), forKey: deadLoginsKey)
    }

    /// True when this profile's stored CLI login has been flagged dead (revoked
    /// refresh token) and the user was told to `/login` + re-sync. Lets the UI
    /// show "login expired" instead of "renews automatically" for a token that
    /// will never renew.
    func isLoginMarkedDead(_ profileId: UUID) -> Bool {
        reloginNotifiedProfiles.contains(profileId)
    }

    /// A fresh login for this profile just arrived (identity-routed adoption or
    /// re-sync) — re-arm the dead-login notification and clear the persisted
    /// "login expired" indicators.
    func markLoginRevived(_ profileId: UUID) {
        reloginNotifiedProfiles.remove(profileId)
    }

    /// Tells the user (once) that a profile's saved Claude Code login is dead — its
    /// access token is expired and the refresh token revoked/consumed — so only a
    /// manual `/login` plus a re-sync can revive it. Called on a 4xx from the token
    /// endpoint and by the activation gate that refuses to apply a dead login.
    /// `force` bypasses the once-per-dead-login dedup — pass it for USER-initiated
    /// actions (clicking the profile in a menu): a silent no-op there reads as a
    /// broken button, not as a safety gate.
    func notifyReloginNeeded(for profileId: UUID, force: Bool = false) {
        guard force || !reloginNotifiedProfiles.contains(profileId) else { return }
        reloginNotifiedProfiles.insert(profileId)
        let name = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId })?.name ?? "Claude"
        NotificationManager.shared.sendClaudeReloginNotification(profileName: name)
    }

    // MARK: - Auto Re-sync Before Switching

    /// Re-syncs credentials from system Keychain before profile switching
    /// This ensures we always have the latest CLI login when switching profiles.
    /// Account-matched: the outgoing profile only absorbs the shared login when it
    /// is not KNOWN to belong to a different account (contamination guard).
    /// Never a downgrade: the CLI's login replaces the stored one only when it
    /// is NEWER (`ClaudeLoginLifetime.isNewer`). An older pair there is one
    /// the stored pair was rotated from — consumed — and saving it over the
    /// profile destroyed the only live copy of a login (2026-10-02 05:24:10,
    /// 2026-10-09 05:45:44).
    func resyncBeforeSwitching(for profileId: UUID) async throws {
        LoggingService.shared.log("Re-syncing CLI credentials before profile switch: \(profileId)")

        // Read fresh credentials from system (if user is logged in)
        guard let freshJSON = try await readSystemCredentialsOffMain() else {
            // No credentials in system - user not logged into CLI anymore
            LoggingService.shared.log("No system credentials found - skipping re-sync")
            return
        }

        let stored = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId })?.cliCredentialsJSON
        if let stored, stored != freshJSON,
           !ClaudeLoginLifetime.isNewer(freshJSON, than: stored, now: Date()) {
            LoggingService.shared.log("Re-sync kept the stored login (\(ClaudeLoginLifetime.summary(stored))) — the CLI's copy is not newer (\(ClaudeLoginLifetime.summary(freshJSON)))")
            return
        }

        guard await adoptionAccountMatches(profileId: profileId, systemJSON: freshJSON) else {
            return
        }

        // Validate JSON before saving (defense-in-depth against truncated data)
        guard let data = freshJSON.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LoggingService.shared.log("Re-synced credentials contain invalid JSON - skipping save")
            return
        }

        // Compare-and-swap over the login compared above: the identity check
        // was an await, and a redemption or a sync landing in it must not be
        // overwritten by what the CLI held before.
        if stored != freshJSON {
            guard ProfileStore.shared.replaceCLILogin(profileId, expected: stored, with: freshJSON) else {
                LoggingService.shared.log("Re-sync skipped: the stored login changed while the CLI's was being verified")
                return
            }
        }

        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            return
        }
        profiles[index].cliAccountSyncedAt = Date()  // Update sync timestamp
        ProfileStore.shared.saveProfiles(profiles)
        reloginNotifiedProfiles.remove(profileId)
        awaitingCLIRenewal.remove(profileId)

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
    case accountAlreadySynced(profileName: String)

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
        case .accountAlreadySynced(let profileName):
            return "This Anthropic account is already synced to the profile \u{201C}\(profileName)\u{201D}. Two profiles on one account share one quota. Remove it there first, or run `claude` and `/login` with a different account before syncing here."
        }
    }
}
