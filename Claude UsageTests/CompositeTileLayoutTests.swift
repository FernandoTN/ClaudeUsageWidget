//
//  CompositeTileLayoutTests.swift
//  Claude UsageTests
//
//  Tests for the composite provider-group tiles: ONE NSStatusItem per provider
//  hosting all of that provider's tiles side-by-side in a single image
//  (2026-07-29 storm fix — 42 scene windows → 9).
//
//  Two things these tests pin down, both of which shipped WRONG and were caught
//  only by review:
//
//  1. ORIENTATION. `multiProfileCreationOrder` ranks the soonest weekly reset
//     FIRST because legacy per-profile status items are created right-to-left
//     (first created = RIGHTMOST on screen). A composite image is drawn with x
//     INCREASING, so painting that array in order puts the soonest reset at the
//     LEFT edge — inverting the owner's "the rightmost account is the one to
//     burn first" layout. The existing ordering tests only assert the rank
//     array, which is identical either way, so they could not catch it.
//  2. SEGMENT COVERAGE. Clicks are routed by x-offset inside the group button,
//     so the segments must be contiguous and cover the whole button: a gap
//     would be a dead click, an overlap an ambiguous one.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class CompositeTileLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

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

    // MARK: - Orientation: soonest weekly reset must be RIGHTMOST

    func testPaintOrderIsTheReverseOfRankOrder() {
        XCTAssertEqual(StatusBarUIManager.compositePaintOrder([1, 2, 3]), [3, 2, 1])
    }

    func testPaintOrderOfEmptyAndSingleGroup() {
        XCTAssertEqual(StatusBarUIManager.compositePaintOrder([Int]()), [])
        XCTAssertEqual(StatusBarUIManager.compositePaintOrder([7]), [7])
    }

    /// The load-bearing assertion: within a provider group, the account whose
    /// weekly limit resets SOONEST is painted LAST — i.e. it sits at the right
    /// edge of the composite, which is the right edge of the group on screen.
    func testSoonestWeeklyResetIsPaintedRightmost() {
        let soon = claudeProfile("Soon", weeklyReset: now.addingTimeInterval(3600))
        let mid = claudeProfile("Mid", weeklyReset: now.addingTimeInterval(2 * 86400))
        let late = claudeProfile("Late", weeklyReset: now.addingTimeInterval(6 * 86400))

        let members = StatusBarUIManager.onScreenGroupMembers(
            for: [mid, late, soon],
            provider: .claude,
            now: now
        )

        XCTAssertEqual(members.map(\.name), ["Late", "Mid", "Soon"],
                       "left-to-right on screen must end with the soonest reset")
        XCTAssertEqual(members.last?.name, "Soon")
    }

    /// The bug as it shipped: paint the rank order directly and the soonest
    /// reset lands leftmost. Documents the inversion so a future refactor that
    /// drops the reverse fails here instead of on the owner's menu bar.
    func testUnreversedRankOrderWouldPutSoonestResetLeftmost() {
        let soon = claudeProfile("Soon", weeklyReset: now.addingTimeInterval(3600))
        let late = claudeProfile("Late", weeklyReset: now.addingTimeInterval(6 * 86400))

        let rank = StatusBarUIManager.multiProfileCreationOrder(for: [late, soon], now: now)
        XCTAssertEqual(rank.first?.name, "Soon", "rank order is soonest-first (right-to-left)")

        let painted = StatusBarUIManager.onScreenGroupMembers(
            for: [late, soon], provider: .claude, now: now
        )
        XCTAssertNotEqual(rank.map(\.name), painted.map(\.name),
                          "paint order must NOT equal rank order for a multi-account group")
    }

    func testOnScreenGroupMembersIsScopedToOneProvider() {
        let claude = claudeProfile("CLA", weeklyReset: now.addingTimeInterval(3600))
        let codexA = codexProfile("CXA", weeklyReset: now.addingTimeInterval(3600))
        let codexB = codexProfile("CXB", weeklyReset: now.addingTimeInterval(5 * 86400))
        let all = [claude, codexA, codexB]

        XCTAssertEqual(
            StatusBarUIManager.onScreenGroupMembers(for: all, provider: .claude, now: now).map(\.name),
            ["CLA"]
        )
        XCTAssertEqual(
            StatusBarUIManager.onScreenGroupMembers(for: all, provider: .codex, now: now).map(\.name),
            ["CXB", "CXA"],
            "codex group: soonest reset (CXA) rightmost"
        )
        XCTAssertTrue(
            StatusBarUIManager.onScreenGroupMembers(for: all, provider: .grok, now: now).isEmpty
        )
    }

    func testOnScreenGroupMembersExcludesUnselectedProfiles() {
        let shown = claudeProfile("Shown", weeklyReset: now.addingTimeInterval(3600))
        let hidden = claudeProfile("Hidden", weeklyReset: now.addingTimeInterval(7200), selected: false)

        XCTAssertEqual(
            StatusBarUIManager.onScreenGroupMembers(for: [shown, hidden], provider: .claude, now: now)
                .map(\.name),
            ["Shown"]
        )
    }

    // MARK: - Segment geometry

    private func layout(_ widths: [CGFloat]) -> (totalWidth: CGFloat, origins: [CGFloat], ranges: [Range<CGFloat>]) {
        StatusBarUIManager.compositeLayout(tileWidths: widths)
    }

    func testTotalWidthIsTilesPlusGapsPlusPadding() {
        // 3 tiles of 20pt, 3pt spacing, 1pt padding either side.
        let expected: CGFloat = 60 + 6 + 2
        let l = layout([20, 20, 20])
        XCTAssertEqual(l.totalWidth, expected, accuracy: 0.001)
    }

    func testOriginsAdvanceByWidthPlusSpacing() {
        let expected: [CGFloat] = [1, 24, 53]
        let l = layout([20, 26, 20])
        XCTAssertEqual(l.origins, expected)
    }

    func testSegmentsAreContiguousAndCoverTheWholeButton() {
        let l = layout([20, 26, 18, 24])
        XCTAssertEqual(l.ranges.count, 4)
        XCTAssertEqual(l.ranges.first?.lowerBound, 0, "first segment must start at the left edge")
        XCTAssertEqual(l.ranges.last?.upperBound, l.totalWidth,
                       "last segment must end at the right edge")
        for i in 1..<l.ranges.count {
            XCTAssertEqual(l.ranges[i].lowerBound, l.ranges[i - 1].upperBound, accuracy: 0.001,
                           "no gap or overlap between segment \(i - 1) and \(i)")
        }
    }

    func testEveryXInsideTheButtonResolvesToExactlyOneSegment() {
        let l = layout([20, 26, 18])
        var x: CGFloat = 0
        while x < l.totalWidth {
            let hits = l.ranges.filter { $0.contains(x) }
            XCTAssertEqual(hits.count, 1, "x=\(x) resolved to \(hits.count) segments")
            x += 0.5
        }
    }

    func testEachTileOwnsHalfOfTheGapOnEitherSide() {
        let l = layout([20, 20])
        // Boundary sits mid-gap: 1 + 20 + 1.5 = 22.5
        XCTAssertEqual(l.ranges[0].upperBound, 22.5, accuracy: 0.001)
        XCTAssertEqual(l.ranges[1].lowerBound, 22.5, accuracy: 0.001)
    }

    func testSingleTileSegmentSpansTheWholeButton() {
        let l = layout([24])
        XCTAssertEqual(l.totalWidth, 26, accuracy: 0.001)
        XCTAssertEqual(l.ranges.count, 1)
        XCTAssertEqual(l.ranges[0].lowerBound, 0)
        XCTAssertEqual(l.ranges[0].upperBound, 26, accuracy: 0.001)
    }

    func testEmptyGroupHasNoGeometry() {
        let l = layout([])
        XCTAssertEqual(l.totalWidth, 0)
        XCTAssertTrue(l.origins.isEmpty)
        XCTAssertTrue(l.ranges.isEmpty)
    }

    /// Tiles are not all the same width (a 3-char label is wider than a 1-char
    /// one, and `.percentage` tiles size to their digits), so the geometry must
    /// not assume a uniform stride.
    func testMixedWidthTilesKeepSegmentsAlignedToTheirTiles() {
        let widths: [CGFloat] = [12, 40, 24]
        let l = layout(widths)
        for (i, origin) in l.origins.enumerated() {
            let mid = origin + widths[i] / 2
            XCTAssertTrue(l.ranges[i].contains(mid),
                          "the midpoint of tile \(i) must fall in its own segment")
        }
    }
}
