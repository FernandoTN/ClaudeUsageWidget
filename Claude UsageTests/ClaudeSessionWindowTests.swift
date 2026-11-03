//
//  ClaudeSessionWindowTests.swift
//  Claude UsageTests
//
//  Anthropic removed the 5-hour limit from some Claude accounts on
//  2026-10-30, per account rather than per plan: on 2026-11-02, 17 of 23
//  Max 20x accounts reported `five_hour: null` with no `session` row in
//  `limits`, while the other 4 still sent the window. The parser read null
//  as 0% and the healer invented a "resets in 5 h" boundary, so those
//  accounts showed a session gauge stuck at 0% with a countdown to nothing.
//  These tests pin the per-response decision, using the live shapes.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class ClaudeSessionWindowTests: XCTestCase {
    private let service = ClaudeAPIService()
    /// Whole seconds, so ISO-8601 strings built from it round-trip exactly.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
    }

    private var weeklyRows: String {
        """
        { "kind": "weekly_all", "percent": 86, "resets_at": "\(iso(2 * 86400))", "scope": null },
        { "kind": "weekly_scoped", "percent": 3, "resets_at": "\(iso(2 * 86400))",
          "scope": { "model": { "display_name": "Fable" } } }
        """
    }

    private let sessionRow = #"{ "kind": "session", "percent": 0, "resets_at": null, "scope": null }"#

    /// `fiveHour` is spliced in raw (`nil` leaves the key out entirely).
    private func payload(fiveHour: String?, limits: [String]) -> Data {
        let fiveHourLine = fiveHour.map { "\"five_hour\": \($0)," } ?? ""
        return """
        {
          \(fiveHourLine)
          "seven_day": { "utilization": 86.0, "resets_at": "\(iso(2 * 86400))" },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "limits": [\(limits.joined(separator: ",\n"))]
        }
        """.data(using: .utf8)!
    }

    func testAnAccountWithoutTheWindowReadsWeeklyOnly() throws {
        let usage = try service.parseUsageResponse(payload(fiveHour: "null", limits: [weeklyRows]))
        XCTAssertEqual(usage.hasSessionWindow, false)
        XCTAssertFalse(usage.providesSessionWindow)
        XCTAssertEqual(usage.sessionPercentage, 0)
        XCTAssertEqual(usage.weeklyPercentage, 86)
        XCTAssertEqual(usage.sessionResetTime, usage.weeklyResetTime)
        XCTAssertEqual(usage.fableWeeklyPercentage, 3)
    }

    func testAMissingKeyReadsLikeNull() throws {
        let usage = try service.parseUsageResponse(payload(fiveHour: nil, limits: [weeklyRows]))
        XCTAssertFalse(usage.providesSessionWindow)
    }

    func testAnIdleAccountThatKeepsTheWindowStillHasIt() throws {
        // The 4 that kept it: an object with zero utilization and no
        // resets_at, plus a session row. The boundary stays unknown for the
        // healer to carry forward; the parser never invents one.
        let usage = try service.parseUsageResponse(payload(
            fiveHour: #"{ "utilization": 0.0, "resets_at": null }"#,
            limits: [sessionRow, weeklyRows]
        ))
        XCTAssertTrue(usage.providesSessionWindow)
        XCTAssertEqual(usage.sessionResetTime, ClaudeUsage.unknownResetSentinel)
    }

    func testABurningWindowReadsAsBefore() throws {
        let usage = try service.parseUsageResponse(payload(
            fiveHour: #"{ "utilization": 40.0, "resets_at": "\#(iso(3600))" }"#,
            limits: [weeklyRows]
        ))
        XCTAssertTrue(usage.providesSessionWindow)
        XCTAssertEqual(usage.sessionPercentage, 40)
        XCTAssertEqual(usage.sessionResetTime, now.addingTimeInterval(3600))
    }

    func testASessionRowKeepsTheWindowWhenTheObjectIsMissing() throws {
        let usage = try service.parseUsageResponse(payload(fiveHour: "null", limits: [sessionRow, weeklyRows]))
        XCTAssertTrue(usage.providesSessionWindow)
    }
}
