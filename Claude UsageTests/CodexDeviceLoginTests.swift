//
//  CodexDeviceLoginTests.swift
//  Claude UsageTests
//
//  Tests for the DEVICE-CODE sign-in the widget runs to add a Codex account.
//
//  Why the feature exists: `codex login`'s browser flow always opens the
//  DEFAULT browser (`ServerOptions.open_browser` is hard-coded `true` in
//  codex-rs/login/src/server.rs), so it signs in whichever account that browser
//  already holds — precisely wrong when the point is to add a SECOND account.
//  `codex login --device-auth` opens nothing: it prints a verification link and
//  a one-time code, which the user carries to any browser session they like.
//
//  These assertions are all pure. The parser is the only part of the flow that
//  can be checked without spawning the CLI and completing a real OAuth
//  round-trip, and it is also the part that would silently strand the user on
//  an empty sheet if the CLI's wording drifted.
//

import XCTest
@testable import Claude_Usage

final class CodexDeviceLoginTests: XCTestCase {

    // The device-code prompt as the CLI actually prints it
    // (codex-rs/login/src/device_code_auth.rs, `device_code_prompt`), colour
    // codes included: gray 90, blue 94, reset 0.
    private let blue = "\u{1B}[94m"
    private let gray = "\u{1B}[90m"
    private let reset = "\u{1B}[0m"

    private func devicePromptLines(url: String, code: String) -> [String] {
        [
            "",
            "Welcome to Codex [v\(gray)0.104.0\(reset)]",
            "\(gray)OpenAI's command-line coding agent\(reset)",
            "",
            "Follow these steps to sign in with ChatGPT using device code authorization:",
            "",
            "1. Open this link in your browser and sign in to your account",
            "   \(blue)\(url)\(reset)",
            "",
            "2. Enter this one-time code \(gray)(expires in 15 minutes)\(reset)",
            "   \(blue)\(code)\(reset)",
            "",
            "\(gray)Continue only if you started this login in Codex. If a website or another person gave you this code, cancel.\(reset)"
        ]
    }

    // MARK: - Device-code prompt

    /// Given the CLI's real device-code prompt, both fields come out — the
    /// verification URL and the one-time code — stripped of their colour codes.
    func testDeviceCodePromptYieldsTheLinkAndTheOneTimeCode() {
        let lines = devicePromptLines(url: "https://auth.openai.com/codex/device", code: "ABCD-EFGH")

        let fields = lines.compactMap(CodexLoginService.promptField(in:))

        XCTAssertEqual(fields, [
            .verificationURL("https://auth.openai.com/codex/device"),
            .userCode("ABCD-EFGH")
        ], "the prose lines must contribute nothing; only the link and the code")
    }

    /// The same prompt with ragged whitespace and a longer, ungrouped code —
    /// the length and the grouping are the authorization server's to choose,
    /// and the parser matches the SHAPE of the line, not the CLI's wording.
    func testDeviceCodePromptSurvivesRaggedWhitespaceAndOtherCodeShapes() {
        let hyphenated = devicePromptLines(url: "https://auth.openai.com/codex/device", code: "WDJB-MJHT")
            .map { "  \($0)\t" }
        XCTAssertEqual(
            hyphenated.compactMap(CodexLoginService.promptField(in:)).last,
            .userCode("WDJB-MJHT")
        )

        let ungrouped = devicePromptLines(url: "https://auth.openai.com/codex/device", code: "K7QP2XM94")
        XCTAssertEqual(
            ungrouped.compactMap(CodexLoginService.promptField(in:)).last,
            .userCode("K7QP2XM94"),
            "a nine-character ungrouped code is still a code"
        )
    }

    // MARK: - Browser prompt

    /// The browser flow prints its own pasteable link, and the sheet shows it
    /// so even that mode does not depend on the default browser's session. The
    /// localhost callback server on the SAME message must not be mistaken for
    /// it: that address is useless anywhere but this machine.
    func testBrowserPromptYieldsTheAuthURLAndNeverTheLocalhostCallback() {
        // codex-rs/cli/src/login.rs, the eprintln! around line 117.
        let authURL = "https://auth.openai.com/oauth/authorize?client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_challenge=abc"
        let lines = [
            "Starting local login server on http://localhost:1455.",
            "If your browser did not open, navigate to this URL to authenticate:",
            "",
            authURL,
            "",
            "On a remote or headless machine? Use `codex login --device-auth` instead."
        ]

        let fields = lines.compactMap(CodexLoginService.promptField(in:))

        XCTAssertEqual(fields, [.verificationURL(authURL)])
    }

    /// Unrelated output contributes nothing, so a status line can never
    /// overwrite a link or a code already on screen.
    func testUnrelatedOutputYieldsNoField() {
        let lines = [
            "",
            "   ",
            "Successfully logged in",
            "Error logging in with device code: device auth failed with status 400",
            "Warning: failed to resolve login log directory: permission denied",
            "\(gray)OpenAI's command-line coding agent\(reset)",
            "WARNING",
            "https://"
        ]

        XCTAssertEqual(lines.compactMap(CodexLoginService.promptField(in:)), [])
    }

    // MARK: - Mode wiring

    /// The flag and the deadline both follow the mode. The device-code ceiling
    /// outlives the CLI's own fifteen-minute poll (`poll_for_token`'s
    /// `max_wait`), so an abandoned sign-in is ended by the CLI rather than cut
    /// short by the widget — the five-minute browser cap would have killed a
    /// device-code login at a third of its life.
    func testArgumentsAndTimeoutFollowTheMode() {
        XCTAssertEqual(CodexLoginService.arguments(for: .deviceCode), ["login", "--device-auth"])
        XCTAssertEqual(CodexLoginService.arguments(for: .browser), ["login"])

        XCTAssertEqual(CodexLoginService.timeout(for: .browser), 5 * 60)
        XCTAssertGreaterThan(
            CodexLoginService.timeout(for: .deviceCode), 15 * 60,
            "the widget must not time out before the CLI's own 15-minute poll gives up"
        )
    }

    /// A failure quotes the CLI's output back to the user, and that tail must
    /// carry neither the link nor the code: the code authorizes a sign-in for
    /// as long as it lives, and the sheet's own fields are the only place
    /// either belongs.
    func testFailureTailCarriesNeitherTheLinkNorTheCode() {
        let tail = devicePromptLines(url: "https://auth.openai.com/codex/device", code: "ABCD-EFGH")
            .joined(separator: "\n")
            + "\nError logging in with device code: device auth failed with status 400"

        let redacted = CodexLoginService.redactingInstructions(in: tail)

        XCTAssertFalse(redacted.contains("ABCD-EFGH"))
        XCTAssertFalse(redacted.contains("auth.openai.com"))
        XCTAssertTrue(redacted.contains("device auth failed with status 400"),
                      "the part that explains the failure has to survive")
    }
}
