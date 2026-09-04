//
//  LocalLimitSignalTests.swift
//  Claude UsageTests
//
//  Tests for LocalLimitSignalService — the zero-network limit signals read
//  from Claude Code's own on-disk state: transcript rate-limit death events
//  ("You've hit your session limit · resets 10:50pm (America/Los_Angeles)")
//  and the CLI's cachedUsageUtilization bars in ~/.claude.json. These are the
//  ground truth the usage endpoint cannot provide while an account's own
//  sessions saturate its request bucket (the 'Commits' 67%-vs-real-100%
//  incident, 2026-08-12).
//

import XCTest
@testable import Claude_Usage

final class LocalLimitSignalTests: XCTestCase {

    // MARK: - Reset-time parsing

    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func date(_ h: Int, _ m: Int, tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: h, minute: m))!
    }

    func testParsesResetTimeWithMinutes() {
        let event = date(20, 29, tz: losAngeles)  // the real incident's event time
        let reset = LocalLimitSignalService.parseResetTime(
            from: "You've hit your session limit · resets 10:50pm (America/Los_Angeles)",
            eventTime: event
        )
        XCTAssertEqual(reset, date(22, 50, tz: losAngeles))
    }

    func testParsesResetTimeWithoutMinutesAndAM() {
        let event = date(20, 29, tz: losAngeles)
        let reset = LocalLimitSignalService.parseResetTime(
            from: "You've hit your session limit · resets 3am (America/Los_Angeles)",
            eventTime: event
        )
        // 3am is before 8:29pm — the reset is TOMORROW's 3am, never the past.
        XCTAssertNotNil(reset)
        XCTAssertGreaterThan(reset!, event)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = losAngeles
        XCTAssertEqual(cal.component(.hour, from: reset!), 3)
        XCTAssertEqual(cal.component(.day, from: reset!), 13)
    }

    func testUnparseableTextReturnsNil() {
        XCTAssertNil(LocalLimitSignalService.parseResetTime(
            from: "Rate limited. Please try again later.", eventTime: Date()
        ))
        XCTAssertNil(LocalLimitSignalService.parseResetTime(
            from: "resets 10:50pm (Not/AZone)", eventTime: Date()
        ))
    }

    // MARK: - Transcript scanning

    func testScanFindsRateLimitEventInTailAndIgnoresOldOnes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuw-tripwire-\(UUID().uuidString)/proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let recent = Date().addingTimeInterval(-60)
        let stale = Date().addingTimeInterval(-3600)
        let lines = [
            #"{"type":"user","timestamp":"\#(iso.string(from: recent))"}"#,
            #"{"type":"assistant","error":"rate_limit","apiErrorStatus":429,"timestamp":"\#(iso.string(from: stale))","message":{"content":"You've hit your session limit · resets 9:00pm (America/Los_Angeles)"}}"#,
            #"{"type":"assistant","error":"rate_limit","apiErrorStatus":429,"timestamp":"\#(iso.string(from: recent))","message":{"content":[{"type":"text","text":"You've hit your session limit · resets 10:50pm (America/Los_Angeles)"}]}}"#,
        ].joined(separator: "\n")
        try lines.write(to: dir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let events = LocalLimitSignalService.scanRateLimitEvents(
            since: Date().addingTimeInterval(-300),
            root: dir.deletingLastPathComponent().path
        )
        // The hour-old event is filtered by `since`; the recent one is found
        // with its reset parsed from array-form message content.
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].at.timeIntervalSince1970, recent.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(events[0].resetsAt)
    }

    func testScanRunsOffTheMainActor() async throws {
        // Given: a transcript the scan will actually read (an empty walk would
        // prove nothing about where the reading happens).
        let root = try Self.makeTranscriptTree(
            files: ["proj/session.jsonl": Self.rateLimitLine(resets: "10:50pm")]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // When: driven from a detached task through a NONISOLATED helper.
        // The helper is the probe: it can only call `scanRateLimitEvents`
        // synchronously — with no actor hop — while the service is
        // nonisolated, so the thread it observes IS the thread that walked the
        // tree. Restore the implicit `@MainActor` on the enum and this file
        // stops compiling cleanly, and `MenuBarManager.swift:2310` regains its
        // "expression is 'async' but is not marked with 'await'" warning.
        let result = await Task.detached(priority: .utility) {
            scanRecordingThread(root: root.path)
        }.value

        // Then: the 12 GB walk did not happen on the UI thread.
        XCTAssertFalse(result.beforeOnMain)
        XCTAssertFalse(result.afterOnMain)
        XCTAssertEqual(result.count, 1, "the scan must really have read the transcript")
    }

    func testScanPrunesToolResultsSubtrees() throws {
        // Given: a real transcript beside a rate-limit-shaped payload dump in
        // a `tool-results` subtree — the directory family that holds most of
        // the file count under ~/.claude/projects.
        let root = try Self.makeTranscriptTree(files: [
            "proj/session.jsonl": Self.rateLimitLine(resets: "10:50pm"),
            "proj/tool-results/payload.jsonl": Self.rateLimitLine(resets: "3:15am"),
            "proj/tool-results/nested/deeper.jsonl": Self.rateLimitLine(resets: "4:15am"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        // When
        let events = LocalLimitSignalService.scanRateLimitEvents(
            since: Date().addingTimeInterval(-300), root: root.path
        )

        // Then: only the sibling transcript is reported. Identifying it by its
        // parsed reset hour proves WHICH file was read, not merely how many.
        XCTAssertEqual(events.count, 1)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = losAngeles
        XCTAssertEqual(cal.component(.hour, from: try XCTUnwrap(events[0].resetsAt)), 22)
    }

    // MARK: - Fixtures

    /// One `error: "rate_limit"` transcript line, stamped a minute ago so the
    /// scan's `since` filter keeps it.
    private static func rateLimitLine(resets: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let at = iso.string(from: Date().addingTimeInterval(-60))
        return #"{"type":"assistant","error":"rate_limit","apiErrorStatus":429,"timestamp":"\#(at)","message":{"content":"You've hit your session limit · resets \#(resets) (America/Los_Angeles)"}}"#
    }

    /// Builds a throwaway tree from relative path → file contents and returns
    /// its root (the caller removes it).
    private static func makeTranscriptTree(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuw-scan-\(UUID().uuidString)")
        for (relative, contents) in files {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: - CLI cached usage

    func testReadsCLICachedUsageShape() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuw-claude-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let json = """
        {"cachedUsageUtilization": {
            "accountUuid": "11111111-2222-4333-8444-555555555555",
            "fetchedAtMs": 1786600000000,
            "utilization": {"limits": [
                {"kind":"session","group":"session","percent":29,"severity":"normal","is_active":false,"scope":null,"resets_at":"2026-08-13T05:49:59.889031+00:00"},
                {"kind":"weekly_all","group":"weekly","percent":46,"severity":"normal","is_active":false,"scope":null,"resets_at":"2026-08-16T07:59:59.889061+00:00"},
                {"kind":"weekly_scoped","group":"weekly","percent":53,"severity":"normal","is_active":true,"resets_at":"2026-08-16T07:59:59.889306+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}
            ]}
        }}
        """
        try json.write(to: file, atomically: true, encoding: .utf8)

        let cache = LocalLimitSignalService.readCLICachedUsage(path: file.path)
        XCTAssertNotNil(cache)
        XCTAssertEqual(cache?.accountUuid, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(cache?.sessionPercent, 29)
        XCTAssertEqual(cache?.weeklyPercent, 46)
        XCTAssertEqual(cache?.fablePercent, 53)
        XCTAssertNotNil(cache?.sessionResetsAt)
        XCTAssertEqual(cache?.fetchedAt.timeIntervalSince1970 ?? 0, 1_786_600_000, accuracy: 1)
    }

    func testMissingCacheReturnsNil() {
        XCTAssertNil(LocalLimitSignalService.readCLICachedUsage(path: "/nonexistent/claude.json"))
    }
}

/// Probe for `testScanRunsOffTheMainActor`. Declared `nonisolated` at file
/// scope because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise
/// pin it to the main actor and it could no longer observe anything useful.
private nonisolated func scanRecordingThread(
    root: String
) -> (beforeOnMain: Bool, afterOnMain: Bool, count: Int) {
    let before = Thread.isMainThread
    let events = LocalLimitSignalService.scanRateLimitEvents(
        since: Date().addingTimeInterval(-300), root: root
    )
    return (before, Thread.isMainThread, events.count)
}
