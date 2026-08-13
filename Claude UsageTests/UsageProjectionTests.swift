//
//  UsageProjectionTests.swift
//  Claude UsageTests
//
//  Tests for the suspected-state burn-rate projection — the honest answer to
//  "the tile said 67% while my sessions hit the hard limit" (2026-08-12:
//  'Commits' sat 22 min blind behind burst 429s while parallel sessions
//  burned it 67%→100%). While reads fail, the display advances along the
//  MEASURED burn rate instead of freezing; it must never invent motion for
//  idle accounts, never survive a session-window rollover, and never exceed
//  100. Also covers the active-account backoff cap that ends the blindness.
//

import XCTest
@testable import Claude_Usage

final class UsageProjectionTests: XCTestCase {

    private let now = Date()

    private func history(_ points: [(secondsAgo: TimeInterval, pct: Double)]) -> [(at: Date, pct: Double)] {
        points.map { (now.addingTimeInterval(-$0.secondsAgo), $0.pct) }
    }

    // MARK: - projectSessionPercentage

    func testProjectsForwardAlongMeasuredBurnRate() {
        // 60% five minutes ago, 70% one minute ago → 2.5pp/min; one minute
        // later the estimate is ~72.5.
        let projected = MenuBarManager.projectSessionPercentage(
            history: history([(300, 60), (60, 70)]),
            sessionResetTime: now.addingTimeInterval(3600),
            now: now
        )
        XCTAssertNotNil(projected)
        XCTAssertEqual(projected!, 72.5, accuracy: 0.5)
    }

    func testProjectionClampsAtHundred() {
        // The Commits shape: fast burn, long blindness — the estimate parks
        // at 100, it does not run past it.
        let projected = MenuBarManager.projectSessionPercentage(
            history: history([(1500, 60), (1320, 67)]),
            sessionResetTime: now.addingTimeInterval(3600),
            now: now
        )
        XCTAssertEqual(projected, 100)
    }

    func testFlatOrDecliningTrendProjectsNothing() {
        // An idle account must not creep upward on jitter.
        XCTAssertNil(MenuBarManager.projectSessionPercentage(
            history: history([(300, 50), (60, 50)]),
            sessionResetTime: now.addingTimeInterval(3600),
            now: now
        ))
        XCTAssertNil(MenuBarManager.projectSessionPercentage(
            history: history([(300, 50), (60, 40)]),
            sessionResetTime: now.addingTimeInterval(3600),
            now: now
        ))
    }

    func testSinglePointOrTinySpanProjectsNothing() {
        XCTAssertNil(MenuBarManager.projectSessionPercentage(
            history: history([(60, 70)]),
            sessionResetTime: now.addingTimeInterval(3600),
            now: now
        ))
        // Two samples 5s apart: rate is measurement noise, not a burn rate.
        XCTAssertNil(MenuBarManager.projectSessionPercentage(
            history: history([(65, 60), (60, 62)]),
            sessionResetTime: now.addingTimeInterval(3600),
            now: now
        ))
    }

    func testRolledSessionWindowKillsProjection() {
        // The basis died with the window — fresh quota, nothing to project.
        XCTAssertNil(MenuBarManager.projectSessionPercentage(
            history: history([(300, 60), (60, 70)]),
            sessionResetTime: now.addingTimeInterval(-1),
            now: now
        ))
    }

    // MARK: - Display integration

    private func usage(
        session: Double,
        projected: Double? = nil,
        suspectedFor: TimeInterval? = 300
    ) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(3600)
        u.lastUpdated = now
        if let suspectedFor {
            u.rateLimitedUntil = now.addingTimeInterval(suspectedFor)
            u.rateLimitedInferred = true
        }
        u.projectedSessionPercentage = projected
        return u
    }

    func testSuspectedDisplayPrefersProjectionOverFrozenMeasurement() {
        // 67 measured, 96 projected → the tile says 96 (with the purple
        // suspected marking), not the frozen 67 that hid a real 100%.
        XCTAssertEqual(usage(session: 67, projected: 96).displaySessionPercentage, 96)
        // No projection basis (idle account) → last measured, unchanged.
        XCTAssertEqual(usage(session: 67).displaySessionPercentage, 67)
    }

    func testProjectionIgnoredOnceSuspicionEnds() {
        // Stamp expired: back to plain measured display even if a stale
        // projection value is still on the struct.
        XCTAssertEqual(
            usage(session: 67, projected: 96, suspectedFor: -1).displaySessionPercentage,
            67
        )
        // And decision seams never see projections at all.
        XCTAssertEqual(usage(session: 67, projected: 96).effectiveSessionPercentage, 100)
    }

    // MARK: - Active-account backoff cap

    func testActiveAccountRetriesEverySweep() {
        // 30s cap == one retry per sweep: the number that gates the
        // auto-switch is never more than ~1 sweep stale behind 429 noise
        // (the 120s re-arming cap produced a 22-minute blind window).
        XCTAssertEqual(MenuBarManager.burstBackoffCap(isActiveAccount: true), 30)
        XCTAssertEqual(MenuBarManager.burstBackoffCap(isActiveAccount: false), 480)
    }
}
