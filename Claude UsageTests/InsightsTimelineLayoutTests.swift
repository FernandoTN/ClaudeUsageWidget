//
//  InsightsTimelineLayoutTests.swift
//  Claude UsageTests
//
//  Owner findings at the real scale (spec §12.10): the reset strip's labels
//  never overlap or spill — they merge, stagger, and past a cap become a list —
//  and the roster census says only what it knows.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class InsightsTimelineLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func marker(_ name: String, hours: Double, pct: Double = 84, window: WindowGauge.Kind = .weekly) -> FleetInsights.ResetMarker {
        FleetInsights.ResetMarker(id: UUID(), name: name, provider: .claude, window: window, resetAt: now.addingTimeInterval(hours * 3600), headroomReturning: pct)
    }

    func testMarkersOnOneSlotMergeIntoOneLabel() {
        let result = InsightsTimelineLayout.layout(markers: [marker("dRir", hours: 9, pct: 100), marker("Commits", hours: 9.2, pct: 100)], width: 372, now: now)
        XCTAssertEqual(result.placements.count, 1)
        XCTAssertEqual(result.placements.first?.text, "dRir · Commits W 100 %")
        XCTAssertEqual(result.rows, 1)
        XCTAssertFalse(result.overflow)
        let mixed = InsightsTimelineLayout.mergedLabel([marker("A", hours: 9, pct: 84), marker("B", hours: 9, pct: 10, window: .fable)])
        XCTAssertEqual(mixed, "A W 84 % · B F 10 %", "different suffixes keep their own")
    }

    func testCrowdedLabelsStaggerIntoRowsAndTheHeightGrows() {
        // 25 h apart at 372 pt = 55 pt between 69-pt labels: neighbours collide, alternates fit.
        let markers = (0..<4).map { marker("Account\($0)", hours: Double($0) * 25) }
        let result = InsightsTimelineLayout.layout(markers: markers, width: 372, now: now)
        XCTAssertFalse(result.overflow)
        XCTAssertGreaterThan(result.rows, 1, "neighbours cannot share a row at this density")
        XCTAssertLessThanOrEqual(result.rows, 3)
        XCTAssertEqual(result.height, InsightsTimelineLayout.axisHeight + CGFloat(result.rows) * InsightsTimelineLayout.rowHeight + 4)
        // No two labels on the same row overlap.
        for row in 0..<result.rows {
            let onRow = result.placements.filter { $0.row == row }.sorted { $0.x < $1.x }
            for (l, r) in zip(onRow, onRow.dropFirst()) {
                let lRight = l.x + CGFloat(l.text.count) * InsightsTimelineLayout.charWidth / 2
                let rLeft = r.x - CGFloat(r.text.count) * InsightsTimelineLayout.charWidth / 2
                XCTAssertLessThanOrEqual(lRight + InsightsTimelineLayout.gap, rLeft + 1, "\(l.text) overlaps \(r.text)")
            }
        }
    }

    func testTooManyLabelsFallBackToDotsAndAList() {
        let markers = (0..<20).map { marker("Account\($0)", hours: Double($0) * 4) }
        let result = InsightsTimelineLayout.layout(markers: markers, width: 372, now: now)
        XCTAssertTrue(result.overflow)
        XCTAssertEqual(result.rows, 0, "dots only; the labels move to the list")
        XCTAssertEqual(result.height, InsightsTimelineLayout.axisHeight + 4)
    }

    func testRosterSubtitleSaysOnlyWhatItKnows() {
        var counts = FleetCounts.Provider(provider: .claude, profiles: 18, distinctAccounts: 16, identifiedAccounts: 1, byReadiness: [:], excludedByToggle: 0, freePlan: 0,
                                          stale: 0, duplicateProfiles: 3, duplicateGroups: [], needsRelogin: 0, queued: 0, onBar: 0, pinned: 0, loginLive: 0, capacityRemaining: 0)
        XCTAssertEqual(AccountsRosterModel.Section(provider: .claude, counts: counts, rows: []).subtitle, "18 profiles · 1 identified")
        counts.identifiedAccounts = 0; counts.distinctAccounts = 18; counts.duplicateProfiles = 0
        XCTAssertEqual(AccountsRosterModel.Section(provider: .claude, counts: counts, rows: []).subtitle, "18 profiles")
        counts.identifiedAccounts = 17; counts.distinctAccounts = 17
        XCTAssertEqual(AccountsRosterModel.Section(provider: .claude, counts: counts, rows: []).subtitle, "18 profiles · 17 accounts", "all identified, one duplicate")
    }
}
