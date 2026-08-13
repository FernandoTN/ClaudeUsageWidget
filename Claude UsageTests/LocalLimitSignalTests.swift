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

    // MARK: - CLI cached usage

    func testReadsCLICachedUsageShape() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuw-claude-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let json = """
        {"cachedUsageUtilization": {
            "accountUuid": "acb1c52d-333c-4852-8128-4c6748f0407d",
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
        XCTAssertEqual(cache?.accountUuid, "acb1c52d-333c-4852-8128-4c6748f0407d")
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
