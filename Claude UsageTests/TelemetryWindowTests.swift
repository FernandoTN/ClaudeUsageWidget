//
//  TelemetryWindowTests.swift
//  Claude UsageTests
//
//  Stage 3a: the window's pure pieces — number formatting, the sidebar built
//  from a Fleet report, the scope decoded from `.telemetryWindowRequested`,
//  the harness fixture — and the frames, rendered when
//  `TEST_RUNNER_CUW_RENDER_FRAMES=<dir>` is set:
//
//      TEST_RUNNER_CUW_RENDER_FRAMES=/tmp/cuw-frames xcodebuild test \
//          -scheme "Claude Usage" -destination 'platform=macOS' \
//          -only-testing:"Claude UsageTests/TelemetryWindowTests"
//

import XCTest
@testable import Claude_Usage

@MainActor
final class TelemetryWindowTests: XCTestCase {

    func testCompactNumbersUSDPercentAndDeltas() {
        XCTAssertEqual(TelemetryFormatting.compact(842), "842")
        XCTAssertEqual(TelemetryFormatting.compact(1_234), "1.23\u{2009}k")
        XCTAssertEqual(TelemetryFormatting.compact(219_021), "219\u{2009}k")
        XCTAssertEqual(TelemetryFormatting.compact(119_884_200), "120\u{2009}M")
        XCTAssertEqual(TelemetryFormatting.compact(78_312_000_000), "78.3\u{2009}B")
        XCTAssertEqual(TelemetryFormatting.usd(nanoUSD: 93_260_000), "$0.09")
        XCTAssertEqual(TelemetryFormatting.usd(nanoUSD: 214_000_000_000), "$214")
        XCTAssertEqual(TelemetryFormatting.usd(nanoUSD: 58_700_000_000_000), "$58.7\u{2009}k")
        XCTAssertEqual(TelemetryFormatting.percent(0.968), "97\u{2009}%")
        XCTAssertEqual(TelemetryFormatting.percent(0.0031), "0.3\u{2009}%")
        XCTAssertEqual(TelemetryFormatting.delta(current: 148, previous: 100), "▲ 48\u{2009}%")
        XCTAssertEqual(TelemetryFormatting.delta(current: 96, previous: 100), "▼ 4\u{2009}%")
        XCTAssertEqual(TelemetryFormatting.delta(current: 5, previous: 0), "—")
    }

    func testScopeFromNotificationDecodesProfileProviderAndFleet() {
        let id = UUID()
        XCTAssertEqual(TelemetryWindowModel.scope(from: Notification(name: .telemetryWindowRequested, object: id, userInfo: ["provider": Profile.ProviderKind.claude])), .account(id))
        XCTAssertEqual(TelemetryWindowModel.scope(from: Notification(name: .telemetryWindowRequested, object: nil, userInfo: ["provider": Profile.ProviderKind.codex])), .provider(.codex))
        XCTAssertEqual(TelemetryWindowModel.scope(from: Notification(name: .telemetryWindowRequested, object: nil, userInfo: ["provider": "grok"])), .provider(.grok))
        XCTAssertEqual(TelemetryWindowModel.scope(from: Notification(name: .telemetryWindowRequested, object: nil, userInfo: nil)), .fleet)
    }

    #if DEBUG
    func testSidebarFollowsTheFleetReportAndMarksOwners() {
        let now = TelemetryFrameHarness.Fixture.now
        let input = TelemetryFrameHarness.Fixture.input(now: now)
        let fleet = TelemetryFrameHarness.report(.fleet, .days7, input: input, now: now)
        let sections = TelemetryWindowModel.sidebar(fleet: fleet, profiles: TelemetryFrameHarness.Fixture.sidebarProfiles)
        XCTAssertEqual(sections.map(\.id), ["fleet", "claude", "codex", "grok"])
        XCTAssertEqual(sections[0].rows.first?.total, fleet.totals.inputClass)
        let claude = sections[1]
        XCTAssertEqual(claude.count, 3)
        XCTAssertEqual(claude.rows.first?.scope, .provider(.claude))
        let names = claude.rows.dropFirst().map(\.title)
        XCTAssertEqual(names.first, "dRir", "busiest account first")
        XCTAssertTrue(names.contains("dLeo"))
        XCTAssertEqual(claude.rows.first { $0.title == "dLeo" }?.total, nil, "no activity → no number, never a zero with confidence")
        XCTAssertEqual(claude.rows.first { $0.title == "dJormun" }?.isOwner, true)
        let codex = sections[2]
        XCTAssertEqual(codex.rows.last?.scope, .unattributed(.codex), "the default home before the Codex log is unattributed")
        XCTAssertGreaterThan(codex.rows.last?.total ?? 0, 0)
        XCTAssertEqual(codex.rows.first { $0.title == "xFenrir(dev)" }?.total.map { $0 > 0 }, true, "isolated home attributes by path")
        XCTAssertEqual(sections[3].rows.count, 2, "Grok: the provider row and its sole account; no Unattributed row")
    }

    func testFixtureReportsCoverEveryStateAndRenderWhenRequested() throws {
        let now = TelemetryFrameHarness.Fixture.now
        let input = TelemetryFrameHarness.Fixture.input(now: now)
        let fleet = TelemetryFrameHarness.report(.fleet, .days7, input: input, now: now)
        XCTAssertEqual(fleet.buckets.count, 7)
        XCTAssertEqual(fleet.seriesOrder.map(\.id), ["claude", "codex", "grok"])
        XCTAssertGreaterThan(fleet.coverage.attributedShare, 0.9)
        XCTAssertLessThan(fleet.coverage.attributedShare, 1.0, "the Codex default home stays unattributed")
        XCTAssertGreaterThan(fleet.totals.costNanoUSD, 10_000_000_000_000, "five figures, as the consult predicted")
        let outlierInput = TelemetryFrameHarness.Fixture.inputWithOutlier(now: now)
        let fleetOutlier = TelemetryFrameHarness.report(.fleet, .days30, input: outlierInput, now: now)
        XCTAssertNil(fleetOutlier.outliers, "Claude dominates the fleet total; a 35 B Codex day is not 20× the fleet median")
        let codexOutlier = TelemetryFrameHarness.report(.provider(.codex), .days30, input: outlierInput, now: now)
        XCTAssertNotNil(codexOutlier.outliers, "in the Codex scope the same day is clipped")
        let empty = TelemetryFrameHarness.report(.account(TelemetryFrameHarness.Fixture.dLeo), .days7, input: input, now: now)
        XCTAssertTrue(empty.totals.isEmpty)

        if let dir = ProcessInfo.processInfo.environment["CUW_RENDER_FRAMES"], !dir.isEmpty {
            TelemetryFrameHarness.renderAll(to: URL(fileURLWithPath: dir))
            let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            XCTAssertTrue(files.contains("telemetry-fleet-7d-dark@2x.png"), files.joined(separator: ", "))
            XCTAssertTrue(files.contains("telemetry-indexing-light@2x.png"))
            XCTAssertTrue(files.contains("index.md"))
        }
    }
    #endif
}
