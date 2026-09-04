//
//  TelemetryExportTests.swift
//  Claude UsageTests
//
//  Stage 4a: the CSV export's provenance columns, the rate-limit overlay's
//  per-bucket counts by scope, the switch detail on ownership spans, and the
//  dense-axis label rule (T26).
//

import XCTest
@testable import Claude_Usage

final class TelemetryExportTests: XCTestCase {
    private let a = UUID(), b = UUID(), x = UUID()
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 16, minute: 3))! }
    private func at(daysAgo: Int, hour: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: -daysAgo, to: now)!)!
    }

    private func totals(input: Int = 100, cacheRead: Int = 1_000, output: Int = 50, units: Int = 3) -> TokenTotals {
        var t = TokenTotals()
        t.input = input; t.cacheRead = cacheRead; t.output = output; t.units = units
        return t
    }

    private func input(markers: [TelemetryMarker] = []) -> TelemetryReportBuilder.Input {
        let roster = [ProfileSummary(id: a, name: "Alpha, Inc", provider: .claude, accountStamp: "a"),
                      ProfileSummary(id: b, name: "Beta", provider: .claude, accountStamp: "b"),
                      ProfileSummary(id: x, name: "xFenrir(dev)", provider: .codex, accountStamp: "x")]
        let ownership = [
            OwnershipRecord(at: at(daysAgo: 6, hour: 0), provider: .claude, profileId: a, previousProfileId: nil, accountStamp: "a", name: "Alpha, Inc", basis: .exactClaim, cause: "activate"),
            OwnershipRecord(at: at(daysAgo: 2, hour: 12), provider: .claude, profileId: b, previousProfileId: a, accountStamp: "b", name: "Beta", basis: .exactClaim, cause: "auto-switch: session 95 %"),
        ]
        var grokCost = totals(input: 10, cacheRead: 0, output: 5, units: 1)
        grokCost.costNanoUSD = 1_250_000_000
        let aggregates = [
            MinuteAggregate(provider: .claude, model: "claude-opus-5", source: "cli", sidechain: false, minute: at(daysAgo: 3, hour: 10), totals: totals()),
            MinuteAggregate(provider: .claude, model: "claude-opus-5", source: "cli", sidechain: true, minute: at(daysAgo: 3, hour: 10), totals: totals(units: 1)),
            MinuteAggregate(provider: .claude, model: "mystery-model", source: "cli", sidechain: false, minute: at(daysAgo: 1, hour: 9), totals: totals()),
            MinuteAggregate(provider: .codex, model: "gpt-5.6-sol", source: ".codex", sidechain: false, minute: at(daysAgo: 1, hour: 9), totals: totals()),
            MinuteAggregate(provider: .grok, model: "grok-4.6-build", source: "ClaudeUsageWidget", sidechain: false, minute: at(daysAgo: 1, hour: 9), totals: grokCost),
        ]
        return TelemetryReportBuilder.Input(aggregates: aggregates, previousAggregates: [], ownership: ownership, roster: roster,
                                            health: [], codexSessions: nil, markers: markers)
    }

    private func query(_ scope: TelemetryScope = .fleet) -> TelemetryQuery {
        TelemetryQuery(scope: scope, window: .days7, metric: .inputClass, now: now, calendar: calendar)
    }

    func testExportRowsCarryProvenanceAndNeverReadAsQuota() {
        let csv = TelemetryExport.csv(query: query(), input: input(), scopeTitle: "Fleet")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("# Claude Usage — token consumption read from local CLI logs. Not quota, not billed."))
        XCTAssertEqual(lines[4], TelemetryExport.columns.joined(separator: ","))
        let rows = lines.dropFirst(5)
        XCTAssertEqual(rows.count, 5, "one row per bucket × provider × model × account × source × sidechain")
        // Alpha held the Claude login three days ago: timeline attribution, the comma-bearing name quoted.
        XCTAssertTrue(rows.contains { $0.contains("claude,claude-opus-5,\"Alpha, Inc\",timeline,cli,false,3,") }, "\(rows)")
        XCTAssertTrue(rows.contains { $0.contains("claude,claude-opus-5,\"Alpha, Inc\",timeline,cli,true,1,") })
        // Beta took it two days ago; the unpriced model has no cost and no basis.
        XCTAssertTrue(rows.contains { $0.contains("claude,mystery-model,Beta,timeline,cli,false,") && $0.hasSuffix(",,") })
        // No Codex ownership record at all → before the log, not a guess.
        XCTAssertTrue(rows.contains { $0.contains("codex,gpt-5.6-sol,,unattributed:before_log,.codex,") && $0.hasSuffix(",list_price") })
        // Grok: sole account, reported cost.
        XCTAssertTrue(rows.contains { $0.contains("grok,grok-4.6-build,,unattributed:before_log,ClaudeUsageWidget,") || $0.contains(",sole_account,") })
        XCTAssertTrue(rows.contains { $0.hasSuffix(",1.2500,reported") })
        XCTAssertEqual(TelemetryExport.field("plain"), "plain")
        XCTAssertEqual(TelemetryExport.field("say \"hi\", now"), "\"say \"\"hi\"\", now\"")
        XCTAssertEqual(TelemetryExport.suggestedFileName(scopeTitle: "Unattributed · Codex", window: .days7, now: now, calendar: calendar),
                       "token-usage-unattributed-codex-7-days-2026-09-04.csv")
    }

    func testExportScopesLikeTheReport() {
        let alpha = TelemetryExport.rows(query: query(.account(a)), input: input())
        XCTAssertEqual(alpha.count, 2)
        XCTAssertTrue(alpha.allSatisfy { $0.account == "Alpha, Inc" && $0.attribution == "timeline" })
        let codex = TelemetryExport.rows(query: query(.unattributed(.codex)), input: input())
        XCTAssertEqual(codex.map(\.model), ["gpt-5.6-sol"])
    }

    func testRateLimitMarkersCountPerBucketByScope() {
        let markers = [
            TelemetryMarker(markerId: "1", provider: .claude, kind: .rateLimit, at: at(daysAgo: 3, hour: 11), session: "s", detail: nil),
            TelemetryMarker(markerId: "2", provider: .claude, kind: .rateLimit, at: at(daysAgo: 3, hour: 15), session: "s", detail: nil),
            TelemetryMarker(markerId: "3", provider: .claude, kind: .quotaRejected, at: at(daysAgo: 1, hour: 9), session: "s", detail: nil),
            TelemetryMarker(markerId: "4", provider: .codex, kind: .rateLimit, at: at(daysAgo: 1, hour: 9), session: "s", detail: nil),
        ]
        func counts(_ scope: TelemetryScope) -> [Int] {
            TelemetryReportBuilder.build(query: query(scope), input: input(markers: markers)).buckets.map(\.rateLimitCount)
        }
        XCTAssertEqual(counts(.fleet).reduce(0, +), 4)
        XCTAssertEqual(counts(.provider(.claude)).reduce(0, +), 3)
        XCTAssertEqual(counts(.provider(.claude)).max(), 2, "two stops in one day bucket")
        XCTAssertEqual(counts(.account(a)).reduce(0, +), 2, "Alpha held the login three days ago, not yesterday")
        XCTAssertEqual(counts(.account(b)).reduce(0, +), 1)
        XCTAssertEqual(counts(.unattributed(.codex)).reduce(0, +), 1, "no Codex ownership record: the stop is unattributed too")
        XCTAssertEqual(counts(.unattributed(.claude)).reduce(0, +), 0)
    }

    func testOwnershipSpansNameTheSwitchOnBothEdges() {
        let report = TelemetryReportBuilder.build(query: query(.account(a)), input: input())
        XCTAssertEqual(report.ownershipSpans.count, 1)
        let span = report.ownershipSpans[0]
        XCTAssertEqual(span.openedBy, "first claim (activate)", "no previous owner")
        XCTAssertEqual(span.closedBy, "handed to Beta (auto-switch: session 95 %)")
        let beta = TelemetryReportBuilder.build(query: query(.account(b)), input: input()).ownershipSpans
        XCTAssertEqual(beta.first?.openedBy, "took over from Alpha, Inc (auto-switch: session 95 %)")
        XCTAssertNil(beta.first?.closedBy)
    }

    func testSplitRowsCarryOnlyTheirOwnStops() {
        let markers = [
            TelemetryMarker(markerId: "1", provider: .claude, kind: .rateLimit, at: at(daysAgo: 3, hour: 11), session: "s", detail: nil),
            TelemetryMarker(markerId: "2", provider: .codex, kind: .rateLimit, at: at(daysAgo: 3, hour: 12), session: "s", detail: nil),
        ]
        let fleet = TelemetryReportBuilder.build(query: query(.fleet), input: input(markers: markers))
        let bucket = fleet.buckets.first { $0.rateLimitCount > 0 }!
        XCTAssertEqual(bucket.rateLimitCount, 2)
        XCTAssertEqual(bucket.rateLimitsBySeries[TelemetryReportBuilder.providerKey(.claude)], 1)
        XCTAssertEqual(bucket.rateLimitsBySeries[TelemetryReportBuilder.providerKey(.codex)], 1)
        // A model stack cannot place a stop on a model: no per-series counts.
        let claude = TelemetryReportBuilder.build(query: query(.provider(.claude)), input: input(markers: markers))
        XCTAssertEqual(claude.buckets.map(\.rateLimitCount).reduce(0, +), 1)
        XCTAssertTrue(claude.buckets.allSatisfy { $0.rateLimitsBySeries.isEmpty })
    }

    func testDenseAxisKeepsEveryDateBesideAMonthBoundary() {
        // 7-day axis: every bucket labelled, "31" and "2" stay either side of "Sep 1" (T26).
        XCTAssertTrue(TelemetryChartMath.isRegularLabel(2, every: 1, boundaries: [3]))
        XCTAssertTrue(TelemetryChartMath.isRegularLabel(4, every: 1, boundaries: [3]))
        // 30-day axis: a regular label right beside the boundary yields to it.
        XCTAssertFalse(TelemetryChartMath.isRegularLabel(27, every: 3, boundaries: [26]))
        XCTAssertTrue(TelemetryChartMath.isRegularLabel(24, every: 3, boundaries: [26]))
        XCTAssertFalse(TelemetryChartMath.isRegularLabel(25, every: 3, boundaries: []), "not a multiple of the pitch")
    }
}
