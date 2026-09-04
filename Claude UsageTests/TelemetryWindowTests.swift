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
        XCTAssertEqual(TelemetryFormatting.delta(current: 5, previous: 0), "new")
        XCTAssertEqual(TelemetryFormatting.delta(current: 0, previous: 0), "—")
        XCTAssertEqual(TelemetryFormatting.delta(current: 38_500_000_000, previous: 2_300_000_000), "from 2.3\u{2009}B", "a percentage against a tiny base is noise")
        XCTAssertEqual(TelemetryFormatting.delta(current: 24_100_000_000_000, previous: 1_000_000_000_000, format: { TelemetryFormatting.usd(nanoUSD: $0) }), "from $1.0\u{2009}k")
        XCTAssertEqual(TelemetryFormatting.meanLabel(.day), "7-day mean")
        XCTAssertEqual(TelemetryFormatting.meanLabel(.hour), "7-hour mean")
        XCTAssertNil(TelemetryFormatting.comparisonLabel(for: .allIndexed))
        XCTAssertEqual(TelemetryFormatting.comparisonLabel(for: .today), "vs yesterday to this hour")
    }

    func testModelColoursNeverBorrowAnotherProvidersHue() {
        XCTAssertEqual(TelemetryPalette.modelColorStep("claude-sonnet-5").provider, .claude, "Sonnet was Grok's green")
        XCTAssertEqual(TelemetryPalette.modelColorStep("claude-opus-5").step, 1.0)
        XCTAssertLessThan(TelemetryPalette.modelColorStep("claude-fable-5-1").step, 1.0)
        XCTAssertEqual(TelemetryPalette.modelColorStep("gpt-5.6-sol").provider, .codex)
        XCTAssertEqual(TelemetryPalette.modelColorStep("codex-auto-review").provider, .codex)
        XCTAssertEqual(TelemetryPalette.modelColorStep("grok-4.5-build").provider, .grok)
        XCTAssertNil(TelemetryPalette.modelColorStep("unknown").provider)
        let claudeSteps = ["claude-opus-5", "claude-fable-5", "claude-sonnet-5", "claude-haiku-4-5"].map { TelemetryPalette.modelColorStep($0).step }
        XCTAssertEqual(claudeSteps, claudeSteps.sorted(by: >), "steps descend by tier so four models stay distinct")
        XCTAssertEqual(Set(claudeSteps).count, 4)
    }

    func testOwnershipSpansForAnAccountAreClaimToClaimAndClippedToTheWindow() {
        let a = UUID(), b = UUID()
        let t = { (h: Double) in Date(timeIntervalSince1970: h * 3_600) }
        let log = [
            OwnershipRecord(at: t(0), provider: .claude, profileId: a, previousProfileId: nil, accountStamp: nil, name: "a", basis: .exactClaim, cause: "activate"),
            OwnershipRecord(at: t(5), provider: .claude, profileId: a, previousProfileId: a, accountStamp: nil, name: "a", basis: .heartbeat, cause: nil),
            OwnershipRecord(at: t(10), provider: .claude, profileId: b, previousProfileId: a, accountStamp: nil, name: "b", basis: .exactClaim, cause: "activate"),
            OwnershipRecord(at: t(20), provider: .claude, profileId: a, previousProfileId: b, accountStamp: nil, name: "a", basis: .observedAtTick, cause: nil),
            OwnershipRecord(at: t(30), provider: .codex, profileId: a, previousProfileId: nil, accountStamp: nil, name: "a", basis: .seededFromRing, cause: "manual"),
        ]
        let spans = TelemetryReportBuilder.ownershipSpans(for: a, ownership: log, from: t(4), to: t(40))
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].start, t(4)); XCTAssertTrue(spans[0].startsBeforeRange); XCTAssertEqual(spans[0].end, t(10)); XCTAssertEqual(spans[0].basis, .exactClaim)
        XCTAssertEqual(spans[1].start, t(20)); XCTAssertNil(spans[1].end, "still the owner at the end of the window"); XCTAssertEqual(spans[1].basis, .observedAtTick)
        XCTAssertEqual(spans[2].provider, .codex); XCTAssertEqual(spans[2].start, t(30)); XCTAssertNil(spans[2].end)
        XCTAssertTrue(TelemetryReportBuilder.ownershipSpans(for: b, ownership: log, from: t(12), to: t(15)).allSatisfy { $0.startsBeforeRange && $0.end == nil })
        XCTAssertTrue(TelemetryReportBuilder.ownershipSpans(for: b, ownership: log, from: t(25), to: t(40)).isEmpty)
    }

    func testChartMathCeilingMeanAndHitTesting() {
        XCTAssertEqual(TelemetryChartMath.niceCeiling(26_500_000_000), 30_000_000_000)
        XCTAssertEqual(TelemetryChartMath.niceCeiling(219_000_000), 250_000_000)
        XCTAssertEqual(TelemetryChartMath.niceCeiling(7), 8)
        XCTAssertEqual(TelemetryChartMath.niceCeiling(0), 1)
        let means = TelemetryChartMath.trailingMean([10, 20, 30, 40, 50, 60, 70, 80], partial: [false, false, false, false, false, false, false, true])
        XCTAssertEqual(means, [nil, nil, nil, nil, nil, nil, 40, nil])
        XCTAssertEqual(TelemetryChartMath.bucketIndex(atX: 0, plotWidth: 700, count: 7), 0)
        XCTAssertEqual(TelemetryChartMath.bucketIndex(atX: 699, plotWidth: 700, count: 7), 6)
        XCTAssertNil(TelemetryChartMath.bucketIndex(atX: 700, plotWidth: 700, count: 7))
        XCTAssertNil(TelemetryChartMath.bucketIndex(atX: -1, plotWidth: 700, count: 7))
    }

    #if DEBUG
    func testBucketsCarryTheirOwnBreakdownForTheClickPopover() {
        let now = TelemetryFrameHarness.Fixture.now
        let fleet = TelemetryFrameHarness.report(.fleet, .days7, input: TelemetryFrameHarness.Fixture.input(now: now), now: now)
        let bucket = fleet.buckets[2]  // four days ago: dRir's, and a default-home Codex day
        XCTAssertEqual(bucket.byModel.values.reduce(0) { $0 + $1.inputClass }, bucket.total.inputClass)
        XCTAssertEqual(bucket.byAccount.values.reduce(0) { $0 + $1.inputClass }, bucket.total.inputClass)
        XCTAssertTrue(bucket.byModel.keys.contains { $0.id == "claude-opus-5" })
        XCTAssertTrue(bucket.byAccount.keys.contains { $0.label == "dRir" }, "days before the switch belong to dRir")
        XCTAssertTrue(bucket.byAccount.keys.contains { $0.id == "unattributed:codex" })
    }
    #endif

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
            XCTAssertTrue(files.contains("telemetry-fleet-7d-hover-dark@2x.png"))
            XCTAssertTrue(files.contains("index.md"))
        }
    }
    #endif
}
