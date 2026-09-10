//
//  CodexResetsCardTests.swift
//  Claude UsageTests
//
//  Stage 4.1 (docs/specs/ux-revamp.md §4.1): the usage-limit-resets surface
//  never claims zero from a null, and Redeem is offered only at a measured limit.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class CodexResetsCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    func testCountLineNeverClaimsZeroFromNull() {
        XCTAssertEqual(CodexResetsFormatting.countLine(nil), "Usage limit resets: none or unknown")
        XCTAssertEqual(CodexResetsFormatting.countLine(2), "Usage limit resets: 2 available")
    }

    func testRedeemNeedsAGrantAndAMeasuredLimit() {
        let own = UsageMeasurement(provenance: .ownEndpoint, measuredAt: now)
        let cache = UsageMeasurement(provenance: .cliCache, measuredAt: now)
        XCTAssertTrue(CodexResetsFormatting.canRedeem(count: 1, readiness: .weeklyHit, measurement: own))
        XCTAssertFalse(CodexResetsFormatting.canRedeem(count: 0, readiness: .weeklyHit, measurement: own), "no grant")
        XCTAssertFalse(CodexResetsFormatting.canRedeem(count: nil, readiness: .weeklyHit, measurement: own), "unknown is not a grant")
        XCTAssertFalse(CodexResetsFormatting.canRedeem(count: 1, readiness: .ready, measurement: own), "headroom left — a reset would be wasted")
        XCTAssertFalse(CodexResetsFormatting.canRedeem(count: 1, readiness: .weeklyHit, measurement: cache), "a cached number is not evidence")
        XCTAssertEqual(CodexResetsFormatting.redeemHelp(count: 1, readiness: .ready, measurement: own), "The account still has headroom; a reset now would be wasted.")
    }

    func testCreditAndOutcomeCopy() {
        let never = CodexResetCredit(id: "c1", resetType: nil, status: "available", grantedAt: nil, expiresAt: nil, title: nil, description: nil)
        let soon = CodexResetCredit(id: "c2", resetType: nil, status: "available", grantedAt: nil, expiresAt: now.addingTimeInterval(3 * 24 * 3600), title: "Welcome reset", description: nil)
        XCTAssertEqual(CodexResetsFormatting.creditLine(never, now: now), "Usage limit reset · never expires")
        XCTAssertEqual(CodexResetsFormatting.creditLine(soon, now: now), "Welcome reset · expires in 3 d")
        XCTAssertEqual(CodexResetsFormatting.outcomeText(.reset(windowsReset: 2)), "Reset applied · 2 windows cleared")
        XCTAssertEqual(CodexResetsFormatting.outcomeText(.alreadyRedeemed), "That reset was already used.")
        XCTAssertEqual(CodexResetsFormatting.errorText(.resetCreditsUnavailable(retryAfter: 30)), "Unknown right now — the resets endpoint is rate-limited; try again in a few minutes.")
    }

    // MARK: - Identity (owner report 2026-09-09: every Codex account read "3 available")

    private func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func credit(_ id: String, expires: String) -> CodexResetCredit {
        CodexResetCredit(id: id, resetType: "codex_rate_limits", status: "available", grantedAt: nil, expiresAt: iso(expires), title: nil, description: nil)
    }
    private func details(_ count: Int, _ credits: [CodexResetCredit]) -> CodexResetCredits {
        CodexResetCredits(availableCount: count, credits: credits, totalEarnedCount: nil, immediateResetPurchaseEligible: nil, fetchedAt: now)
    }
    /// Measured live on 2026-09-09 (UTC expiries): xFho holds 3 grants, xFenrir 2.
    private var xFhoDetails: CodexResetCredits {
        details(3, [credit("a", expires: "2026-09-21T00:07:00Z"), credit("b", expires: "2026-10-04T02:16:00Z"), credit("c", expires: "2026-10-05T04:19:00Z")])
    }
    private var xFenrirDetails: CodexResetCredits {
        details(2, [credit("d", expires: "2026-10-04T06:05:00Z"), credit("e", expires: "2026-10-05T04:19:00Z")])
    }

    func testResolutionDiscardsDetailsFetchedForAnotherAccount() {
        let xFho = UUID(), xFenrir = UUID()
        let fetched = (profileId: xFho, credits: xFhoDetails)
        // Viewing xFenrir after one Details click on xFho: its own sweep count, no borrowed expiry lines.
        let fenrir = CodexResetsCard.Resolution.resolve(viewed: xFenrir, fetched: fetched, cached: nil, sweepCount: 2)
        XCTAssertEqual(fenrir.count, 2, "the report: xFenrir read xFho's 3")
        XCTAssertNil(fenrir.details, "xFho's three expiry lines must not caption xFenrir")
        // The account the details were fetched for keeps them, soonest expiry first.
        let fho = CodexResetsCard.Resolution.resolve(viewed: xFho, fetched: fetched, cached: nil, sweepCount: 3)
        XCTAssertEqual(fho.count, 3)
        XCTAssertEqual(fho.details?.availableCreditsByExpiry.map(\.id), ["a", "b", "c"])
    }

    func testResolutionRanksOwnFetchOverOwnCacheOverSweepCount() {
        let xFho = UUID(), xFenrir = UUID()
        // xFenrir's own earlier answer, held by the service cache, beats both the sweep and a foreign fetch.
        let cached = CodexResetsCard.Resolution.resolve(viewed: xFenrir, fetched: (xFho, xFhoDetails), cached: xFenrirDetails, sweepCount: 2)
        XCTAssertEqual(cached.count, 2)
        XCTAssertEqual(cached.details?.availableCreditsByExpiry.map(\.expiresAt), [iso("2026-10-04T06:05:00Z"), iso("2026-10-05T04:19:00Z")])
        // A fresh fetch for the viewed account outranks its cache (one grant just spent).
        let spent = CodexResetsCard.Resolution.resolve(viewed: xFenrir, fetched: (xFenrir, details(1, [credit("e", expires: "2026-10-05T04:19:00Z")])),
                                                       cached: xFenrirDetails, sweepCount: 2)
        XCTAssertEqual(spent.count, 1)
        XCTAssertEqual(spent.details?.credits.count, 1)
        // Only the sweep: the count stands alone. Nothing at all: unknown, never zero.
        XCTAssertEqual(CodexResetsCard.Resolution.resolve(viewed: xFenrir, fetched: nil, cached: nil, sweepCount: 2), .init(count: 2, details: nil))
        XCTAssertEqual(CodexResetsCard.Resolution.resolve(viewed: xFenrir, fetched: nil, cached: nil, sweepCount: nil), .init(count: nil, details: nil))
    }

    func testUsableNowLinePrintsAStatedZeroAndHidesTheUnknown() {
        XCTAssertEqual(CodexResetsFormatting.usableNowLine(0), "Usable now: 0", "xFme live: grants in hand, none applicable while idle")
        XCTAssertEqual(CodexResetsFormatting.usableNowLine(2), "Usable now: 2")
        XCTAssertNil(CodexResetsFormatting.usableNowLine(nil), "unknown prints nothing, never a zero")
    }
}
