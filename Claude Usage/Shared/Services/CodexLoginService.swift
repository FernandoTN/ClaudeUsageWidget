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
/// what happened three times on 2026-09-03. The device-code path revokes the
/// same way (`run_login_with_device_code` calls
/// `clear_existing_auth_before_login` too), which costs nothing in a fresh
/// isolated home and is the profile's own dead grant in a reused one.
///
/// The CLI honours `$CODEX_HOME`, so this service runs the same command with
/// that variable pointed at a fresh per-account directory, where there is no
/// token to revoke. It NEVER reads, writes or deletes the default home: the
/// profile-switch path stays the only writer of `~/.codex/auth.json`.
final class CodexLoginService {
    static let shared = CodexLoginService()

    // MARK: - How the CLI is asked to authorize

    /// The two sign-in flows the CLI offers.
    enum Mode: Equatable {
        /// `codex login --device-auth` — the OAuth DEVICE-CODE flow. It opens
        /// NO browser: it prints a verification URL and a one-time code, and
        /// the user enters them wherever they like. That is the default here
        /// because the browser flow hijacks the DEFAULT browser
        /// (`ServerOptions.open_browser` is hard-coded `true` in the CLI), and
        /// a default browser already signed in to another account signs the
        /// WRONG account in — the whole problem when adding a second one.
        case deviceCode
        /// `codex login` — the localhost-callback flow. Always opens the
        /// default browser; the URL it prints is shown anyway, so it can be
        /// pasted into a different browser or session.
        case browser
    }

    /// The CLI's argument vector for a mode. `--device-auth` is the flag
    /// `codex-rs/cli/src/main.rs` binds to `LoginCommand.use_device_code`.
    nonisolated static func arguments(for mode: Mode) -> [String] {
        switch mode {
        case .deviceCode: return ["login", "--device-auth"]
        case .browser: return ["login"]
        }
    }

    /// The browser round-trip has to finish inside this window. The CLI itself
    /// waits indefinitely on its localhost callback, so without a cap an
    /// abandoned login leaves a `codex` process running forever.
    nonisolated static let browserLoginTimeout: TimeInterval = 5 * 60

    /// The device-code ceiling. The CLI polls for at most fifteen minutes
    /// (`codex-rs/login/src/device_code_auth.rs`, `poll_for_token`:
    /// `max_wait = Duration::from_secs(15 * 60)`) and the code it prints
    /// "expires in 15 minutes", so the CLI gives up first; the extra minute
    /// only catches a CLI that outlives its own deadline.
    nonisolated static let deviceLoginTimeout: TimeInterval = 16 * 60

    nonisolated static func timeout(for mode: Mode) -> TimeInterval {
        switch mode {
        case .deviceCode: return deviceLoginTimeout
        case .browser: return browserLoginTimeout
        }
    }

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

    // MARK: - Where a login lands

    /// Where a fresh login should be stored, decided from the profile whose
    /// page the button was pressed on.
    enum Target: Equatable {
        /// The viewed profile takes it. Either it has no Codex account, or the
        /// one it has is dead — in both cases this login is what that profile
        /// was missing, and creating a second profile beside it would leave the
        /// user with an empty or broken one to clean up.
        case viewedProfile
        /// The viewed profile holds a WORKING account. A profile holds exactly
        /// one, so a new login needs a profile of its own.
        case newProfile
    }

    /// A profile whose stored Codex login is flagged dead is a destination, not
    /// an obstacle: replacing those tokens in place is the repair. Only a live
    /// account makes the viewed profile off-limits.
    nonisolated static func loginTarget(carriesCodexAccount: Bool, loginIsDead: Bool) -> Target {
        (!carriesCodexAccount || loginIsDead) ? .viewedProfile : .newProfile
    }

    /// The isolated home a profile's login should use: the one it already knows,
    /// so a RE-login reuses it, else one named after the profile.
    ///
    /// Reuse is deliberate. `codex login` revokes what it finds in the home it
    /// runs in — and what is in a profile's own home is that profile's own dead
    /// grant, which is already worthless. Revoking it costs nothing, while
    /// minting a new directory per attempt would litter `~/.codex-accounts`.
    /// A remembered path pointing at the DEFAULT home is refused rather than
    /// reused: a login there is the one that kills a live account.
    nonisolated static func loginHome(existingHomePath: String?, profileName: String) -> URL? {
        if let existingHomePath, !existingHomePath.isEmpty {
            let remembered = URL(fileURLWithPath: existingHomePath)
            guard remembered.standardizedFileURL != CodexUsageService.defaultCodexHome.standardizedFileURL else {
                return nil
            }
            return remembered
        }
        guard let slug = slug(for: profileName) else { return nil }
        return home(forSlug: slug)
    }

    // MARK: - Reading the CLI's sign-in prompt

    /// What the CLI has told the user to do, harvested from its own output.
    ///
    /// Both fields belong on screen and NOWHERE else: the code authorizes a
    /// sign-in for the fifteen minutes it lives, and the URL is the door it
    /// opens. Neither is logged above debug and neither reaches an error
    /// message — `redactingInstructions(in:)` strips them from the failure tail.
    struct LoginInstructions: Equatable {
        var verificationURL: String?
        var userCode: String?

        var isEmpty: Bool { verificationURL == nil && userCode == nil }
    }

    /// One field of the sign-in prompt, recognised on one line of CLI output.
    enum PromptField: Equatable {
        case verificationURL(String)
        case userCode(String)
    }

    /// Drops ANSI escape sequences. The device-code prompt colours both fields
    /// (`\u{1B}[94m…\u{1B}[0m`, `device_code_auth.rs`), so the bytes on the pipe
    /// are not the text.
    nonisolated static func strippingANSI(_ line: String) -> String {
        var result = ""
        var inEscape = false
        var inControlSequence = false

        for character in line {
            if inEscape {
                if inControlSequence {
                    // A CSI sequence ends at its final byte, anything in @…~.
                    if let scalar = character.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) {
                        inEscape = false
                        inControlSequence = false
                    }
                } else if character == "[" {
                    inControlSequence = true
                } else {
                    inEscape = false
                }
                continue
            }
            if character == "\u{1B}" {
                inEscape = true
                continue
            }
            result.append(character)
        }
        return result
    }

    /// Extracts one field of the sign-in prompt from one line of CLI output.
    ///
    /// Deliberately tolerant. Both flows print through `format!` with colour
    /// codes and leading spaces, one prints to stdout and the other to stderr,
    /// and the wording has already changed once. What is matched is the SHAPE —
    /// an `https` token, or a line that is nothing but a code-shaped token —
    /// never the prose around it.
    nonisolated static func promptField(in rawLine: String) -> PromptField? {
        let line = strippingANSI(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if let url = httpsToken(in: line) { return .verificationURL(url) }
        if isUserCode(line) { return .userCode(line) }
        return nil
    }

    /// The first `https://` token on the line, minus trailing sentence
    /// punctuation. `http://localhost:<port>` is deliberately NOT matched: the
    /// browser flow announces its callback server there, and that address is
    /// worthless to paste into another machine's browser.
    private nonisolated static func httpsToken(in line: String) -> String? {
        guard let start = line.range(of: "https://") else { return nil }
        let token = line[start.lowerBound...].prefix { !$0.isWhitespace }
        let trimmed = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}>\"'"))
        return trimmed.count > "https://".count ? trimmed : nil
    }

    /// Whether a line is NOTHING BUT a one-time code. The observed shape is
    /// `ABCD-EFGH` (`device_code_auth_tests.rs`), but the grouping and the
    /// length are the server's to choose, so any single upper-case alphanumeric
    /// token counts — hyphenated, or eight to ten characters long.
    ///
    /// A line like `ERROR-500` would match too. That costs nothing: the field
    /// is only ever displayed, and the real code arrives in the same `println!`
    /// as the rest of the prompt.
    private nonisolated static func isUserCode(_ line: String) -> Bool {
        guard line.count <= 16 else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard line.allSatisfy({ allowed.contains($0) }) else { return false }
        let body = line.filter { $0 != "-" }
        guard body.count >= 6, body.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return line.contains("-") || (8...10).contains(body.count)
    }

    /// The CLI's own output with every sign-in link and one-time code removed.
    /// The tail travels into failure messages, and those must not carry a live
    /// credential out of the sheet.
    nonisolated static func redactingInstructions(in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                switch promptField(in: String(line)) {
                case .verificationURL: return "[sign-in link hidden]"
                case .userCode: return "[one-time code hidden]"
                case nil: return String(line)
                }
            }
            .joined(separator: "\n")
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

    /// Prepares the isolated home and starts the CLI in it.
    ///
    /// Blocking preparation (directory creation, binary lookup) happens on the
    /// caller's thread, so call this off the main thread; `onInstructions` and
    /// `completion` are both delivered on the main queue, `completion` exactly
    /// once.
    func startLogin(
        home: URL,
        mode: Mode = .deviceCode,
        onInstructions: @escaping (LoginInstructions) -> Void = { _ in },
        completion: @escaping (Result<URL, CodexLoginError>, String) -> Void
    ) throws -> CodexLoginRun {
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

        // One pipe for both streams: the device-code prompt goes to stdout
        // (`println!`) and every status line to stderr (`eprintln!`), and the
        // sheet needs whichever arrives.
        let output = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = Self.arguments(for: mode)
        process.environment = Self.loginEnvironment(home: home, inherited: ProcessInfo.processInfo.environment)
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        let run = CodexLoginRun(
            home: home,
            logURL: logURL,
            mode: mode,
            process: process,
            output: output,
            logHandle: logHandle,
            onInstructions: onInstructions,
            completion: completion
        )
        try run.start(timeout: Self.timeout(for: mode))
        LoggingService.shared.log(
            "Codex: started `codex \(Self.arguments(for: mode).joined(separator: " "))`"
                + " under an isolated home (\(home.lastPathComponent))"
        )
        return run
    }
}

/// Splits the CLI's byte stream into whole lines. A pipe read can land
/// mid-line, and the one line that matters is the one holding the code.
final class CodexLoginLineBuffer {
    private var pending = ""
    private let lock = NSLock()

    func take(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        pending += text

        var lines: [String] = []
        while let newline = pending.firstIndex(of: "\n") {
            lines.append(String(pending[pending.startIndex..<newline]))
            pending = String(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// Whatever never got its newline. The CLI's last write need not end in one.
    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rest = pending
        pending = ""
        return rest.isEmpty ? [] : [rest]
    }
}

/// A `codex login` in flight. Settles exactly once — on exit, on cancel, or on
/// the timeout — and delivers its verdict on the main queue.
final class CodexLoginRun {
    let home: URL
    let logURL: URL
    let mode: CodexLoginService.Mode

    private let process: Process
    private let output: Pipe
    private let logHandle: FileHandle
    private let lines = CodexLoginLineBuffer()
    /// Called on the main queue whenever the CLI reveals more of its prompt.
    private let onInstructions: (CodexLoginService.LoginInstructions) -> Void
    /// Delivered with the tail of the CLI's own output, so a caller that
    /// never saw the run object still has something to show the user.
    private let completion: (Result<URL, CodexLoginError>, String) -> Void
    private let lock = NSLock()
    private var settled = false
    private var cancelled = false
    private var timedOut = false
    private var timeoutItem: DispatchWorkItem?
    /// Main-queue only.
    private var instructions = CodexLoginService.LoginInstructions()

    init(
        home: URL,
        logURL: URL,
        mode: CodexLoginService.Mode,
        process: Process,
        output: Pipe,
        logHandle: FileHandle,
        onInstructions: @escaping (CodexLoginService.LoginInstructions) -> Void,
        completion: @escaping (Result<URL, CodexLoginError>, String) -> Void
    ) {
        self.home = home
        self.logURL = logURL
        self.mode = mode
        self.process = process
        self.output = output
        self.logHandle = logHandle
        self.onInstructions = onInstructions
        self.completion = completion
    }

    func start(timeout: TimeInterval) throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.endOfOutput()
                return
            }
            self?.consume(data)
        }

        process.terminationHandler = { [weak self] finished in
            self?.settle(status: finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? logHandle.close()
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

    /// The tail of the CLI's own output, for a failure message — with the
    /// sign-in link and the one-time code taken out. They belong on the sheet's
    /// own live fields and nowhere else.
    func logTail(lines count: Int = 6) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        let tail = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(count)
            .joined(separator: "\n")
        return CodexLoginService.redactingInstructions(in: tail)
    }

    // MARK: - Reading the CLI

    private func consume(_ data: Data) {
        // The log file stays the CLI's verbatim output; `logTail` is what
        // redacts, because that is the copy the user's error message quotes.
        try? logHandle.write(contentsOf: data)

        let fields = lines.take(data).compactMap(CodexLoginService.promptField(in:))
        guard !fields.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.apply(fields) }
    }

    private func endOfOutput() {
        let fields = lines.flush().compactMap(CodexLoginService.promptField(in:))
        guard !fields.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.apply(fields) }
    }

    private func apply(_ fields: [CodexLoginService.PromptField]) {
        var changed = false
        for field in fields {
            switch field {
            case .verificationURL(let url):
                if instructions.verificationURL != url {
                    instructions.verificationURL = url
                    changed = true
                }
            case .userCode(let code):
                if instructions.userCode != code {
                    instructions.userCode = code
                    changed = true
                }
            }
        }
        guard changed else { return }
        // Never the values themselves: the code is a live credential.
        LoggingService.shared.logDebug("Codex: sign-in prompt read from the CLI")
        onInstructions(instructions)
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
        output.fileHandleForReading.readabilityHandler = nil
        // Drain whatever the child wrote between the last read and its exit.
        if let rest = try? output.fileHandleForReading.readToEnd(), !rest.isEmpty {
            consume(rest)
        }
        endOfOutput()
        try? logHandle.close()

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
