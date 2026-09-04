//
//  WeeklyOnlyNotificationTests.swift
//  Claude UsageTests
//
//  Covers the three weekly-only-provider defects from the 2026-09-03 Codex
//  parity audit:
//
//  H1  MenuBarManager's auto-switch preflight keyed its 25/50/75/90 milestones
//      off the SESSION percentage. A weekly-only provider (Codex since OpenAI
//      collapsed its 5h/weekly pair into one 7-day window, Grok always)
//      reports session 0 forever, so preflight never armed for that provider's
//      owner and dead candidate logins were only ever discovered inside the
//      auto-switch walk itself.
//  H5  NotificationManager computed threshold alerts from the session window
//      only, so a Codex account could never cross a threshold; and the
//      weeklyWarning/weeklyCritical alert types had zero callers.
//  H9  Setup-complete meant "the FOCUSED profile has credentials", so a
//      Codex-only install reopened the wizard on every launch.
//
//  These exercise the pure decision seams. Delivery-side dedupe (the
//  persisted `sentNotifications` set) and the sweep's per-profile call site
//  are not reachable from a unit test — they need UNUserNotificationCenter
//  and the network sweep respectively.
//

import XCTest
@testable import Claude_Usage

final class WeeklyOnlyNotificationTests: XCTestCase {

    private let now = Date()

    /// `effectiveSessionPercentage` compares `sessionResetTime` with the real
    /// clock, so every window here is anchored in the future.
    private func usage(
        session: Double = 0,
        weekly: Double = 0,
        hasSessionWindow: Bool? = nil,
        weeklyResetIn: TimeInterval = 5 * 86_400
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 100_000,
            sessionPercentage: session,
            sessionResetTime: now.addingTimeInterval(3600),
            hasSessionWindow: hasSessionWindow,
            weeklyTokensUsed: 0,
            weeklyLimit: 1_000_000,
            weeklyPercentage: weekly,
            weeklyResetTime: now.addingTimeInterval(weeklyResetIn),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: now,
            userTimezone: .current
        )
    }

    // MARK: - H1: preflight milestone keying

    func testPreflightMilestoneUsesWeeklyForWeeklyOnlyProvider() {
        // Given: today's live Codex shape — one 7-day window, session 0.
        let codex = usage(session: 0, weekly: 62, hasSessionWindow: false)
        // Then: the milestone reads 62, not 0, so the 50% milestone arms.
        XCTAssertEqual(MenuBarManager.preflightMilestonePercentage(codex), 62)
    }

    func testPreflightMilestoneTakesTheFullerWindowWhenSessionExists() {
        // Claude keeps its session behaviour, and a weekly that is further
        // along still arms the milestone (the overnight weekly-exhaustion
        // shape the auto-switch trigger already handles).
        XCTAssertEqual(MenuBarManager.preflightMilestonePercentage(usage(session: 60, weekly: 10)), 60)
        XCTAssertEqual(MenuBarManager.preflightMilestonePercentage(usage(session: 20, weekly: 80)), 80)
    }

    func testPreflightMilestoneBoundaryFollowsTheKeyedWindow() {
        let claude = usage(session: 30, weekly: 30)
        XCTAssertEqual(MenuBarManager.preflightMilestoneBoundary(claude), claude.sessionResetTime)

        let codex = usage(weekly: 30, hasSessionWindow: false)
        XCTAssertEqual(MenuBarManager.preflightMilestoneBoundary(codex), codex.weeklyResetTime)
    }

    // MARK: - H5: threshold alerts on the weekly window

    func testWeeklyOnlyProfileCrossingNinetyGetsOneWeeklyAlert() {
        let codex = usage(weekly: 91, hasSessionWindow: false)
        let alert = NotificationManager.thresholdAlert(usage: codex, settings: NotificationSettings())

        // One alert, the highest crossed threshold, on the WEEKLY window.
        XCTAssertEqual(alert?.type, .weeklyWarning)
        XCTAssertEqual(alert?.level, 90)
        XCTAssertEqual(alert?.percentage, 91)
        XCTAssertEqual(alert?.resetTime, codex.weeklyResetTime)

        // The decision is stable across a re-read of the same window, so the
        // 30s sweep asks for the same identifier the dedupe already holds.
        let again = NotificationManager.thresholdAlert(usage: codex, settings: NotificationSettings())
        XCTAssertEqual(alert, again)
    }

    func testWeeklyOnlyProfileAtNinetyFiveIsCritical() {
        let codex = usage(weekly: 97, hasSessionWindow: false)
        let alert = NotificationManager.thresholdAlert(usage: codex, settings: NotificationSettings())
        XCTAssertEqual(alert?.type, .weeklyCritical)
        XCTAssertEqual(alert?.level, 95)
    }

    func testWeeklyOnlyProfileBelowEveryThresholdIsSilent() {
        let codex = usage(weekly: 61, hasSessionWindow: false)
        XCTAssertNil(NotificationManager.thresholdAlert(usage: codex, settings: NotificationSettings()))
    }

    func testSessionProviderKeepsSessionAlertsAndGainsNoWeeklyStream() {
        // A Claude account with a nearly-spent WEEK but a quiet session must
        // keep behaving exactly as before — no new weekly notifications.
        let claude = usage(session: 12, weekly: 99)
        XCTAssertNil(NotificationManager.thresholdAlert(usage: claude, settings: NotificationSettings()))

        let busy = usage(session: 92, weekly: 99)
        let alert = NotificationManager.thresholdAlert(usage: busy, settings: NotificationSettings())
        XCTAssertEqual(alert?.type, .sessionWarning)
        XCTAssertEqual(alert?.level, 90)
        XCTAssertEqual(alert?.resetTime, busy.sessionResetTime)
    }

    func testEachProfilesOwnTogglesGateItsAlert() {
        // The sweep passes each profile's own NotificationSettings, which is
        // what makes the per-profile switches in Settings → General real.
        let codex = usage(weekly: 92, hasSessionWindow: false)

        let off = NotificationSettings(enabled: false)
        XCTAssertNil(NotificationManager.thresholdAlert(usage: codex, settings: off))

        // 90 and 95 disabled, 75 left on: the 75 alert is what 92% earns.
        let only75 = NotificationSettings(threshold90Enabled: false, threshold95Enabled: false)
        let alert = NotificationManager.thresholdAlert(usage: codex, settings: only75)
        XCTAssertEqual(alert?.level, 75)
        XCTAssertEqual(alert?.type, .weeklyWarning)

        // A custom threshold participates too.
        let custom = NotificationSettings(
            threshold75Enabled: false,
            threshold90Enabled: false,
            threshold95Enabled: false,
            customThresholds: [80]
        )
        XCTAssertEqual(NotificationManager.thresholdAlert(usage: codex, settings: custom)?.level, 80)
    }

    func testWeeklyWindowRolloverIsWhatReArmsWeeklyAlerts() {
        let boundary = now.addingTimeInterval(5 * 86_400)
        // Same window reported with API jitter — not a rollover.
        XCTAssertFalse(NotificationManager.windowRolledOver(
            previousBoundary: boundary, current: boundary.addingTimeInterval(60)))
        // A real weekly rollover.
        XCTAssertTrue(NotificationManager.windowRolledOver(
            previousBoundary: boundary, current: boundary.addingTimeInterval(7 * 86_400)))
        // Nothing seen yet is not a rollover — it must not clear the records
        // a previous app run persisted.
        XCTAssertFalse(NotificationManager.windowRolledOver(previousBoundary: nil, current: boundary))
    }

    // MARK: - H9: setup-complete across providers

    func testSetupIsCompleteWithACodexOnlyProfile() {
        // The real Codex-only install: focus sits on an empty "Account 1"
        // while the auto-imported Codex profile holds the only credentials.
        let empty = Profile(id: UUID(), name: "Account 1")
        var codex = Profile(id: UUID(), name: "Codex (a@b.c)")
        codex.codexEmail = "a@b.c"
        codex.codexCredentialsJSON = "{\"tokens\":{\"access_token\":\"x\"}}"

        XCTAssertTrue(AppDelegate.isSetupComplete(
            profiles: [empty, codex],
            hasClaudeCLILogin: false, hasCodexCLILogin: false, hasGrokCLILogin: false))

        // Nothing anywhere: the wizard is still right to open.
        XCTAssertFalse(AppDelegate.isSetupComplete(
            profiles: [empty],
            hasClaudeCLILogin: false, hasCodexCLILogin: false, hasGrokCLILogin: false))

        // A codex CLI login on disk counts even before the one-time import
        // has turned it into a profile.
        XCTAssertTrue(AppDelegate.isSetupComplete(
            profiles: [empty],
            hasClaudeCLILogin: false, hasCodexCLILogin: true, hasGrokCLILogin: false))
    }

    func testNotificationsAreSuppressedUnderXCTest() {
        XCTAssertTrue(NotificationManager.isRunningUnderXCTest, "the suite runs inside the XCTest host")
        NotificationManager.shared.sendAutoSwitchNotification(fromProfile: "Fixture A", toProfile: "Fixture B")
    }
}
