//
//  MenuBarOrderingTests.swift
//  Claude UsageTests
//
//  Tests for StatusBarUIManager.multiProfileCreationOrder — the weekly-reset
//  ranking that decides menu bar item order. Creation order maps right-to-left
//  on screen: index 0 is the RIGHTMOST item. Claude profiles are created first
//  (right side), Codex profiles last (far left). A ranking flip tears down and
//  rebuilds the whole status-item group (visible flicker), so stability under
//  API jitter is load-bearing behavior.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class MenuBarOrderingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A Claude-side profile (claude.ai session credentials).
    private func claudeProfile(_ name: String, weeklyReset: Date?, selected: Bool = true) -> Profile {
        var usage: ClaudeUsage?
        if let weeklyReset {
            var u = ClaudeUsage.empty
            u.weeklyResetTime = weeklyReset
            usage = u
        }
        return Profile(
            name: name,
            claudeSessionKey: "sk-ant-sid01-test",
            organizationId: "org-test",
            claudeUsage: usage,
            isSelectedForDisplay: selected
        )
    }

    /// A Codex-only profile (isCodexOnlyProfile == true).
    private func codexProfile(_ name: String, weeklyReset: Date?, selected: Bool = true) -> Profile {
        var usage: ClaudeUsage?
        if let weeklyReset {
            var u = ClaudeUsage.empty
            u.weeklyResetTime = weeklyReset
            usage = u
        }
        return Profile(
            name: name,
            codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
            codexEmail: "codex@example.com",
            claudeUsage: usage,
            isSelectedForDisplay: selected
        )
    }

    private func order(_ profiles: [Profile]) -> [String] {
        StatusBarUIManager.multiProfileCreationOrder(for: profiles, now: now).map(\.name)
    }

    // MARK: group split

    func testClaudeGroupIsCreatedBeforeCodexGroup() {
        // Creation order right-to-left: Claude items first (right), Codex last (far left).
        let profiles = [
            codexProfile("X-Codex", weeklyReset: now.addingTimeInterval(3600)),
            claudeProfile("A-Claude", weeklyReset: now.addingTimeInterval(7200))
        ]
        XCTAssertEqual(order(profiles), ["A-Claude", "X-Codex"])
    }

    // MARK: within-group ranking

    func testSoonestWeeklyResetRanksFirstWithinGroup() {
        let profiles = [
            claudeProfile("Late", weeklyReset: now.addingTimeInterval(5 * 24 * 3600)),
            claudeProfile("Soon", weeklyReset: now.addingTimeInterval(1 * 24 * 3600)),
            claudeProfile("Mid", weeklyReset: now.addingTimeInterval(3 * 24 * 3600))
        ]
        XCTAssertEqual(order(profiles), ["Soon", "Mid", "Late"])
    }

    func testProfileWithoutCachedUsageSortsLastInItsGroup() {
        let profiles = [
            claudeProfile("Unknown", weeklyReset: nil),
            claudeProfile("Known", weeklyReset: now.addingTimeInterval(24 * 3600))
        ]
        XCTAssertEqual(order(profiles), ["Known", "Unknown"])
    }

    func testUnselectedProfilesAreExcluded() {
        let profiles = [
            claudeProfile("Shown", weeklyReset: now.addingTimeInterval(3600)),
            claudeProfile("Hidden", weeklyReset: now.addingTimeInterval(60), selected: false)
        ]
        XCTAssertEqual(order(profiles), ["Shown"])
    }

    // MARK: jitter quantization

    func testSubMinuteJitterDoesNotFlipTheOrder() {
        // The usage API reports the same weekly boundary with ±1s jitter across
        // fetches. Two accounts sharing a boundary must keep a stable order
        // (name tiebreak) no matter which side of the second boundary each
        // fetch lands on — every flip is a full menu bar rebuild.
        let boundary = now.addingTimeInterval(24 * 3600)

        let sweep1 = [
            claudeProfile("Beta", weeklyReset: boundary.addingTimeInterval(-0.2)),
            claudeProfile("Alpha", weeklyReset: boundary.addingTimeInterval(0.1))
        ]
        let sweep2 = [
            claudeProfile("Beta", weeklyReset: boundary.addingTimeInterval(0.3)),
            claudeProfile("Alpha", weeklyReset: boundary.addingTimeInterval(-0.4))
        ]
        XCTAssertEqual(order(sweep1), ["Alpha", "Beta"])
        XCTAssertEqual(order(sweep2), ["Alpha", "Beta"])
    }

    func testJitterAcrossAMinuteBoundaryStillQuantizesTogether() {
        // 23:59:59.8 vs 00:00:00.1 — different minutes, but rounding to the
        // NEAREST minute maps both onto the same key.
        let minuteBoundary = Date(timeIntervalSinceReferenceDate:
            (now.addingTimeInterval(24 * 3600).timeIntervalSinceReferenceDate / 60).rounded() * 60)

        let sweep1 = [
            claudeProfile("Beta", weeklyReset: minuteBoundary.addingTimeInterval(-0.5)),
            claudeProfile("Alpha", weeklyReset: minuteBoundary.addingTimeInterval(0.5))
        ]
        XCTAssertEqual(order(sweep1), ["Alpha", "Beta"])
    }

    func testGenuinelyDifferentResetsAreNotMerged() {
        let profiles = [
            claudeProfile("Alpha", weeklyReset: now.addingTimeInterval(24 * 3600 + 300)),
            claudeProfile("Beta", weeklyReset: now.addingTimeInterval(24 * 3600))
        ]
        // 5 minutes apart: real difference, Beta (sooner) first despite name order.
        XCTAssertEqual(order(profiles), ["Beta", "Alpha"])
    }

    func testEqualUnknownResetsUseNameTiebreak() {
        let profiles = [
            claudeProfile("Zeta", weeklyReset: nil),
            claudeProfile("Alpha", weeklyReset: nil)
        ]
        XCTAssertEqual(order(profiles), ["Alpha", "Zeta"])
    }

    private func grokProfile(_ name: String, weeklyReset: Date?, selected: Bool = true) -> Profile {
        var usage: ClaudeUsage?
        if let weeklyReset {
            var u = ClaudeUsage.empty
            u.weeklyResetTime = weeklyReset
            usage = u
        }
        return Profile(
            name: name,
            grokCredentialsJSON: "{\"https://auth.x.ai::client\":{\"key\":\"jwt\"}}",
            grokEmail: "grok@example.com",
            claudeUsage: usage,
            isSelectedForDisplay: selected
        )
    }

    func testFullTwoProviderLayout() {
        let profiles = [
            codexProfile("Codex-Late", weeklyReset: now.addingTimeInterval(6 * 24 * 3600)),
            claudeProfile("Claude-Late", weeklyReset: now.addingTimeInterval(5 * 24 * 3600)),
            codexProfile("Codex-Soon", weeklyReset: now.addingTimeInterval(1 * 24 * 3600)),
            claudeProfile("Claude-Soon", weeklyReset: now.addingTimeInterval(2 * 24 * 3600))
        ]
        // Rightmost → leftmost: Claude group (soonest first), then Codex group.
        XCTAssertEqual(order(profiles), ["Claude-Soon", "Claude-Late", "Codex-Soon", "Codex-Late"])
    }

    func testThreeProviderLayoutPutsGrokLeftmost() {
        let profiles = [
            grokProfile("Grok", weeklyReset: now.addingTimeInterval(3 * 24 * 3600)),
            codexProfile("Codex", weeklyReset: now.addingTimeInterval(1 * 24 * 3600)),
            claudeProfile("Claude", weeklyReset: now.addingTimeInterval(2 * 24 * 3600))
        ]
        // Creation order maps right-to-left: Claude rightmost, Codex next,
        // Grok created last = leftmost on screen.
        XCTAssertEqual(order(profiles), ["Claude", "Codex", "Grok"])
    }

    // MARK: - Stranded-tile layout check

    func testDescendingContiguousXPositionsMatchCreationOrder() {
        // Creation order maps right-to-left: strictly descending, tightly
        // packed x (~27pt tiles) is healthy.
        XCTAssertFalse(StatusBarUIManager.layoutDivergesFromCreationOrder([900, 873, 846, 819]))
        XCTAssertFalse(StatusBarUIManager.layoutDivergesFromCreationOrder([100]))
        XCTAssertFalse(StatusBarUIManager.layoutDivergesFromCreationOrder([]))
    }

    func testStrandedTileIsDetected() {
        // The incident shape: the LAST-created tile (expected leftmost) sitting
        // at the far right of the bar.
        XCTAssertTrue(StatusBarUIManager.layoutDivergesFromCreationOrder([900, 873, 846, 1650]))
        // Equal positions (overlapping/unresolved windows) also count as broken
        // rather than silently accepted — the caller filters unmeasurable cases.
        XCTAssertTrue(StatusBarUIManager.layoutDivergesFromCreationOrder([900, 900]))
    }

    func testSplitGroupIsDetected() {
        // Order intact but the group torn in two (other apps' icons in the
        // middle — a rejected pin's fallback placement): a >90pt adjacent gap.
        XCTAssertTrue(StatusBarUIManager.layoutDivergesFromCreationOrder([1509, 1482, 1321, 1294]))
    }

}
