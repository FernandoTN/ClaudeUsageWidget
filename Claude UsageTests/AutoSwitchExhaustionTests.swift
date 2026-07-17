//
//  AutoSwitchExhaustionTests.swift
//  Claude UsageTests
//
//  Tests for MenuBarManager.isQuotaExhausted — the auto-switch TRIGGER. It must
//  mirror the candidate headroom filter exactly: an account the auto-switch
//  would never pick as a target (no session, weekly, or Fable headroom) must
//  also not be kept as the active one. The original trigger only looked at the
//  session window, which stranded the app on an account whose WEEKLY limit ran
//  out at 20% session usage (real overnight incident).
//

import XCTest
@testable import Claude_Usage

final class AutoSwitchExhaustionTests: XCTestCase {

    // Anchored to the real clock: ClaudeUsage.effectiveSessionPercentage compares
    // sessionResetTime against Date() internally, not against the injected now.
    private let now = Date()

    private func usage(
        session: Double = 0,
        sessionResetIn: TimeInterval = 3600,
        weekly: Double = 0,
        weeklyResetIn: TimeInterval = 86_400,
        fable: Double? = nil,
        fableResetIn: TimeInterval? = nil
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: Int(session * 1000),
            sessionLimit: 100_000,
            sessionPercentage: session,
            sessionResetTime: now.addingTimeInterval(sessionResetIn),
            weeklyTokensUsed: Int(weekly * 10_000),
            weeklyLimit: 1_000_000,
            weeklyPercentage: weekly,
            weeklyResetTime: now.addingTimeInterval(weeklyResetIn),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            fableWeeklyPercentage: fable,
            fableWeeklyResetTime: fableResetIn.map { now.addingTimeInterval($0) },
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: now,
            userTimezone: .current
        )
    }

    func testHealthyUsageIsNotExhausted() {
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 40, weekly: 60, fable: 70, fableResetIn: 86_400), now: now))
    }

    func testSessionAtLimitIsExhausted() {
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(usage(session: 100, weekly: 20), now: now))
    }

    func testSessionAtLimitButWindowRolledOverIsNotExhausted() {
        // effectiveSessionPercentage treats a past sessionResetTime as 0%.
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 100, sessionResetIn: -60, weekly: 20), now: now))
    }

    func testWeeklyAtLimitIsExhaustedEvenWithSessionHeadroom() {
        // The overnight incident: weekly hit 100% while session sat at 20%.
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 100), now: now))
    }

    func testWeeklyAtLimitButWindowRolledOverIsNotExhausted() {
        // A weekly reset already in the past means the cached data predates the
        // rollover — full quota again, same as hasWeeklyHeadroom.
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 100, weeklyResetIn: -60), now: now))
    }

    func testFableAtLimitIsExhaustedEvenWithWeeklyHeadroom() {
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 40, fable: 100, fableResetIn: 86_400), now: now))
    }

    func testFableAtLimitWithRolledOverResetIsNotExhausted() {
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 40, fable: 100, fableResetIn: -60), now: now))
    }

    func testFableAtLimitWithNoResetTimeIsExhausted() {
        // No reset stamp to prove a rollover — matches hasFableWeeklyHeadroom.
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 40, fable: 100, fableResetIn: nil), now: now))
    }

    func testCodexStyleUsageWithoutFableWindow() {
        // Codex profiles report no Fable bucket at all; only session + weekly count.
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 40, fable: nil), now: now))
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 100, fable: nil), now: now))
    }

    // MARK: - Proactive threshold (default 95%)

    func testProactiveThresholdFiresBelowHardLimit() {
        // The point of the threshold: at 95% the account is exhausted for
        // auto-switch purposes even though the API would still accept requests.
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(usage(session: 95, weekly: 20), threshold: 95, now: now))
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 94.9, weekly: 20), threshold: 95, now: now))
    }

    func testProactiveThresholdAppliesToWeeklyAndFableWindows() {
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 95), threshold: 95, now: now))
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 40, fable: 95, fableResetIn: 86_400), threshold: 95, now: now))
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 94, fable: 94, fableResetIn: 86_400), threshold: 95, now: now))
    }

    func testProactiveThresholdStillRespectsRolledOverWindows() {
        // Rolled-over windows mean full quota regardless of the threshold.
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 96, sessionResetIn: -60, weekly: 20), threshold: 95, now: now))
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 96, weeklyResetIn: -60), threshold: 95, now: now))
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 20, weekly: 40, fable: 96, fableResetIn: -60), threshold: 95, now: now))
    }

    func testThresholdDefaultsToExactLimit() {
        // Callers that don't pass a threshold keep the historical >= 100 semantics.
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(usage(session: 99.9, weekly: 99.9), now: now))
    }

    // MARK: - Account-level throttle stamp

    func testThrottledAccountIsExhaustedDespiteLowCachedPercentages() {
        // The Stanford incident: cache frozen at 16/24/29 while the account's
        // usage endpoint 429s with a long Retry-After. The stamp must make the
        // trigger (and, via the shared threshold, candidate selection) treat
        // the account as having no capacity.
        var throttled = usage(session: 16, weekly: 24, fable: 29, fableResetIn: 86_400)
        throttled.rateLimitedUntil = now.addingTimeInterval(2918)
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(throttled, threshold: 95, now: now))
    }

    func testExpiredThrottleStampIsNotExhausted() {
        var recovered = usage(session: 16, weekly: 24)
        recovered.rateLimitedUntil = now.addingTimeInterval(-1)
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(recovered, threshold: 95, now: now))
    }
}
