//
//  ResetsExpiryTests.swift
//  Claude UsageTests
//
//  S2 (round 3): the ⇄ menu's resets row carries the cached detail's expiry
//  and its "as of" time — from the cache only, never a fetch.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class ResetsExpiryTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_757_000_000)

    func testRowTitleAddsTheExpiryOnlyWhenADetailIsCached() {
        XCTAssertEqual(ActiveSelectorMenuModel.resetsRowTitle(count: 2, detail: nil), "Usage limit resets: 2 available")
        let expiry = fetchedAt.addingTimeInterval(3 * 86400)
        let soon = OwnerRow.ResetsDetail(soonestExpiry: expiry, fetchedAt: fetchedAt, availableCount: 2)
        let title = ActiveSelectorMenuModel.resetsRowTitle(count: 2, detail: soon)
        XCTAssertTrue(title.hasPrefix("Usage limit resets: 2 available · expires "), title)
        XCTAssertTrue(title.contains(ActiveSelectorMenuModel.expiryFormatter.string(from: expiry)), title)
        XCTAssertTrue(title.hasSuffix("(as of \(ActiveSelectorMenuModel.timeFormatter.string(from: fetchedAt)))"), title)
        let never = OwnerRow.ResetsDetail(soonestExpiry: nil, fetchedAt: fetchedAt, availableCount: 1)
        XCTAssertEqual(ActiveSelectorMenuModel.resetsRowTitle(count: 1, detail: never),
                       "Usage limit resets: 1 available · never expires (as of \(ActiveSelectorMenuModel.timeFormatter.string(from: fetchedAt)))")
    }

    func testCachedDetailMapsOntoTheOwnerRowSoonestFirst() {
        var codex = Profile(name: "Petrel", codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}", codexEmail: "x@example.com")
        var usage = ClaudeUsage(sessionTokensUsed: 0, sessionLimit: 100, sessionPercentage: 10, sessionResetTime: fetchedAt.addingTimeInterval(3600),
                                weeklyTokensUsed: 0, weeklyLimit: 100, weeklyPercentage: 10, weeklyResetTime: fetchedAt.addingTimeInterval(86400),
                                opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0, sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0,
                                lastUpdated: fetchedAt, userTimezone: .current)
        usage.codexResetCreditsAvailable = 2
        codex.claudeUsage = usage
        let credits = CodexResetCredits(availableCount: 2, credits: [
            CodexResetCredit(id: "later", resetType: nil, status: "available", grantedAt: nil, expiresAt: fetchedAt.addingTimeInterval(9 * 86400), title: nil, description: nil),
            CodexResetCredit(id: "never", resetType: nil, status: "available", grantedAt: nil, expiresAt: nil, title: nil, description: nil),
            CodexResetCredit(id: "soon", resetType: nil, status: "available", grantedAt: nil, expiresAt: fetchedAt.addingTimeInterval(2 * 86400), title: nil, description: nil),
        ], totalEarnedCount: nil, immediateResetPurchaseEligible: nil, fetchedAt: fetchedAt)
        let context = FleetSummaryContext(thresholds: ReadinessThresholds(session: 95, weekly: 99), isLoginDead: { _ in false }, isExcluded: { _ in false },
                                          nextCandidates: [:], preflightVerdicts: [:], preferencesDegraded: false, isSwitching: false, now: fetchedAt)
        let selections = ProviderActiveSelection.build(ProviderActiveSelection.Inputs(
            profiles: [codex], activeIds: [codex.id], focusedId: codex.id, context: context, queue: [],
            cachedResets: [codex.id: credits], needsRelogin: [], autoSwitchEnabled: true))
        let owner = selections.first { $0.provider == .codex }?.owner
        XCTAssertEqual(owner?.resetCreditsAvailable, 2, "the sweep's count stays the count")
        XCTAssertEqual(owner?.resetsDetail?.soonestExpiry, fetchedAt.addingTimeInterval(2 * 86400), "soonest expiry first, never-expiring last")
        XCTAssertEqual(owner?.resetsDetail?.fetchedAt, fetchedAt)
    }
}
