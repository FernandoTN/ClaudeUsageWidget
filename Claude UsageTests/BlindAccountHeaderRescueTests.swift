//
//  BlindAccountHeaderRescueTests.swift
//  Claude UsageTests
//
//  2026-08-13 incident ('Iris' 06:36→06:59, 'Kite' 12:41→13:40): ~30
//  parallel CLI sessions burned the ACTIVE account from a fresh window to a
//  hard 100% session limit, and the widget never switched. Its own
//  `oauth/usage` endpoint refused most reads for exactly that account (HTTP
//  429, `retry-after: 0` — measured live the next morning at 7 refusals in 8
//  attempts), so the gating number never even reached the 25% preflight
//  milestone before the fleet hit the wall.
//
//  The rescue: `/v1/messages` is a DIFFERENT rate-limit bucket — the one the
//  fleet's own requests ride — and its `anthropic-ratelimit-unified-*`
//  response headers ARE the enforcement counters (verified live 2026-08-14:
//  `unified-5h-utilization: 0.86` in the same minute `oauth/usage` was
//  refusing everything). These tests cover the header contract, the merge
//  that keeps per-model weekly data alive, and the narrow gate that keeps the
//  probe from ever opening an idle account's 5-hour window.
//

import XCTest
@testable import Claude_Usage

final class BlindAccountHeaderRescueTests: XCTestCase {

    private let now = Date()

    // MARK: - Header contract

    private func headers(
        sessionUtilization: String? = "0.86",
        sessionReset: String? = nil,
        weeklyUtilization: String? = "0.17",
        weeklyReset: String? = nil,
        sessionStatus: String? = "allowed"
    ) -> [String: String] {
        var result: [String: String] = [:]
        result["anthropic-ratelimit-unified-5h-utilization"] = sessionUtilization
        result["anthropic-ratelimit-unified-5h-reset"] = sessionReset
            ?? String(Int(now.addingTimeInterval(3600).timeIntervalSince1970))
        result["anthropic-ratelimit-unified-7d-utilization"] = weeklyUtilization
        result["anthropic-ratelimit-unified-7d-reset"] = weeklyReset
            ?? String(Int(now.addingTimeInterval(3 * 86400).timeIntervalSince1970))
        result["anthropic-ratelimit-unified-5h-status"] = sessionStatus
        return result.compactMapValues { $0 }
    }

    func testParsesUnifiedUtilizationAsPercentages() {
        // The live shape: 0.0-1.0 fractions, epoch-second resets.
        let usage = ClaudeAPIService.usageFromUnifiedHeaders(headers())
        XCTAssertEqual(usage.sessionPercentage, 86, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyPercentage, 17, accuracy: 0.001)
        XCTAssertEqual(usage.sessionResetTime.timeIntervalSince(now), 3600, accuracy: 2)
    }

    func testExpiredSessionWindowReadsZero() {
        // The window rolled: the utilization on the header belongs to a dead
        // window and must not be shown as live capacity.
        let expired = headers(
            sessionReset: String(Int(now.addingTimeInterval(-60).timeIntervalSince1970))
        )
        XCTAssertEqual(ClaudeAPIService.usageFromUnifiedHeaders(expired).sessionPercentage, 0)
    }

    func testMissingResetHeaderYieldsSentinelNotAFabricatedBoundary() {
        var noReset = headers()
        noReset["anthropic-ratelimit-unified-5h-reset"] = nil
        let usage = ClaudeAPIService.usageFromUnifiedHeaders(noReset)
        XCTAssertEqual(usage.sessionResetTime, ClaudeUsage.unknownResetSentinel)
        // Sentinel is not "expired" — the percentage survives for healing.
        XCTAssertEqual(usage.sessionPercentage, 86, accuracy: 0.001)
    }

    func testSessionWindowRejectionIsOnlyClaimedWhenTheHeaderSaysSo() {
        XCTAssertFalse(ClaudeAPIService.isSessionWindowRejected(headers()))
        XCTAssertTrue(ClaudeAPIService.isSessionWindowRejected(headers(sessionStatus: "rejected")))
        // Absent header ⇒ no claim. Never invent exhaustion.
        XCTAssertFalse(ClaudeAPIService.isSessionWindowRejected(headers(sessionStatus: nil)))
    }

    // MARK: - Merge: headers must not erase per-model weekly data

    private func cachedUsage() -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 24
        usage.sessionResetTime = now.addingTimeInterval(3600)
        usage.weeklyPercentage = 60
        usage.weeklyResetTime = now.addingTimeInterval(3 * 86400)
        usage.fableWeeklyPercentage = 99
        usage.fableWeeklyResetTime = now.addingTimeInterval(3 * 86400)
        usage.opusWeeklyPercentage = 40
        usage.projectedSessionPercentage = 71
        usage.rateLimitedUntil = now.addingTimeInterval(300)
        usage.rateLimitedInferred = true
        usage.lastUpdated = now.addingTimeInterval(-1200)
        return usage
    }

    func testMergeTakesSessionAndWeeklyFromHeadersAndKeepsFable() {
        let merged = cachedUsage().mergingHeaderMeasurement(
            ClaudeAPIService.usageFromUnifiedHeaders(headers())
        )
        XCTAssertEqual(merged.sessionPercentage, 86, accuracy: 0.001)
        XCTAssertEqual(merged.weeklyPercentage, 17, accuracy: 0.001)
        // The headers carry no per-model windows; wiping Fable here would turn
        // a Fable-maxed account into an apparently healthy switch target.
        XCTAssertEqual(merged.fableWeeklyPercentage, 99)
        XCTAssertEqual(merged.opusWeeklyPercentage, 40)
    }

    func testMergeClearsSuspicionAndProjectionLikeAnySuccessfulFetch() {
        let merged = cachedUsage().mergingHeaderMeasurement(
            ClaudeAPIService.usageFromUnifiedHeaders(headers())
        )
        XCTAssertNil(merged.rateLimitedUntil)
        XCTAssertNil(merged.rateLimitedInferred)
        XCTAssertNil(merged.projectedSessionPercentage)
        XCTAssertGreaterThan(merged.lastUpdated, now.addingTimeInterval(-5))
    }

    func testMergeKeepsAServerAffirmedStampFromTheHeaderResponse() {
        // 5h window rejected: the fleet's own requests are being refused.
        var affirmed = ClaudeAPIService.usageFromUnifiedHeaders(headers(sessionStatus: "rejected"))
        affirmed.rateLimitedUntil = now.addingTimeInterval(1800)
        let merged = cachedUsage().mergingHeaderMeasurement(affirmed)
        XCTAssertEqual(merged.rateLimitedUntil, affirmed.rateLimitedUntil)
        XCTAssertNil(merged.rateLimitedInferred, "server-affirmed, not suspected")
        XCTAssertEqual(merged.effectiveSessionPercentage, 100)
    }

    func testMergeKeepsPreviousBoundaryWhenHeadersOmitIt() {
        var noReset = headers()
        noReset["anthropic-ratelimit-unified-5h-reset"] = nil
        noReset["anthropic-ratelimit-unified-7d-reset"] = nil
        let cached = cachedUsage()
        let merged = cached.mergingHeaderMeasurement(
            ClaudeAPIService.usageFromUnifiedHeaders(noReset)
        )
        XCTAssertEqual(merged.sessionResetTime, cached.sessionResetTime)
        XCTAssertEqual(merged.weeklyResetTime, cached.weeklyResetTime)
    }

    // MARK: - Probe gate

    private func openWindow(percentage: Double = 24) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = percentage
        usage.sessionResetTime = now.addingTimeInterval(3600)
        usage.lastUpdated = now.addingTimeInterval(-600)
        return usage
    }

    func testProbesTheActiveAccountWhoseWindowIsAlreadyBurning() {
        XCTAssertTrue(MenuBarManager.shouldProbeMessageHeaders(
            isActiveClaudeAccount: true, cached: openWindow(), lastProbe: nil, now: now
        ))
    }

    func testNeverProbesABackgroundAccount() {
        // Only the provider-active account's number gates the switch, and only
        // it is guaranteed to be the one the fleet is burning.
        XCTAssertFalse(MenuBarManager.shouldProbeMessageHeaders(
            isActiveClaudeAccount: false, cached: openWindow(), lastProbe: nil, now: now
        ))
    }

    func testNeverProbesAnIdleAccountAndOpensItsWindow() {
        // A 5-hour window starts at the first request. Probing an account at
        // 0% (or with no live window) would steal headroom from an account we
        // are holding in reserve as a switch target.
        XCTAssertFalse(MenuBarManager.shouldProbeMessageHeaders(
            isActiveClaudeAccount: true, cached: openWindow(percentage: 0), lastProbe: nil, now: now
        ))
        var rolled = openWindow()
        rolled.sessionResetTime = now.addingTimeInterval(-1)
        XCTAssertFalse(MenuBarManager.shouldProbeMessageHeaders(
            isActiveClaudeAccount: true, cached: rolled, lastProbe: nil, now: now
        ))
        XCTAssertFalse(MenuBarManager.shouldProbeMessageHeaders(
            isActiveClaudeAccount: true, cached: nil, lastProbe: nil, now: now
        ))
    }

    func testNeverProbesAProviderWithoutASessionWindow() {
        var weeklyOnly = openWindow()
        weeklyOnly.hasSessionWindow = false
        XCTAssertFalse(MenuBarManager.shouldProbeMessageHeaders(
            isActiveClaudeAccount: true, cached: weeklyOnly, lastProbe: nil, now: now
        ))
    }

    func testProbeIsRateLimitedToOnePerMinute() {
        XCTAssertFalse(MenuBarManager.shouldProbeMessageHeaders(
            isActiveClaudeAccount: true,
            cached: openWindow(),
            lastProbe: now.addingTimeInterval(-30),
            now: now
        ))
        XCTAssertTrue(MenuBarManager.shouldProbeMessageHeaders(
            isActiveClaudeAccount: true,
            cached: openWindow(),
            lastProbe: now.addingTimeInterval(-MenuBarManager.headerProbeMinInterval - 1),
            now: now
        ))
    }

    // MARK: - Transcript tripwire attribution across providers

    private func event(_ minutesAgo: Double, from: String, to: String) -> SwitchEvent {
        SwitchEvent(
            at: now.addingTimeInterval(-minutesAgo * 60),
            from: from, to: to, trigger: .manual, reason: nil
        )
    }

    func testAttributionSkipsCodexSwitchesBetweenClaudeOnes() {
        // The owner rotates Codex accounts between Claude ones and both land
        // in the same history ring. Treating the Codex switch as "not
        // attributable" dropped the Claude exhaustion event entirely.
        let history = [
            event(30, from: "Iris", to: "Kestrel"),          // event happened before this
            event(20, from: "Kestrel", to: "Osprey"),          // Codex → skip
            event(10, from: "Kite", to: "Harbor")
        ]
        XCTAssertEqual(
            MenuBarManager.rateLimitEventOwnerName(
                history: history,
                eventTime: now.addingTimeInterval(-25 * 60),
                claudeProfileNames: ["Iris", "Kite", "Harbor"]
            ),
            "Kite"
        )
    }

    func testAttributionPicksTheFirstClaudeSwitchAfterTheEvent() {
        let history = [
            event(40, from: "Fjord", to: "Iris"),
            event(20, from: "Iris", to: "Granite"),
            event(5, from: "Granite", to: "Ridge")
        ]
        XCTAssertEqual(
            MenuBarManager.rateLimitEventOwnerName(
                history: history,
                eventTime: now.addingTimeInterval(-21 * 60),
                claudeProfileNames: ["Fjord", "Iris", "Granite", "Ridge"]
            ),
            "Iris",
            "the account that owned the CLI login when its sessions died"
        )
    }

    func testNoSwitchAfterTheEventFallsBackToTheCurrentOwner() {
        let history = [event(40, from: "Fjord", to: "Iris")]
        XCTAssertNil(MenuBarManager.rateLimitEventOwnerName(
            history: history,
            eventTime: now.addingTimeInterval(-60),
            claudeProfileNames: ["Fjord", "Iris"]
        ))
    }

    func testUnsortedHistoryStillPicksTheEarliestQualifyingSwitch() {
        let history = [
            event(5, from: "Granite", to: "Ridge"),
            event(20, from: "Iris", to: "Granite")
        ]
        XCTAssertEqual(
            MenuBarManager.rateLimitEventOwnerName(
                history: history,
                eventTime: now.addingTimeInterval(-25 * 60),
                claudeProfileNames: ["Iris", "Granite", "Ridge"]
            ),
            "Iris"
        )
    }
}
