//
//  WeeklyWindowPrimingPayloadTests.swift
//  Claude UsageTests
//
//  The three real `wham/usage` shapes measured with each account's own token
//  on 2026-09-09 09:12 (docs/specs/weekly-window-priming.md, "Semantics"):
//  an IDLE account is reported with a PLACEHOLDER window (used 0 %,
//  reset_after == limit_window_seconds, reset_at = now + 7 d advancing with
//  every poll), an active one counts down, an exhausted one counts down with
//  `limit_reached`. Stage 1 waited for a missing window object and never
//  fired. No network: the payloads are literals; fixture names follow the
//  synthetic roster.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class WeeklyWindowPrimingPayloadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 604800

    private func payload(used: Int, resetAfter: Int, resetAt: Date, limitReached: Bool = false) -> Data {
        Data("""
        {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":\(used),"limit_window_seconds":604800,
        "reset_after_seconds":\(resetAfter),"reset_at":\(Int(resetAt.timeIntervalSince1970)),"limit_reached":\(limitReached)},
        "secondary_window":null},"rate_limit_reset_credits":null}
        """.utf8)
    }

    // MARK: - The three shapes

    func testIdlePlaceholderReadsAsClosed() throws {
        // xLucifer (dev): used 0, reset_after 604800, reset_at exactly now + 7 d.
        let usage = try CodexUsageService.shared.parseUsageResponse(payload(used: 0, resetAfter: 604800, resetAt: Date().addingTimeInterval(week)))
        XCTAssertEqual(usage.weeklyWindowOpen, false)
        XCTAssertEqual(usage.weeklyResetTime, ClaudeUsage.unknownResetSentinel)
        XCTAssertEqual(usage.weeklyWindowSeconds, 604800)
        XCTAssertEqual(usage.hasSessionWindow, false)
        XCTAssertEqual(WeeklyWindowState.of(usage, provider: .codex, now: Date()), .closed)

        var healed = usage
        healed.healMissingResetStamps(previous: nil, now: now)
        XCTAssertEqual(healed.weeklyWindowOpen, false)
        XCTAssertEqual(healed.weeklyResetProjected, true)
        XCTAssertEqual(healed.weeklyResetTime, now.addingTimeInterval(week))
    }

    func testActiveAndExhaustedWindowsReadAsOpen() throws {
        // xFernando (dev): used 28, reset_after 582757 — the clock is running.
        let activeReset = Date().addingTimeInterval(582757)
        let active = try CodexUsageService.shared.parseUsageResponse(payload(used: 28, resetAfter: 582757, resetAt: activeReset))
        XCTAssertEqual(active.weeklyWindowOpen, true)
        XCTAssertEqual(active.weeklyPercentage, 28)
        XCTAssertEqual(active.weeklyResetTime.timeIntervalSince1970, activeReset.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(WeeklyWindowState.of(active, provider: .codex, now: Date()), .open(resetAt: active.weeklyResetTime))

        // xFenrir (dev): used 100, reset_after 466209, limit_reached.
        let exhaustedReset = Date().addingTimeInterval(466209)
        let exhausted = try CodexUsageService.shared.parseUsageResponse(payload(used: 100, resetAfter: 466209, resetAt: exhaustedReset, limitReached: true))
        XCTAssertEqual(exhausted.weeklyWindowOpen, true)
        XCTAssertEqual(exhausted.weeklyPercentage, 100)
        XCTAssertEqual(WeeklyWindowState.of(exhausted, provider: .codex, now: Date()), .open(resetAt: exhausted.weeklyResetTime))
    }

    func testAMissingWindowObjectStillReadsAsClosed() throws {
        let usage = try CodexUsageService.shared.parseUsageResponse(Data(#"{"plan_type":"pro","rate_limit":{"primary_window":null,"secondary_window":null}}"#.utf8))
        XCTAssertEqual(usage.weeklyWindowOpen, false)
        XCTAssertEqual(usage.weeklyResetTime, ClaudeUsage.unknownResetSentinel)
        XCTAssertNil(usage.weeklyWindowSeconds)
    }

    // MARK: - The rules

    func testPlaceholderRuleBoundaries() {
        let rule = CodexWindowPlaceholder.self
        XCTAssertTrue(rule.isPlaceholder(usedPercent: 0, resetAfter: 604800, resetAt: nil, windowSeconds: 604800, now: now))
        XCTAssertTrue(rule.isPlaceholder(usedPercent: 0, resetAfter: 604800 - 120, resetAt: nil, windowSeconds: 604800, now: now), "server rounding inside the tolerance")
        XCTAssertFalse(rule.isPlaceholder(usedPercent: 0, resetAfter: 604800 - 121, resetAt: nil, windowSeconds: 604800, now: now), "the clock has run for two minutes")
        XCTAssertFalse(rule.isPlaceholder(usedPercent: 1, resetAfter: 604800, resetAt: nil, windowSeconds: 604800, now: now), "anything used is a running window")
        // No reset_after: reset_at against now + window; no window length: the default 7 d.
        XCTAssertTrue(rule.isPlaceholder(usedPercent: 0, resetAfter: nil, resetAt: now.addingTimeInterval(week - 30), windowSeconds: nil, now: now))
        XCTAssertFalse(rule.isPlaceholder(usedPercent: 0, resetAfter: nil, resetAt: now.addingTimeInterval(week - 3600), windowSeconds: nil, now: now))
        XCTAssertFalse(rule.isPlaceholder(usedPercent: 0, resetAfter: nil, resetAt: nil, windowSeconds: nil, now: now), "nothing to compare is no evidence")

        let reported = now.addingTimeInterval(week)
        XCTAssertTrue(rule.advanced(previousReset: reported, previousReported: true, reset: reported.addingTimeInterval(60), usedPercent: 0))
        XCTAssertFalse(rule.advanced(previousReset: reported, previousReported: true, reset: reported.addingTimeInterval(1), usedPercent: 0), "±1 s jitter is not drift")
        XCTAssertFalse(rule.advanced(previousReset: reported, previousReported: true, reset: reported.addingTimeInterval(600), usedPercent: 3), "a used window never drifts; a moved stamp with usage is a new window")
        XCTAssertFalse(rule.advanced(previousReset: reported, previousReported: false, reset: reported.addingTimeInterval(600), usedPercent: 0), "a projected previous stamp is no evidence")
    }

    func testHealerCrossCheckClosesADriftingReportedResetAndKeepsAFixedOne() {
        func reported(reset: Date, used: Double = 0) -> ClaudeUsage {
            var usage = ClaudeUsage.empty
            usage.hasSessionWindow = false
            usage.weeklyWindowOpen = true
            usage.weeklyWindowSeconds = week
            usage.weeklyPercentage = used
            usage.weeklyResetTime = reset
            usage.lastUpdated = now
            return usage
        }
        // The reported reset moved 90 s between polls at 0 %: a placeholder the parser rule missed.
        let previous = reported(reset: now.addingTimeInterval(week - 100))
        var drifting = reported(reset: now.addingTimeInterval(week - 10))
        drifting.healMissingResetStamps(previous: previous, now: now)
        XCTAssertEqual(drifting.weeklyWindowOpen, false)
        XCTAssertEqual(drifting.weeklyResetProjected, true)
        XCTAssertEqual(WeeklyWindowState.of(drifting, provider: .codex, now: now), .closed)

        // The same stamp again (±1 s): a running window.
        var fixed = reported(reset: now.addingTimeInterval(week - 99))
        fixed.healMissingResetStamps(previous: previous, now: now)
        XCTAssertEqual(fixed.weeklyWindowOpen, true)
        XCTAssertNil(fixed.weeklyResetProjected)

        // A previous CLOSED (projected) stamp is no evidence: the parser rule decides.
        var closedBefore = previous
        closedBefore.weeklyWindowOpen = false
        closedBefore.weeklyResetProjected = true
        var afterPrime = reported(reset: now.addingTimeInterval(week - 400))
        afterPrime.healMissingResetStamps(previous: closedBefore, now: now)
        XCTAssertEqual(afterPrime.weeklyWindowOpen, true)
    }

    // MARK: - The dashboard line

    func testDashboardPrintsNoWindowIdleForAClosedWindow() {
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = false
        usage.weeklyWindowOpen = false
        usage.weeklyResetProjected = true
        usage.weeklyResetTime = now.addingTimeInterval(week)
        let countdown = DashboardModel_weeklyReset(usage)
        XCTAssertTrue(countdown.idle)
        XCTAssertNil(countdown.resetAt)
        XCTAssertEqual(DashboardFormatting.resetCountdown(countdown, now: now), "W no window (idle)")
        XCTAssertTrue(DashboardFormatting.resetHelp(countdown, now: now).contains("closed"))

        var running = usage
        running.weeklyWindowOpen = true
        running.weeklyResetProjected = nil
        let open = DashboardModel_weeklyReset(running)
        XCTAssertFalse(open.idle)
        XCTAssertEqual(open.resetAt, running.weeklyResetTime)
    }

    private func DashboardModel_weeklyReset(_ usage: ClaudeUsage) -> ResetCountdown {
        DashboardSnapshot.weeklyReset(for: usage, thresholds: ReadinessThresholds(session: 95, weekly: 99), now: now)
    }
}
