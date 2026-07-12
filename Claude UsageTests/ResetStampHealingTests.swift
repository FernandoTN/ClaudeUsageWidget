//
//  ResetStampHealingTests.swift
//  Claude UsageTests
//
//  Tests for ClaudeUsage.healMissingResetStamps — the carry-forward that
//  replaces sentinel reset stamps (windows the API reported with no resets_at,
//  i.e. rolled over while the account was idle). The old behavior fabricated
//  "next Monday 12:59pm", which made an idle account look like the
//  soonest-reset auto-switch candidate (real incident: the switch picked the
//  account with the FARTHEST true reset because its phantom stamp said
//  "tomorrow").
//

import XCTest
@testable import Claude_Usage

final class ResetStampHealingTests: XCTestCase {

    private let now = Date()

    private func usage(
        sessionReset: Date,
        weeklyReset: Date,
        fable: Double? = nil,
        fableReset: Date? = nil
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: 0,
            sessionResetTime: sessionReset,
            weeklyTokensUsed: 0,
            weeklyLimit: 1_000_000,
            weeklyPercentage: 0,
            weeklyResetTime: weeklyReset,
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            fableWeeklyPercentage: fable,
            fableWeeklyResetTime: fableReset,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: now,
            userTimezone: .current
        )
    }

    private var sentinel: Date { ClaudeUsage.unknownResetSentinel }

    // MARK: Session

    func testSessionSentinelCarriesForwardFutureStamp() {
        let prev = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: now.addingTimeInterval(86_400))
        var new = usage(sessionReset: sentinel, weeklyReset: now.addingTimeInterval(86_400))
        new.healMissingResetStamps(previous: prev, now: now)
        XCTAssertEqual(new.sessionResetTime, prev.sessionResetTime)
    }

    func testSessionSentinelWithExpiredPreviousFallsBackToFiveHours() {
        let prev = usage(sessionReset: now.addingTimeInterval(-60), weeklyReset: now.addingTimeInterval(86_400))
        var new = usage(sessionReset: sentinel, weeklyReset: now.addingTimeInterval(86_400))
        new.healMissingResetStamps(previous: prev, now: now)
        XCTAssertEqual(new.sessionResetTime, now.addingTimeInterval(5 * 3600))
    }

    func testSessionSentinelWithNoHistoryFallsBackToFiveHours() {
        var new = usage(sessionReset: sentinel, weeklyReset: now.addingTimeInterval(86_400))
        new.healMissingResetStamps(previous: nil, now: now)
        XCTAssertEqual(new.sessionResetTime, now.addingTimeInterval(5 * 3600))
    }

    // MARK: Weekly

    func testWeeklySentinelProjectsPreviousBoundaryForward() {
        // Previous boundary passed 1h ago (the rollover that emptied the window);
        // the healed stamp is that boundary + 7 days — the account's REAL next
        // reset, not a fabricated near-future one.
        let passedBoundary = now.addingTimeInterval(-3600)
        let prev = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: passedBoundary)
        var new = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: sentinel)
        new.healMissingResetStamps(previous: prev, now: now)
        XCTAssertEqual(new.weeklyResetTime, passedBoundary.addingTimeInterval(7 * 24 * 3600))
    }

    func testWeeklySentinelKeepsStillFutureBoundary() {
        let futureBoundary = now.addingTimeInterval(2 * 86_400)
        let prev = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: futureBoundary)
        var new = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: sentinel)
        new.healMissingResetStamps(previous: prev, now: now)
        XCTAssertEqual(new.weeklyResetTime, futureBoundary)
    }

    func testWeeklySentinelWithNoHistoryFallsBackToSevenDays() {
        var new = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: sentinel)
        new.healMissingResetStamps(previous: nil, now: now)
        XCTAssertEqual(new.weeklyResetTime, now.addingTimeInterval(7 * 24 * 3600))
    }

    func testVeryStaleBoundaryProjectsPastNow() {
        let staleBoundary = now.addingTimeInterval(-20 * 86_400)  // ~3 weeks ago
        let projected = ClaudeUsage.projectedWeeklyBoundary(staleBoundary, after: now)
        XCTAssertGreaterThan(projected, now)
        XCTAssertLessThanOrEqual(projected.timeIntervalSince(now), 7 * 24 * 3600)
    }

    // MARK: Fable

    func testFableMissingStampCarriesProjectedBoundary() {
        let passedBoundary = now.addingTimeInterval(-3600)
        let prev = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: now.addingTimeInterval(86_400),
                         fable: 94, fableReset: passedBoundary)
        var new = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: now.addingTimeInterval(86_400),
                        fable: 0, fableReset: nil)
        new.healMissingResetStamps(previous: prev, now: now)
        XCTAssertEqual(new.fableWeeklyResetTime, passedBoundary.addingTimeInterval(7 * 24 * 3600))
    }

    func testFableAbsentStaysAbsent() {
        // A plan with no Fable window (fable nil) must not inherit a stamp.
        let prev = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: now.addingTimeInterval(86_400),
                         fable: 94, fableReset: now.addingTimeInterval(86_400))
        var new = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: now.addingTimeInterval(86_400),
                        fable: nil, fableReset: nil)
        new.healMissingResetStamps(previous: prev, now: now)
        XCTAssertNil(new.fableWeeklyResetTime)
    }

    // MARK: No-op cases

    func testRealStampsAreUntouched() {
        let prev = usage(sessionReset: now.addingTimeInterval(-9999), weeklyReset: now.addingTimeInterval(-9999))
        let sessionStamp = now.addingTimeInterval(4000)
        let weeklyStamp = now.addingTimeInterval(5 * 86_400)
        var new = usage(sessionReset: sessionStamp, weeklyReset: weeklyStamp, fable: 20, fableReset: weeklyStamp)
        new.healMissingResetStamps(previous: prev, now: now)
        XCTAssertEqual(new.sessionResetTime, sessionStamp)
        XCTAssertEqual(new.weeklyResetTime, weeklyStamp)
        XCTAssertEqual(new.fableWeeklyResetTime, weeklyStamp)
    }

    func testHealingIsIdempotent() {
        let prev = usage(sessionReset: now.addingTimeInterval(1800), weeklyReset: now.addingTimeInterval(-3600))
        var new = usage(sessionReset: sentinel, weeklyReset: sentinel)
        new.healMissingResetStamps(previous: prev, now: now)
        let once = new
        new.healMissingResetStamps(previous: prev, now: now)
        XCTAssertEqual(new, once)
    }
}
