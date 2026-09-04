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
        XCTAssertTrue(CodexResetsFormatting.canRedeem(count: 1, readiness: .exhausted, measurement: own))
        XCTAssertFalse(CodexResetsFormatting.canRedeem(count: 0, readiness: .exhausted, measurement: own), "no grant")
        XCTAssertFalse(CodexResetsFormatting.canRedeem(count: nil, readiness: .exhausted, measurement: own), "unknown is not a grant")
        XCTAssertFalse(CodexResetsFormatting.canRedeem(count: 1, readiness: .ready, measurement: own), "headroom left — a reset would be wasted")
        XCTAssertFalse(CodexResetsFormatting.canRedeem(count: 1, readiness: .exhausted, measurement: cache), "a cached number is not evidence")
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
}
