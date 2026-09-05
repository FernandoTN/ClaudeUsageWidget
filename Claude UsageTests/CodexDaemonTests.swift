//
//  CodexDaemonTests.swift
//  Claude UsageTests
//
//  The pure parts of Codex daemon awareness (docs/specs/codex-daemon-awareness.md):
//  a PATH-ANCHORED daemon match that can never hit the user's TUIs, the
//  desktop app's embedded codex or a `codex exec`; the attached-session count
//  (children named codex-code-mode-host, daemon's only); and the terminals
//  line, derived solely from a daemon-written rollout's rate-limit reset stamp
//  matched to the profiles' cached stamps — never inferred beyond it.
//
//  No test here runs `ps`, signals a process, or reads the real
//  ~/.codex/sessions; the one file-system test builds its own sessions tree
//  in a temporary directory. Fixture names follow the synthetic roster
//  (Atlas, Cedar); account stamps are `acct-…`.
//

import XCTest
@testable import Claude_Usage

final class CodexDaemonTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester/.codex", isDirectory: true)
    private var standalone: String { home.path + "/packages/standalone" }

    private var psOutput: String {
        """
          321     1 /Users/tester/.codex/packages/standalone/current/codex app-server --listen unix:///Users/tester/.codex/app-server-control/app-server-control.sock
          400   321 /Users/tester/.codex/packages/standalone/releases/0.153.3-aarch64-apple-darwin/bin/codex-code-mode-host
          401   321 /Users/tester/.codex/packages/standalone/releases/0.153.3-aarch64-apple-darwin/bin/codex-code-mode-host
          402   321 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node launch.mjs
        13463     1 codex exec --model gpt-6-astra -c model_reasoning_effort=xhigh -o out.json
        15796 13463 /Users/tester/.codex/packages/standalone/releases/0.153.3-aarch64-apple-darwin/bin/codex-code-mode-host
        """
    }

    // MARK: - Process list

    func testParseProcessListReadsPidPpidAndCommandThroughPaddedColumns() {
        let records = CodexDaemon.parseProcessList(psOutput)
        XCTAssertEqual(records.count, 6)
        XCTAssertEqual(records[0].pid, 321)
        XCTAssertEqual(records[0].ppid, 1)
        XCTAssertEqual(records[0].executablePath, "/Users/tester/.codex/packages/standalone/current/codex")
        XCTAssertEqual(records[0].arguments.first, "app-server")
        XCTAssertEqual(records[4].pid, 13463)
        XCTAssertEqual(records[4].executableName, "codex", "a bare command has no directory")
        XCTAssertEqual(records[5].ppid, 13463)
        XCTAssertEqual(records[5].executableName, CodexDaemon.sessionHostExecutable)
    }

    // MARK: - Path-anchored match

    /// The one rule that keeps a restart from killing the wrong process.
    func testDaemonMatchIsPathAnchoredAndNeverTheBareName() {
        XCTAssertTrue(CodexDaemon.isDaemonCommand(
            "\(standalone)/current/codex app-server --listen unix:///tmp/x.sock", codexHome: home))
        XCTAssertTrue(CodexDaemon.isDaemonCommand(
            "\(standalone)/releases/0.153.3-aarch64-apple-darwin/bin/codex app-server", codexHome: home),
            "a release path under the package is the same binary")

        XCTAssertFalse(CodexDaemon.isDaemonCommand("codex app-server --listen unix:///tmp/x.sock", codexHome: home),
                       "the bare name is never enough — it is what the user's TUIs and codex exec are called")
        XCTAssertFalse(CodexDaemon.isDaemonCommand("codex exec --model gpt-6-astra -o out.json", codexHome: home))
        XCTAssertFalse(CodexDaemon.isDaemonCommand(
            "/Applications/ChatGPT.app/Contents/Resources/codex app-server", codexHome: home),
            "the desktop app's embedded codex is outside the standalone package")
        XCTAssertFalse(CodexDaemon.isDaemonCommand(
            "\(standalone)/releases/0.153.3/bin/codex-code-mode-host", codexHome: home),
            "the session host is not the daemon")
        XCTAssertFalse(CodexDaemon.isDaemonCommand("\(standalone)/current/codex exec -o out.json", codexHome: home),
                       "the standalone binary running a headless exec is not the daemon either")
        XCTAssertFalse(CodexDaemon.isDaemonCommand(
            "\(standalone)/current/codex app-server", codexHome: URL(fileURLWithPath: "/Users/tester/.codex-accounts/juniper")),
            "another CODEX_HOME is another install")
    }

    // MARK: - Attached sessions

    func testAttachedSessionsAreCodeModeHostChildrenOfTheDaemonOnly() {
        let records = CodexDaemon.parseProcessList(psOutput)
        let status = CodexDaemon.status(processes: records, codexHome: home, controlSocketPresent: true)
        XCTAssertEqual(status.daemon?.pid, 321)
        XCTAssertEqual(status.attachedSessions, 2,
                       "two hosts under the daemon; the node child is not a session and the host under codex exec is a headless run")
        XCTAssertTrue(status.isRunning)

        let noDaemon = CodexDaemon.status(processes: Array(records[4...]), codexHome: home, controlSocketPresent: true)
        XCTAssertNil(noDaemon.daemon, "a socket file alone is not a running daemon")
        XCTAssertEqual(noDaemon.attachedSessions, 0)
    }

    // MARK: - Terminals: stamp → profile

    private func codexProfile(_ name: String, weeklyReset: Date) -> Profile {
        var profile = Profile(id: UUID(), name: name)
        profile.codexAccountId = "acct-\(name.lowercased())"
        var usage = ClaudeUsage.empty
        usage.weeklyResetTime = weeklyReset
        usage.sessionResetTime = weeklyReset
        profile.claudeUsage = usage
        return profile
    }

    func testStampResolvesToTheUniqueCodexProfileToTheMinute() {
        let boundaryA = Date(timeIntervalSince1970: 1_789_140_000)
        let boundaryB = Date(timeIntervalSince1970: 1_789_500_000)
        let atlas = codexProfile("Atlas", weeklyReset: boundaryA)
        let cedar = codexProfile("Cedar", weeklyReset: boundaryB)
        var claude = Profile(id: UUID(), name: "Fjord")
        var claudeUsage = ClaudeUsage.empty
        claudeUsage.weeklyResetTime = boundaryA
        claude.claudeUsage = claudeUsage
        claude.cliCredentialsJSON = #"{"claudeAiOauth":{"accessToken":"x"}}"#

        func evidence(_ stamp: Date) -> CodexTerminals.Evidence {
            CodexTerminals.Evidence(resetsAt: stamp, windowMinutes: 10080, sessionStartedAt: stamp.addingTimeInterval(-3600))
        }

        XCTAssertEqual(CodexTerminals.profile(matching: evidence(boundaryA.addingTimeInterval(26)), in: [atlas, cedar, claude])?.name,
                       "Atlas", "±1 s API jitter is absorbed by the minute quantization; the Claude profile with the same stamp never matches")
        XCTAssertEqual(CodexTerminals.profile(matching: evidence(boundaryB), in: [atlas, cedar, claude])?.name, "Cedar")
        XCTAssertNil(CodexTerminals.profile(matching: evidence(boundaryA.addingTimeInterval(3600)), in: [atlas, cedar]),
                     "no cached stamp equals it — unknown, never a guess")

        let twin = codexProfile("Birch", weeklyReset: boundaryA)
        XCTAssertNil(CodexTerminals.profile(matching: evidence(boundaryA), in: [atlas, twin, cedar]),
                     "two Codex profiles on one boundary are ambiguous — unknown, never the first one")
    }

    // MARK: - Terminals: rollout lines

    private let metaTUI = #"{"timestamp":"2026-09-05T00:31:19.405Z","type":"session_meta","payload":{"id":"01a06efa","timestamp":"2026-09-05T00:31:19.308Z","originator":"codex-tui","cli_version":"0.153.3"}}"#
    private let metaExec = #"{"timestamp":"2026-09-05T00:32:18.405Z","type":"session_meta","payload":{"id":"01a06efb","timestamp":"2026-09-05T00:32:18.308Z","originator":"codex_exec"}}"#
    private func tokenCount(resetsAt: Int) -> String {
        #"{"timestamp":"2026-09-05T00:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":19.0,"window_minutes":10080,"resets_at":\#(resetsAt)},"secondary":null,"plan_type":"pro"}}}"#
    }

    func testRolloutLinesYieldOriginatorSessionStartAndStamp() {
        XCTAssertEqual(CodexTerminals.originator(ofSessionMetaLine: metaTUI), "codex-tui")
        XCTAssertEqual(CodexTerminals.originator(ofSessionMetaLine: metaExec), "codex_exec")
        XCTAssertNil(CodexTerminals.originator(ofSessionMetaLine: tokenCount(resetsAt: 1)), "not a session_meta line")
        XCTAssertEqual(CodexTerminals.sessionStart(ofSessionMetaLine: metaTUI)?.timeIntervalSince1970 ?? 0,
                       1_788_568_279.308, accuracy: 0.001, "the payload timestamp, with its fraction")

        let stamp = CodexTerminals.rateLimitStamp(inLine: tokenCount(resetsAt: 1_789_140_026))
        XCTAssertEqual(stamp?.resetsAt, Date(timeIntervalSince1970: 1_789_140_026))
        XCTAssertEqual(stamp?.windowMinutes, 10080)
        XCTAssertNil(CodexTerminals.rateLimitStamp(inLine: metaTUI))
    }

    func testTerminalsLineFormatsKnownUnknownAccountAndUnknown() {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_GB")
        clock.timeZone = TimeZone(identifier: "UTC")
        clock.dateStyle = .none
        clock.timeStyle = .short
        let since = Date(timeIntervalSince1970: 1_788_568_279)  // 00:31 UTC

        XCTAssertEqual(CodexTerminals.format(CodexTerminals.Line(profileName: "Cedar", since: since), clock: clock),
                       "Terminals: Cedar since 00:31")
        XCTAssertEqual(CodexTerminals.format(CodexTerminals.Line(profileName: nil, since: since), clock: clock),
                       "Terminals: unknown account since 00:31")
        XCTAssertEqual(CodexTerminals.format(nil, clock: clock), "Terminals: unknown")
    }

    /// End to end over a temporary sessions tree: the newer `codex_exec`
    /// rollout is skipped, and the newest `codex-tui` rollout's LAST stamp
    /// wins over its first.
    func testNewestDaemonEvidenceSkipsExecRolloutsAndReadsTheLastStamp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuw-codex-sessions-\(UUID().uuidString)", isDirectory: true)
        let day = root.appendingPathComponent("2026/09/04", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tui = day.appendingPathComponent("rollout-2026-09-04T17-31-19-tui.jsonl")
        try [metaTUI, tokenCount(resetsAt: 1_789_140_000), tokenCount(resetsAt: 1_789_140_026)]
            .joined(separator: "\n").write(to: tui, atomically: true, encoding: .utf8)
        let exec = day.appendingPathComponent("rollout-2026-09-04T17-32-18-exec.jsonl")
        try [metaExec, tokenCount(resetsAt: 1_789_999_999)]
            .joined(separator: "\n").write(to: exec, atomically: true, encoding: .utf8)
        // The exec rollout is the NEWER file.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: exec.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: tui.path)

        let evidence = try XCTUnwrap(CodexTerminals.newestDaemonEvidence(sessionsRoot: root))
        XCTAssertEqual(evidence.resetsAt, Date(timeIntervalSince1970: 1_789_140_026), "the last stamp in the TUI rollout")
        XCTAssertEqual(evidence.windowMinutes, 10080)
        XCTAssertEqual(evidence.sessionStartedAt.timeIntervalSince1970, 1_788_568_279.308, accuracy: 0.001)

        try FileManager.default.removeItem(at: tui)
        XCTAssertNil(CodexTerminals.newestDaemonEvidence(sessionsRoot: root),
                     "a codex_exec rollout says nothing about terminals")
    }

    // MARK: - Setting

    func testRestartOnSwitchIsOffByDefault() {
        let store = SharedDataStore.shared
        let saved = store.loadCodexDaemonRestartOnSwitch()
        defer { store.saveCodexDaemonRestartOnSwitch(saved) }

        store.saveCodexDaemonRestartOnSwitch(false)
        XCTAssertFalse(store.loadCodexDaemonRestartOnSwitch(), "restarting somebody's daemon is opt-in")
        store.saveCodexDaemonRestartOnSwitch(true)
        XCTAssertTrue(store.loadCodexDaemonRestartOnSwitch())
        XCTAssertTrue(SharedDataStore.registeredKeys.contains { $0.key == "codexDaemonRestartOnSwitch_v1" && $0.status == .live },
                      "every key is registered — Settings › Advanced flags the unregistered ones")
    }
}
