//
//  CodexLoginService.swift
//  Claude Usage
//
//  Runs `codex login` inside an ISOLATED CODEX_HOME.
//

import Foundation

/// Adds a Codex account without logging the current one out.
///
/// `codex login` REVOKES, server-side, whatever refresh token sits in the home
/// it runs in before it opens the browser (`codex-rs/cli/src/login.rs`:
/// `login_with_chatgpt` → `clear_existing_auth_before_login` →
/// `logout_with_revoke(codex_home, …)`). Running it in a terminal therefore
/// kills the account the widget has applied to `~/.codex` — which is exactly
/// what happened three times on 2026-09-03.
///
/// The CLI honours `$CODEX_HOME`, so this service runs the same command with
/// that variable pointed at a fresh per-account directory, where there is no
/// token to revoke. It NEVER reads, writes or deletes the default home: the
/// profile-switch path stays the only writer of `~/.codex/auth.json`.
final class CodexLoginService {
    static let shared = CodexLoginService()

    /// The browser round-trip has to finish inside this window. The CLI itself
    /// waits indefinitely on its localhost callback, so without a cap an
    /// abandoned login leaves a `codex` process running forever.
    nonisolated static let loginTimeout: TimeInterval = 5 * 60

    /// Where Homebrew puts the CLI on Apple silicon and Intel. Tried in order
    /// before falling back to a login shell, because a GUI app inherits
    /// launchd's PATH, not the user's.
    nonisolated static let wellKnownBinaryPaths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]

    private init() {}

    // MARK: - Label → folder slug

    /// A folder-safe slug for a user-typed account label. Everything outside
    /// `[a-z0-9-_]` becomes a separator, so no input can walk out of the
    /// accounts directory: `/`, `.` and `..` cannot survive.
    nonisolated static func slug(for label: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        var pieces: [String] = []
        var current = ""
        for character in label.lowercased() {
            if allowed.contains(character) {
                current.append(character)
            } else if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }

        let trimmed = String(pieces.joined(separator: "-").prefix(32))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The isolated home a slug names. Sibling directories, one per account.
    nonisolated static func home(forSlug slug: String) -> URL {
        CodexUsageService.isolatedHomesRoot.appendingPathComponent(slug)
    }

    // MARK: - Finding the CLI

    /// Resolves the `codex` binary: the well-known install paths first, then a
    /// login shell (`zsh -lc 'command -v codex'`) for everyone else. The shell
    /// answer is accepted only when it is an absolute path that exists — a
    /// shell function or alias name is not something we can execute.
    nonisolated static func codexBinaryPath(
        wellKnown: [String] = CodexLoginService.wellKnownBinaryPaths,
        isExecutable: (String) -> Bool,
        loginShellLookup: () -> String?
    ) -> String? {
        for path in wellKnown where isExecutable(path) { return path }

        guard let found = loginShellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
              found.hasPrefix("/"),
              isExecutable(found) else {
            return nil
        }
        return found
    }

    /// The runtime resolver. Blocking (it spawns a login shell) — call it off
    /// the main thread.
    nonisolated static func locateCodexBinary() -> String? {
        codexBinaryPath(
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            loginShellLookup: { runLoginShell(command: "command -v codex") }
        )
    }

    private nonisolated static func runLoginShell(command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Child environment

    /// The child's environment: everything this process has (so PATH, HOME and
    /// the proxy variables the CLI needs survive) plus `CODEX_HOME` pointing at
    /// the isolated directory. Overriding rather than appending is the point —
    /// an inherited `CODEX_HOME` must not win.
    nonisolated static func loginEnvironment(home: URL, inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment["CODEX_HOME"] = home.path
        return environment
    }

    /// What a finished `codex login` means. Exit 0 alone is not success: a CLI
    /// that exits cleanly without writing `auth.json` has given us nothing to
    /// import, and reporting that as a win would strand the user on an empty
    /// profile.
    nonisolated static func loginVerdict(
        status: Int32,
        cancelled: Bool,
        timedOut: Bool,
        authFileExists: Bool
    ) -> CodexLoginError? {
        if cancelled { return .cancelled }
        if timedOut { return .timedOut }
        if status != 0 { return .failed(status: status) }
        return authFileExists ? nil : .noCredentialsAfterLogin
    }

    // MARK: - Running the login

    /// Prepares the isolated home and starts `codex login` in it.
    ///
    /// Blocking preparation (directory creation, binary lookup) happens on the
    /// caller's thread, so call this off the main thread; `completion` is
    /// delivered on the main queue exactly once.
    func startLogin(
        slug: String,
        completion: @escaping (Result<URL, CodexLoginError>, String) -> Void
    ) throws -> CodexLoginRun {
        let home = Self.home(forSlug: slug)

        // Belt and braces: this flow must never point the CLI at the default
        // home, because that is the one login that revokes a live account.
        guard home.standardizedFileURL != CodexUsageService.defaultCodexHome.standardizedFileURL else {
            throw CodexLoginError.refusesDefaultHome
        }
        guard let binary = Self.locateCodexBinary() else {
            throw CodexLoginError.binaryNotFound
        }

        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let logURL = home.appendingPathComponent("widget-login.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            throw CodexLoginError.launchFailed("could not open \(logURL.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["login"]
        process.environment = Self.loginEnvironment(home: home, inherited: ProcessInfo.processInfo.environment)
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice

        let run = CodexLoginRun(home: home, logURL: logURL, process: process, completion: completion)
        try run.start(timeout: Self.loginTimeout)
        LoggingService.shared.log("Codex: started `codex login` under an isolated home (\(slug))")
        return run
    }
}

/// A `codex login` in flight. Settles exactly once — on exit, on cancel, or on
/// the timeout — and delivers its verdict on the main queue.
final class CodexLoginRun {
    let home: URL
    let logURL: URL

    private let process: Process
    /// Delivered with the tail of the CLI's own output, so a caller that
    /// never saw the run object still has something to show the user.
    private let completion: (Result<URL, CodexLoginError>, String) -> Void
    private let lock = NSLock()
    private var settled = false
    private var cancelled = false
    private var timedOut = false
    private var timeoutItem: DispatchWorkItem?

    init(
        home: URL,
        logURL: URL,
        process: Process,
        completion: @escaping (Result<URL, CodexLoginError>, String) -> Void
    ) {
        self.home = home
        self.logURL = logURL
        self.process = process
        self.completion = completion
    }

    func start(timeout: TimeInterval) throws {
        process.terminationHandler = { [weak self] finished in
            self?.settle(status: finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            throw CodexLoginError.launchFailed(error.localizedDescription)
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.lock.lock()
            self.timedOut = true
            self.lock.unlock()
            self.process.terminate()
        }
        timeoutItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// User pressed Cancel. Terminating the CLI before it reaches the callback
    /// leaves the isolated home without an auth.json and the default home
    /// untouched — nothing was revoked, because nothing was there.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    /// The tail of the CLI's own output, for a failure message. The CLI prints
    /// a URL and status lines here, never a token, but the caller shows it to
    /// the user, so it is trimmed to the last few lines rather than dumped.
    func logTail(lines: Int = 6) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .joined(separator: "\n")
    }

    private func settle(status: Int32) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let wasCancelled = cancelled
        let didTimeOut = timedOut
        lock.unlock()

        timeoutItem?.cancel()

        let authFile = CodexUsageService.authFileURL(inHome: home)
        let verdict = CodexLoginService.loginVerdict(
            status: status,
            cancelled: wasCancelled,
            timedOut: didTimeOut,
            authFileExists: FileManager.default.fileExists(atPath: authFile.path)
        )

        let home = self.home
        let completion = self.completion
        let tail = verdict == nil ? "" : logTail()
        DispatchQueue.main.async {
            if let verdict {
                completion(.failure(verdict), tail)
            } else {
                completion(.success(home), tail)
            }
        }
    }
}

// MARK: - CodexLoginError

enum CodexLoginError: LocalizedError, Equatable {
    case invalidLabel
    case binaryNotFound
    case refusesDefaultHome
    case launchFailed(String)
    case cancelled
    case timedOut
    case failed(status: Int32)
    case noCredentialsAfterLogin

    var errorDescription: String? {
        switch self {
        case .invalidLabel:
            return "codex.login.error_label".localized
        case .binaryNotFound:
            return "codex.login.error_no_binary".localized
        case .refusesDefaultHome:
            return "codex.login.error_default_home".localized
        case .launchFailed(let detail):
            return "codex.login.error_launch".localized(with: detail)
        case .cancelled:
            return "codex.login.error_cancelled".localized
        case .timedOut:
            return "codex.login.error_timeout".localized
        case .failed(let status):
            return "codex.login.error_exit".localized(with: Int(status))
        case .noCredentialsAfterLogin:
            return "codex.login.error_no_auth_file".localized
        }
    }
}
