//
//  CodexDaemonRestartTests.swift
//  Claude UsageTests
//
//  The 2026-09-08 restart guard (docs/specs/codex-daemon-awareness.md,
//  "Restart on switch"): the elapsed column, the attached-session predicate
//  against a process list mirroring the incident (a stale code-mode host from
//  the previous evening plus the ChatGPT desktop app's helpers under the
//  daemon), the pure restart policy, the outgoing-login exhaustion rule, the
//  default-ON migration, the notification routing, and the scan's
//  newest-terminal-write.
//
//  No test here runs `ps`, signals a process or reads ~/.codex; the one
//  file-system test builds its own sessions tree in a temporary directory.
//  Fixture names follow the synthetic roster (Atlas, Cedar).
//

import UserNotifications
import XCTest
@testable import Claude_Usage

@MainActor
final class CodexDaemonRestartTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester/.codex", isDirectory: true)
    private let standaloneHost = "/Users/tester/.codex/packages/standalone/releases/0.153.3-aarch64-apple-darwin/bin/codex-code-mode-host"

    /// The daemon's children at 12:40 on 2026-09-08: the daemon from the
    /// previous evening, one code-mode host started 21:09 the night before,
    /// the ChatGPT desktop app's Computer Use helpers (spawned continuously,
    /// paths with spaces), one fresh host from a terminal the owner had just
    /// opened — and, beside them, a headless `codex exec` with its own host.
    private var incidentProcessList: String {
        """
        55232     1  1-16:25:33 /Users/tester/.codex/packages/standalone/current/codex app-server --listen unix:///Users/tester/.codex/app-server-control/app-server-control.sock
        55300 55232    15:25:10 \(standaloneHost)
        55401 55232       03:12 /Applications/ChatGPT.app/Contents/Frameworks/Codex Computer Use.app/Contents/MacOS/Codex Computer Use --serve
        55402 55232       02:01 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node launch.mjs
        55403 55232       01:58 /Applications/ChatGPT.app/Contents/Frameworks/Codex Computer Use.app/Contents/MacOS/Codex Computer Use --serve
        55450 55232       00:40 \(standaloneHost)
        61000     1       12:00 codex exec --model gpt-6-astra -o out.json
        61001 61000       11:59 \(standaloneHost)
        """
    }

    // MARK: - Process list

    func testElapsedColumnParsesEveryPsForm() {
        let fifteenHours: TimeInterval = 15 * 3600 + 25 * 60 + 10      // 15:25:10
        let overADay: TimeInterval = 86_400 + 16 * 3600 + 25 * 60 + 33  // 1-16:25:33
        XCTAssertEqual(CodexDaemon.parseElapsed("00:40"), 40)
        XCTAssertEqual(CodexDaemon.parseElapsed("15:25:10"), fifteenHours)
        XCTAssertEqual(CodexDaemon.parseElapsed("1-16:25:33"), overADay)
        XCTAssertNil(CodexDaemon.parseElapsed("-"))
        XCTAssertNil(CodexDaemon.parseElapsed("12"))

        let records = CodexDaemon.parseProcessList(incidentProcessList)
        XCTAssertEqual(records.count, 8)
        XCTAssertEqual(records[0].elapsed, overADay)
        XCTAssertEqual(records[0].executablePath, "/Users/tester/.codex/packages/standalone/current/codex")
        XCTAssertEqual(records[0].arguments.first, "app-server", "the command survives the extra column intact")
        XCTAssertEqual(records[1].elapsed, fifteenHours)
        XCTAssertEqual(records[6].executableName, "codex", "a bare command keeps its name")
        XCTAssertEqual(records[6].elapsed, 720)
    }

    // MARK: - Attached sessions

    /// The incident's blocker: "1 attached session" was a host from the
    /// previous evening, and the desktop app's helpers sit under the daemon
    /// too. Only code-mode hosts are sessions, and a 15-hour-old one with no
    /// terminal writing lately is abandoned.
    func testDesktopAppHelpersAreNotSessionsAndAStaleHostDoesNotBlock() {
        let records = CodexDaemon.parseProcessList(incidentProcessList)
        let idle = CodexDaemon.status(processes: records, codexHome: home, controlSocketPresent: true, terminalsActive: false)
        XCTAssertEqual(idle.daemon?.pid, 55232)
        XCTAssertEqual(idle.sessions.map(\.pid), [55300, 55450],
                       "code-mode hosts under the daemon only — not the Computer Use helpers, not the host under codex exec")
        XCTAssertEqual(idle.sessions.map(\.isStale), [true, false], "15 h old and idle is abandoned; 40 s old is live")
        XCTAssertEqual(idle.attachedSessions, 1)
        XCTAssertEqual(idle.staleSessions, 1)
        XCTAssertEqual(CodexDaemon.describe(idle.sessions), "pid 55300 (15h 25m, stale), pid 55450 (40s)")

        let busy = CodexDaemon.status(processes: records, codexHome: home, controlSocketPresent: true, terminalsActive: true)
        XCTAssertEqual(busy.attachedSessions, 2,
                       "a terminal rollout written lately means some TUI is in use — which host is unknowable, so nothing is stale")
        XCTAssertEqual(busy.staleSessions, 0)

        let ageless = CodexDaemon.attachedSessions(
            daemonPid: 55232, in: [ProcessRecord(pid: 9, ppid: 55232, command: standaloneHost)], terminalsActive: false)
        XCTAssertEqual(ageless.map(\.isStale), [false], "a host whose age is unknown is never called stale")
        XCTAssertEqual(CodexDaemon.describe([]), "none")
    }

    func testTerminalsAreActiveOnlyWithinTheWindow() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        XCTAssertTrue(CodexDaemon.terminalsActive(newestTerminalWrite: now.addingTimeInterval(-29 * 60), now: now))
        XCTAssertFalse(CodexDaemon.terminalsActive(newestTerminalWrite: now.addingTimeInterval(-31 * 60), now: now))
        XCTAssertFalse(CodexDaemon.terminalsActive(newestTerminalWrite: nil, now: now), "no terminal rollout at all is no activity")
        XCTAssertEqual(CodexDaemon.staleSessionAge, 12 * 3600)
        XCTAssertEqual(CodexDaemon.terminalActivityWindow, 30 * 60)
    }

    // MARK: - Restart policy

    private typealias Policy = CodexDaemonRestartPolicy

    func testExhaustedOutgoingLoginRestartsRegardlessOfAttachedSessions() {
        XCTAssertEqual(Policy.verdict(restartOnSwitch: true, outgoingLoginExhausted: true, liveSessions: 3), .restartExhaustedLogin,
                       "the incident: every attached session is already broken on the exhausted login")
        XCTAssertEqual(Policy.verdict(restartOnSwitch: true, outgoingLoginExhausted: true, liveSessions: 0), .restartExhaustedLogin)
        XCTAssertEqual(Policy.verdict(restartOnSwitch: false, outgoingLoginExhausted: true, liveSessions: 0), .holdToggleOff,
                       "the toggle still rules")
        XCTAssertTrue(Policy.Verdict.restartExhaustedLogin.restarts)
        XCTAssertFalse(Policy.Verdict.holdToggleOff.restarts)
    }

    func testUsableOutgoingLoginKeepsTheLiveSessionRule() {
        XCTAssertEqual(Policy.verdict(restartOnSwitch: true, outgoingLoginExhausted: false, liveSessions: 0), .restartIdle)
        XCTAssertEqual(Policy.verdict(restartOnSwitch: true, outgoingLoginExhausted: false, liveSessions: 2), .holdLiveSessions(2),
                       "a switch away from a WORKING login never kills somebody's terminal")
        XCTAssertEqual(Policy.verdict(restartOnSwitch: false, outgoingLoginExhausted: false, liveSessions: 0), .holdToggleOff)
        XCTAssertTrue(Policy.Verdict.restartIdle.restarts)
        XCTAssertFalse(Policy.Verdict.holdLiveSessions(2).restarts)
    }

    func testOutgoingLoginExhaustionReadsThresholdsStampsAndTheDeadFlag() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        func usage(session: Double = 0, weekly: Double = 0, sessionOpen: Bool = true, weeklyOpen: Bool = true,
                   sessionWindow: Bool? = nil) -> ClaudeUsage {
            var usage = ClaudeUsage.empty
            usage.sessionPercentage = session
            usage.sessionResetTime = now.addingTimeInterval(sessionOpen ? 3600 : -60)
            usage.weeklyPercentage = weekly
            usage.weeklyResetTime = now.addingTimeInterval(weeklyOpen ? 86_400 : -60)
            usage.hasSessionWindow = sessionWindow
            return usage
        }
        func exhausted(_ usage: ClaudeUsage?, dead: Bool = false) -> Bool {
            Policy.outgoingLoginIsExhausted(usage: usage, loginMarkedDead: dead, sessionThreshold: 95, weeklyThreshold: 99, now: now)
        }

        XCTAssertTrue(exhausted(usage(weekly: 100, sessionWindow: false)), "the incident: weekly 100 % on a weekly-only Codex account")
        XCTAssertTrue(exhausted(usage(weekly: 99)), "at the weekly threshold — where the auto-switch leaves")
        XCTAssertFalse(exhausted(usage(weekly: 98)))
        XCTAssertTrue(exhausted(usage(session: 95)))
        XCTAssertFalse(exhausted(usage(session: 94, weekly: 50)), "headroom on both windows — the old login still works")
        XCTAssertFalse(exhausted(usage(session: 100, sessionOpen: false)), "a session window that already reset is a stale cache, not evidence")
        XCTAssertFalse(exhausted(usage(weekly: 100, weeklyOpen: false)))
        XCTAssertFalse(exhausted(usage(session: 100, sessionWindow: false)), "no session window — that number is not a window")

        var affirmed = usage(session: 40)
        affirmed.rateLimitedUntil = now.addingTimeInterval(1800)
        XCTAssertTrue(exhausted(affirmed), "a server-affirmed throttle stamp")
        var inferred = affirmed
        inferred.rateLimitedInferred = true
        XCTAssertFalse(exhausted(inferred), "an inferred stamp is suspicion, never proof")
        affirmed.rateLimitedUntil = now.addingTimeInterval(-1)
        XCTAssertFalse(exhausted(affirmed), "an expired stamp")
        XCTAssertTrue(exhausted(nil, dead: true), "a dead login is broken for every session too")
        XCTAssertFalse(exhausted(nil))
    }

    // MARK: - Setting

    func testRestartOnSwitchReadsOnWhenTheKeyIsAbsent() {
        XCTAssertTrue(SharedDataStore.codexDaemonRestartOnSwitch(stored: nil),
                      "absent → ON: the 2026-09-08 default flip reaches installs that never touched the toggle")
        XCTAssertFalse(SharedDataStore.codexDaemonRestartOnSwitch(stored: false), "an explicit OFF sticks")
        XCTAssertTrue(SharedDataStore.codexDaemonRestartOnSwitch(stored: true))
    }

    // MARK: - Notification

    func testNotificationResponseRoutesOnlyTheRestartButton() {
        XCTAssertEqual(NotificationManager.responseAction(
            actionIdentifier: NotificationManager.restartCodexDaemonActionIdentifier,
            categoryIdentifier: NotificationManager.codexDaemonCategoryIdentifier), .restartCodexDaemon)
        XCTAssertNil(NotificationManager.responseAction(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            categoryIdentifier: NotificationManager.codexDaemonCategoryIdentifier), "a tap on the body restarts nothing")
        XCTAssertNil(NotificationManager.responseAction(actionIdentifier: UNNotificationDismissActionIdentifier, categoryIdentifier: "INFO_ALERT"))
        XCTAssertEqual(NotificationManager.codexDaemonCategory.actions.map(\.identifier), ["RESTART_CODEX_DAEMON"],
                       "the category the notice is posted under carries the button")
    }

    func testHoldNoticeCarriesTheRestartCategoryAndTheReminderHasItsOwnKey() {
        let manager = NotificationManager.shared
        manager.sendCodexDaemonHoldsPreviousLoginNotification(profileName: "Cedar", previousOwnerName: "Atlas", attachedSessions: 2)
        manager.sendCodexDaemonHoldsPreviousLoginNotification(profileName: "Cedar", previousOwnerName: "Atlas", attachedSessions: 2, reminder: true)
        let sent = manager.recentDeliveries.suffix(2)
        XCTAssertEqual(sent.map(\.category), [NotificationManager.codexDaemonCategoryIdentifier, NotificationManager.codexDaemonCategoryIdentifier])
        XCTAssertEqual(sent.map(\.identifier), ["codex_daemon_holds_Cedar", "codex_daemon_holds_Cedar_reminder"],
                       "the reminder is not swallowed by the first notice's dedupe key")
        XCTAssertEqual(sent.map(\.profile), ["Cedar", "Cedar"])
    }

    func testHoldLineNamesThePreviousOwnerOrUnknown() {
        let since = Date()
        XCTAssertEqual(CodexDaemonService.holdText(.init(daemonPid: 55232, previousOwnerName: "Atlas", newOwnerName: "Cedar", since: since)),
                       "Terminals still on Atlas")
        XCTAssertEqual(CodexDaemonService.holdText(.init(daemonPid: 55232, previousOwnerName: nil, newOwnerName: "Cedar", since: since)),
                       "Terminals still on unknown account")
        XCTAssertEqual(CodexDaemonService.reminderDelay, 10 * 60)
        XCTAssertEqual(CodexDaemonService.exitTimeout, 10)
    }

    // MARK: - Scan

    private let metaTUI = #"{"timestamp":"2026-09-08T09:31:19.405Z","type":"session_meta","payload":{"id":"01a06efa","timestamp":"2026-09-08T09:31:19.308Z","originator":"codex-tui","cli_version":"0.153.3"}}"#
    private let metaExec = #"{"timestamp":"2026-09-08T09:32:18.405Z","type":"session_meta","payload":{"id":"01a06efb","timestamp":"2026-09-08T09:32:18.308Z","originator":"codex_exec"}}"#
    private func tokenCount(resetsAt: Int) -> String {
        #"{"timestamp":"2026-09-08T09:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":19.0,"window_minutes":10080,"resets_at":\#(resetsAt)},"secondary":null,"plan_type":"pro"}}}"#
    }

    /// The staleness rule needs the last time ANY terminal wrote, which is
    /// the newest `codex-tui` rollout's modification date whether or not it
    /// carries a stamp yet; the evidence stays the newest STAMPED one, and a
    /// newer `codex_exec` rollout counts for neither.
    func testScanReportsTheNewestTerminalWriteEvenWithoutAStamp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuw-codex-sessions-\(UUID().uuidString)", isDirectory: true)
        let day = root.appendingPathComponent("2026/09/08", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func write(_ name: String, _ lines: [String], age: TimeInterval) throws {
            let url = day.appendingPathComponent(name)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try write("rollout-a-tui.jsonl", [metaTUI, tokenCount(resetsAt: 1_789_140_026)], age: 3600)
        try write("rollout-b-tui.jsonl", [metaTUI], age: 60)
        try write("rollout-c-exec.jsonl", [metaExec, tokenCount(resetsAt: 1_789_999_999)], age: 0)

        let scan = CodexTerminals.scanRollouts(sessionsRoot: root, cache: RolloutScanCache())
        XCTAssertEqual(scan.evidence?.resetsAt, Date(timeIntervalSince1970: 1_789_140_026), "the newest STAMPED terminal rollout")
        XCTAssertEqual(try XCTUnwrap(scan.newestTerminalWrite).timeIntervalSince1970, now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 1,
                       "the unstamped terminal rollout is the newest terminal write; the exec rollout is newer still and does not count")
        XCTAssertEqual(CodexTerminals.newestDaemonEvidence(sessionsRoot: root, cache: RolloutScanCache()), scan.evidence)
    }
}
