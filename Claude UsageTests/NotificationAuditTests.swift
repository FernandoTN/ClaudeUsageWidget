//
//  NotificationAuditTests.swift
//  Claude UsageTests
//
//  The notification-volume audit from the 2026-09-05 idle-CPU diagnosis: 48
//  posts between 23:25 and 09:45, 35 of them with no log line. These replay
//  the night on a fixture roster through the real senders — `deliver` records
//  every send and, under XCTest, posts nothing — so the counts in the PR body
//  are measured, not estimated. The dedupe ledger lives in the isolated test
//  suite under XCTest; fixture names follow the synthetic roster.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class NotificationAuditTests: XCTestCase {

    private let manager = NotificationManager.shared
    private let roster = ["Atlas", "Birch", "Cedar", "Delta", "Elm", "Fjord", "Grove", "Harbor"]
    /// `fleetAlertDefaults_v1` as shipped: every band on.
    private let allBands = NotificationSettings(
        enabled: true, threshold75Enabled: true, threshold90Enabled: true, threshold95Enabled: true,
        soundName: "none", customThresholds: []
    )

    override func setUp() {
        super.setUp()
        roster.forEach { manager.clearNotificationsForProfile($0) }
        manager.resetDeliveryRecordsForTesting()
    }

    override func tearDown() {
        roster.forEach { manager.clearNotificationsForProfile($0) }
        manager.resetDeliveryRecordsForTesting()
        super.tearDown()
    }

    private func usage(session: Double) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = Date().addingTimeInterval(3600)
        return u
    }

    /// One sweep over the whole roster at one reading each.
    private func sweep(_ session: Double) {
        for name in roster {
            manager.checkAndNotify(usage: usage(session: session), profileName: name, settings: allBands)
        }
    }

    private var identifiers: [String] { manager.recentDeliveries.map(\.identifier) }

    /// The night: eight accounts each burn through a 5-hour window (75/90/95
    /// crossed on successive sweeps, then the window comes back) while the
    /// sweep re-reads every account every 30 s. Every send is a band alert or
    /// a reset notice, one per (profile, band) per window — 4 per account, 32
    /// for the roster — and repeat sweeps at the same reading post nothing.
    func testEightRotatingAccountsPostFourAlertsEachPerWindowAndNothingOnRepeatSweeps() {
        for reading in [10.0, 40.0, 76.0, 76.0, 76.0] { sweep(reading) }
        XCTAssertEqual(manager.recentDeliveries.count, 8, "one 75 % alert per account, however many sweeps read 76 %")
        XCTAssertEqual(identifiers.first, "Atlas_session_info_75")

        for reading in [91.0, 91.0, 96.0, 96.0, 100.0] { sweep(reading) }
        XCTAssertEqual(manager.recentDeliveries.count, 24, "90 % and 95 % once each per account")
        XCTAssertTrue(identifiers.contains("Cedar_session_warning_90"))
        XCTAssertTrue(identifiers.contains("Cedar_session_critical_95"))

        sweep(0)
        sweep(0)
        XCTAssertEqual(manager.recentDeliveries.count, 32, "one reset notice per account when its window comes back")
        XCTAssertTrue(identifiers.contains("Harbor_session_reset_0"))
        XCTAssertEqual(Set(manager.recentDeliveries.map(\.category)), ["USAGE_ALERT"])

        sweep(25)
        sweep(76)
        XCTAssertEqual(manager.recentDeliveries.count, 40, "the new window re-arms the 75 % band")
        XCTAssertEqual(Set(manager.recentDeliveries.compactMap(\.profile)).count, 8, "every send names its profile")
        XCTAssertEqual(manager.recentDeliveries.filter { $0.profile == "Atlas" }.map(\.identifier),
                       ["Atlas_session_info_75", "Atlas_session_warning_90", "Atlas_session_critical_95",
                        "Atlas_session_reset_0", "Atlas_session_info_75"])
    }

    /// The two one-shot-per-episode notices re-arm on every successful fetch,
    /// so a flapping endpoint could re-post them inside one window. A window
    /// is told once; the next window, and another profile, are told again.
    func testInferredThrottleAndProjectedExhaustionPostOncePerSessionWindow() {
        let window = Date().addingTimeInterval(3600)
        let next = window.addingTimeInterval(5 * 3600)
        manager.sendInferredThrottleNotification(profileName: "Atlas", sessionResetTime: window)
        manager.sendInferredThrottleNotification(profileName: "Atlas", sessionResetTime: window.addingTimeInterval(30))
        manager.sendProjectedExhaustionNotification(profileName: "Atlas", projectedPercentage: 96, sessionResetTime: window)
        manager.sendProjectedExhaustionNotification(profileName: "Atlas", projectedPercentage: 99, sessionResetTime: window)
        XCTAssertEqual(identifiers, ["inferred_throttle_Atlas", "projected_exhaustion_Atlas"],
                       "a second episode inside the same window (±2 min jitter) is not re-posted")

        manager.sendInferredThrottleNotification(profileName: "Atlas", sessionResetTime: next)
        manager.sendProjectedExhaustionNotification(profileName: "Atlas", projectedPercentage: 96, sessionResetTime: next)
        manager.sendInferredThrottleNotification(profileName: "Birch", sessionResetTime: window)
        XCTAssertEqual(identifiers.count, 5, "a new window and another profile each post again")
        XCTAssertEqual(manager.recentDeliveries.last?.profile, "Birch")
        XCTAssertTrue(manager.recentDeliveries.allSatisfy { $0.category == "INFO_ALERT" })
    }
}
