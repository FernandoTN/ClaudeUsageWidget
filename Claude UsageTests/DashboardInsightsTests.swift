//
//  DashboardInsightsTests.swift
//  Claude UsageTests
//
//  Stage 4b: the Insights block's pure formatting and its frame fixture.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class DashboardInsightsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    func testTimelinePositionSpansTheSevenDayHorizonAndClamps() {
        XCTAssertEqual(InsightsFormatting.timelinePosition(now, now: now), 0)
        XCTAssertEqual(InsightsFormatting.timelinePosition(now.addingTimeInterval(3.5 * 24 * 3600), now: now), 0.5, accuracy: 0.001)
        XCTAssertEqual(InsightsFormatting.timelinePosition(now.addingTimeInterval(30 * 24 * 3600), now: now), 1)
        XCTAssertEqual(InsightsFormatting.timelinePosition(now.addingTimeInterval(-60), now: now), 0)
    }

    func testTimelineLabelNamesTheWindowAndTheHeadroomThatReturns() {
        let weekly = FleetInsights.ResetMarker(id: UUID(), name: "dRir", provider: .claude, window: .weekly, resetAt: now, headroomReturning: 84.4)
        let fable = FleetInsights.ResetMarker(id: UUID(), name: "dRir", provider: .claude, window: .fable, resetAt: now, headroomReturning: 10)
        XCTAssertEqual(InsightsFormatting.timelineLabel(weekly), "dRir W 84 %")
        XCTAssertEqual(InsightsFormatting.timelineLabel(fable), "dRir F 10 %")
    }

    func testBlindSpotTextNamesEveryPieceOfEvidence() {
        let fine = FleetInsights.BlindSpot(id: UUID(), name: "A", provider: .claude, sinceOwnMeasurement: 30, provenance: .ownEndpoint, headerRescuesLastHour: 0, backoff: nil, isBlind: false)
        XCTAssertEqual(InsightsFormatting.blind(fine, now: now), "own measurement 30 s ago")
        let blind = FleetInsights.BlindSpot(id: UUID(), name: "B", provider: .codex, sinceOwnMeasurement: nil, provenance: .cliCache, headerRescuesLastHour: 2,
                                            backoff: FleetInsights.Backoff(until: now.addingTimeInterval(120), streak: 3), isBlind: true)
        XCTAssertEqual(InsightsFormatting.blind(blind, now: now), "never measured through its own endpoint · shown from the CLI cache · 2 header rescues in the last hour · backing off 2 min (streak 3)")
    }

    func testSwitchAndBurnDetails() {
        let legacy = FleetInsights.SwitchRow(at: now.addingTimeInterval(-3600), from: "A", to: "B", trigger: .manual, reason: nil, provider: .claude, isLegacy: true, fromHeadroom: nil)
        XCTAssertEqual(InsightsFormatting.switchDetail(legacy, now: now), "1 h ago · manual · recorded before Viewing was split from Active")
        let auto = FleetInsights.SwitchRow(at: now.addingTimeInterval(-60), from: "A", to: "B", trigger: .auto, reason: "session 96 %", provider: .claude, isLegacy: false, fromHeadroom: 4.4)
        XCTAssertEqual(InsightsFormatting.switchDetail(auto, now: now), "1 m ago · auto-switch · session 96 %", "the recorder's reason says it once")
        let bare = FleetInsights.SwitchRow(at: now.addingTimeInterval(-60), from: "A", to: "B", trigger: .auto, reason: nil, provider: .claude, isLegacy: false, fromHeadroom: 4.4)
        XCTAssertEqual(InsightsFormatting.switchDetail(bare, now: now), "1 m ago · auto-switch · left at 96 % session")
        let rescue = FleetInsights.Incident(at: now.addingTimeInterval(-60), profileId: nil, name: "A", provider: .claude, kind: .headerRescue, detail: "5h 0.86")
        XCTAssertEqual(InsightsFormatting.incident(rescue, now: now), "1 m ago · measured through the Messages headers · 5-hour window 86 %")
        let affirmed = FleetInsights.Incident(at: now.addingTimeInterval(-60), profileId: nil, name: "A", provider: .claude, kind: .affirmedStamp(until: now.addingTimeInterval(2400)), detail: "retry-after 2918 s")
        XCTAssertEqual(InsightsFormatting.incident(affirmed, now: now), "1 m ago · 429 with Retry-After, 40 min left")
        let dead = FleetInsights.WhyNot(id: UUID(), name: "Ai", provider: .claude, status: .blocked(.dead), evidence: "dead login", verdictText: "× login dead 2 h ago", evidenceAge: 7200)
        XCTAssertEqual(InsightsFormatting.whyNot(dead), "login dead 2 h ago", "the row glyph carries the status; the verdict says dead once")
        let flat = FleetInsights.Burn(id: UUID(), name: "A", provider: .claude, ratePerMinute: nil, samples: [], projectedCrossing: nil)
        XCTAssertEqual(InsightsFormatting.burn(flat, now: now), "flat")
        let rising = FleetInsights.Burn(id: UUID(), name: "A", provider: .claude, ratePerMinute: 2.06, samples: [], projectedCrossing: now.addingTimeInterval(8 * 60))
        XCTAssertEqual(InsightsFormatting.burn(rising, now: now), "+2.1 pp/min · crosses the threshold in 8 min")
    }

    func testFixtureCoversEverySection() {
        let fixture = FleetInsights.fixture(now: now)
        XCTAssertEqual(fixture.resetTimeline.count, 5)
        XCTAssertFalse(fixture.blindness.isEmpty)
        XCTAssertFalse(fixture.drift.isEmpty)
        XCTAssertEqual(fixture.switchLog.filter(\.isLegacy).count, 1)
        XCTAssertFalse(fixture.burn.isEmpty)
        XCTAssertEqual(Set(fixture.incidents.map { InsightsFormatting.glyph(for: $0.kind) }).count, 3, "all three incident glyphs appear")
        XCTAssertEqual(fixture.capacity.count, 3)
        XCTAssertEqual(fixture.whyNotOthers.count, 3)
        XCTAssertTrue(fixture.resetTimeline.allSatisfy { InsightsFormatting.timelinePosition($0.resetAt, now: now) < 1 }, "every fixture marker is inside the horizon")
    }
}
