//
//  TelemetryReportTests.swift
//  Claude UsageTests
//
//  The pure report model (stage 2): window → local buckets (including a DST
//  day), the previous period's elapsed portion, attribution bands from a
//  synthetic ownership log, scope filtering, stacking with the Other fold,
//  the moving average over complete buckets, the outlier verdict, prices by
//  longest prefix, coverage, tables and native counts.
//

import XCTest
@testable import Claude_Usage

final class TelemetryReportTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private let dRir = UUID(), dJormun = UUID(), xFenrir = UUID(), grok = UUID()

    private var roster: [ProfileSummary] {
        [
            ProfileSummary(id: dRir, name: "dRir", provider: .claude, accountStamp: "a"),
            ProfileSummary(id: dJormun, name: "dJormun", provider: .claude, accountStamp: "b"),
            ProfileSummary(id: xFenrir, name: "xFenrir(dev)", provider: .codex, accountStamp: "c", codexHomeSlug: "xfenrir-dev"),
            ProfileSummary(id: grok, name: "GROK", provider: .grok, accountStamp: "g"),
        ]
    }

    private func aggregate(_ provider: TelemetryProvider, _ model: String, at: Date, input: Int = 0, cacheRead: Int = 0,
                           cacheWrite: Int = 0, cacheWrite1h: Int = 0, output: Int = 0, units: Int = 1, source: String? = nil,
                           sidechain: Bool = false, costNano: Int = 0, unpriced: Int = 0) -> MinuteAggregate {
        var totals = TokenTotals()
        totals.units = units; totals.input = input; totals.cacheRead = cacheRead; totals.cacheWrite = cacheWrite
        totals.cacheWrite1h = cacheWrite1h; totals.output = output; totals.reasoning = output / 3
        totals.costNanoUSD = costNano; totals.unpricedUnits = unpriced; totals.sidechainUnits = sidechain ? units : 0
        return MinuteAggregate(provider: provider, model: model, source: source, sidechain: sidechain, minute: at, totals: totals)
    }

    // MARK: - Windows

    func testSevenDayWindowBucketsByLocalDayAcrossTheFallBackDSTChange() {
        // 2026-11-01 is the fall-back day in Los Angeles (25 hours long).
        let now = date(2026, 11, 3, 15, 30)
        let query = TelemetryQuery(window: .days7, now: now, calendar: cal)
        let range = query.range()
        XCTAssertEqual(range.granularity, .day)
        XCTAssertEqual(range.buckets.count, 7)
        XCTAssertEqual(range.buckets.first?.start, date(2026, 10, 28))
        XCTAssertEqual(range.buckets.map(\.isPartial), [false, false, false, false, false, false, true])
        let dst = range.buckets.first { cal.component(.day, from: $0.start) == 1 && cal.component(.month, from: $0.start) == 11 }!
        XCTAssertEqual(dst.end.timeIntervalSince(dst.start), 25 * 3_600, "the DST day is 25 hours, stepped by the calendar")
        XCTAssertEqual(range.previousStart, date(2026, 10, 21))
        XCTAssertEqual(range.previousEnd.timeIntervalSince(range.previousStart), now.timeIntervalSince(range.start),
                       "the previous period is compared over the same elapsed portion")
    }

    func testTodayIsHourlyThroughTheCurrentHourAndAllIndexedIsWeeklyThenMonthly() {
        let now = date(2026, 9, 4, 10, 20)
        let today = TelemetryQuery(window: .today, now: now, calendar: cal).range()
        XCTAssertEqual(today.granularity, .hour)
        XCTAssertEqual(today.buckets.count, 11)
        XCTAssertEqual(today.buckets.last?.isPartial, true)

        let weekly = TelemetryQuery(window: .allIndexed, now: now, calendar: cal, earliestIndexed: date(2026, 7, 14)).range()
        XCTAssertEqual(weekly.granularity, .week)
        XCTAssertLessThanOrEqual(weekly.buckets.first!.start, date(2026, 7, 14))
        XCTAssertGreaterThan(weekly.buckets.count, 7)

        let monthly = TelemetryQuery(window: .allIndexed, now: now, calendar: cal, earliestIndexed: date(2025, 12, 3)).range()
        XCTAssertEqual(monthly.granularity, .month)
        XCTAssertEqual(monthly.buckets.first?.start, date(2025, 12, 1))

        XCTAssertEqual(TelemetryQuery.bucketIndex(for: date(2026, 9, 4, 3, 59), in: today.buckets), 3)
        XCTAssertNil(TelemetryQuery.bucketIndex(for: date(2026, 9, 3, 23, 59), in: today.buckets))
    }

    // MARK: - Prices

    func testPricesMatchByLongestPrefixAndComputeNanoUSD() {
        let table = TokenPriceTable.shipped
        XCTAssertEqual(table.price(forModel: "claude-fable-5-1")?.cacheRead, 0.25)
        XCTAssertEqual(table.price(forModel: "claude-fable-5")?.cacheRead, 1.0)
        XCTAssertEqual(table.price(forModel: "claude-haiku-4-5-20251001")?.output, 5)
        XCTAssertNil(table.price(forModel: "codex-auto-review"))
        XCTAssertNil(table.price(forModel: "unknown"))
        // Opus 5: 2 uncached @ $5, 40,000 cache reads @ $0.50, 3,000 one-hour writes @ $10, 1,730 output @ $25.
        let cost = table.costNanoUSD(model: "claude-opus-5", input: 2, cacheRead: 40_000, cacheWrite: 3_000, cacheWrite1h: 3_000, output: 1_730)
        XCTAssertEqual(cost, 10_000 + 20_000_000 + 30_000_000 + 43_250_000)
        // Codex writes bill as input; a mixed 5 m / 1 h Claude write splits.
        XCTAssertEqual(table.costNanoUSD(model: "gpt-5.6-sol", input: 1_000, cacheRead: 0, cacheWrite: 1_000, cacheWrite1h: 0, output: 0), 8_000_000)
        XCTAssertEqual(table.costNanoUSD(model: "claude-opus-5", input: 0, cacheRead: 0, cacheWrite: 1_000, cacheWrite1h: 400, output: 0),
                       600 * 6_250 + 400 * 10_000)
    }

    // MARK: - Attribution

    func testAttributionBandsFollowTheEvidence() {
        let t0 = date(2026, 9, 1, 8, 0)
        let ownership = [
            OwnershipRecord(at: t0, provider: .claude, profileId: dRir, previousProfileId: nil, accountStamp: "a", name: "dRir", basis: .exactClaim, cause: "activate"),
            OwnershipRecord(at: t0.addingTimeInterval(3_600), provider: .claude, profileId: dRir, previousProfileId: dRir, accountStamp: "a", name: "dRir", basis: .heartbeat, cause: nil),
            OwnershipRecord(at: t0.addingTimeInterval(3 * 3_600), provider: .claude, profileId: dJormun, previousProfileId: dRir, accountStamp: "b", name: "dJormun", basis: .observedAtTick, cause: nil),
            OwnershipRecord(at: t0.addingTimeInterval(6 * 3_600), provider: .claude, profileId: nil, previousProfileId: dJormun, accountStamp: nil, name: nil, basis: .exactClaim, cause: "clear"),
        ]
        let resolver = AttributionResolver(ownership: ownership, roster: roster)
        XCTAssertEqual(resolver.attribute(provider: .claude, at: t0.addingTimeInterval(-60), source: nil), .unattributed(.beforeLog))
        XCTAssertEqual(resolver.attribute(provider: .claude, at: t0.addingTimeInterval(1_800), source: nil), .profile(dRir, basis: .timeline), "inside the exact claim")
        XCTAssertEqual(resolver.attribute(provider: .claude, at: t0.addingTimeInterval(2 * 3_600), source: nil), .unattributed(.gap),
                       "between the last heartbeat of dRir and the first OBSERVATION of dJormun the switch time is unknown")
        XCTAssertEqual(resolver.attribute(provider: .claude, at: t0.addingTimeInterval(4 * 3_600), source: nil), .profile(dJormun, basis: .timeline),
                       "an observed owner followed by an exact claim is bracketed")
        XCTAssertEqual(resolver.attribute(provider: .claude, at: t0.addingTimeInterval(7 * 3_600), source: nil), .unattributed(.noOwner))
        XCTAssertEqual(resolver.attribute(provider: .codex, at: t0, source: "xfenrir-dev"), .profile(xFenrir, basis: .byPath))
        XCTAssertEqual(resolver.attribute(provider: .codex, at: t0, source: ".codex"), .unattributed(.beforeLog), "the default home follows the (empty) Codex log")
        XCTAssertEqual(resolver.attribute(provider: .grok, at: t0.addingTimeInterval(-9_999), source: "Demo"), .profile(grok, basis: .soleAccount))
    }

    func testObservedOwnerWithNothingAfterItIsTrustedForTwoHeartbeats() {
        let t0 = date(2026, 9, 1, 8, 0)
        let ownership = [OwnershipRecord(at: t0, provider: .claude, profileId: dRir, previousProfileId: nil, accountStamp: "a", name: "dRir", basis: .observedAtTick, cause: nil)]
        let resolver = AttributionResolver(ownership: ownership, roster: roster)
        XCTAssertEqual(resolver.attribute(provider: .claude, at: t0.addingTimeInterval(3_600), source: nil), .profile(dRir, basis: .timeline))
        XCTAssertEqual(resolver.attribute(provider: .claude, at: t0.addingTimeInterval(3 * 3_600), source: nil), .unattributed(.gap))
    }

    // MARK: - Report

    private func fixtureInput(now: Date) -> TelemetryReportBuilder.Input {
        let day = { (offset: Int, hour: Int) in self.cal.date(byAdding: .day, value: -offset, to: self.cal.startOfDay(for: now))!.addingTimeInterval(Double(hour) * 3_600) }
        let ownership = [
            OwnershipRecord(at: day(6, 0), provider: .claude, profileId: dRir, previousProfileId: nil, accountStamp: "a", name: "dRir", basis: .exactClaim, cause: "activate"),
            OwnershipRecord(at: day(2, 12), provider: .claude, profileId: dJormun, previousProfileId: dRir, accountStamp: "b", name: "dJormun", basis: .exactClaim, cause: "activate"),
        ]
        var aggregates: [MinuteAggregate] = []
        for offset in (0...6).reversed() {
            aggregates.append(aggregate(.claude, "claude-opus-5", at: day(offset, 9), input: 10, cacheRead: 1_000_000, cacheWrite: 10_000, cacheWrite1h: 10_000, output: 5_000, units: 20))
            aggregates.append(aggregate(.claude, "claude-fable-5-1", at: day(offset, 14), input: 5, cacheRead: 200_000, output: 2_000, units: 4, sidechain: true))
            aggregates.append(aggregate(.codex, "gpt-5.6-sol", at: day(offset, 10), input: 2_000, cacheRead: 50_000, output: 300, units: 3, source: ".codex"))
            aggregates.append(aggregate(.grok, "grok-4.6-build", at: day(offset, 11), input: 400, cacheRead: 6_000, output: 100, units: 1, source: "Demo", costNano: 12_000_000))
        }
        aggregates.append(aggregate(.claude, "claude-opus-5", at: day(7, 9), input: 10, cacheRead: 999, output: 1, units: 1)) // outside the window
        let previous = [aggregate(.claude, "claude-opus-5", at: day(10, 9), input: 10, cacheRead: 500_000, output: 2_000, units: 10)]
        return TelemetryReportBuilder.Input(
            aggregates: aggregates, previousAggregates: previous, ownership: ownership, roster: roster,
            health: [ProviderHealth(provider: .claude, scannedAt: now, dataThrough: day(0, 9)),
                     ProviderHealth(provider: .grok, scannedAt: now, dataThrough: day(0, 11))],
            codexSessions: 7, firstIndexedAt: day(1, 0))
    }

    func testFleetReportStacksByProviderBucketsDailyAndFillsTheTables() {
        let now = date(2026, 9, 4, 16, 0)
        let report = TelemetryReportBuilder.build(query: TelemetryQuery(window: .days7, now: now, calendar: cal), input: fixtureInput(now: now))
        XCTAssertEqual(report.buckets.count, 7)
        XCTAssertEqual(report.seriesOrder.map(\.id), ["claude", "codex", "grok"], "providers keep a fixed order")
        XCTAssertEqual(report.totals.units, 7 * 28)
        XCTAssertEqual(report.totals.inputClass, 7 * (1_010_010 + 200_005 + 52_000 + 6_400))
        XCTAssertEqual(report.buckets[0].series[TelemetryReportBuilder.providerKey(.claude)]?.units, 24)
        XCTAssertEqual(report.buckets.last?.isPartial, true)
        XCTAssertEqual(report.previousTotals.units, 10)
        // Costs: Opus row priced by the table, Grok by its reported nano-USD.
        let opus = report.models.first { $0.key.id == "claude-opus-5" }!
        XCTAssertEqual(opus.totals.costNanoUSD, 7 * (10 * 5_000 + 1_000_000 * 500 + 10_000 * 10_000 + 5_000 * 25_000))
        XCTAssertEqual(report.models.first { $0.key.id == "grok-4.6-build" }?.totals.costNanoUSD, 7 * 12_000_000)
        XCTAssertEqual(report.models.first?.key.id, "claude-opus-5", "largest input-class first")
        XCTAssertEqual(report.models.reduce(0.0) { $0 + $1.share }, 1.0, accuracy: 1e-9)
        // Accounts: dRir owned Claude until two days ago at noon, dJormun after; Grok is the sole account; Codex default home is unattributed.
        let names = report.accounts.map(\.key.label)
        XCTAssertEqual(names.first, "dRir")
        XCTAssertTrue(names.contains("dJormun"))
        XCTAssertTrue(names.contains("GROK"))
        XCTAssertEqual(names.last, "Unattributed", "the unattributed band sorts last")
        XCTAssertEqual(report.accounts.last?.key.provider, .codex)
        XCTAssertEqual(report.accounts.first { $0.key.label == "dJormun" }?.totals.units, 3 * 24 - 20, "days 2 (after noon), 1 and 0; the 09:00 Opus row of day 2 is dRir's")
        XCTAssertGreaterThan(report.coverage.attributedShare, 0.9)
        XCTAssertEqual(report.coverage.attributedShare + report.coverage.unattributedShare, 1.0, accuracy: 1e-9)
        XCTAssertNil(report.nativeCount, "Fleet mixes three nouns; coverage replaces the count")
        XCTAssertEqual(report.provenance.map(\.provider), [.claude, .codex, .grok])
        XCTAssertEqual(report.provenance[2].caveats.first?.contains("Completed turns only"), true)
        XCTAssertEqual(report.buckets.reduce(0) { $0 + $1.switchCount }, 2)
        XCTAssertNil(report.outliers, "7 buckets never trigger the outlier rule")
        XCTAssertTrue(report.movingAverage.allSatisfy { $0 == nil }, "seven buckets with one partial cannot complete a 7-bucket mean")
    }

    func testProviderAndAccountScopesFilterAndStackByModelWithNativeCounts() {
        let now = date(2026, 9, 4, 16, 0)
        let input = fixtureInput(now: now)
        let claude = TelemetryReportBuilder.build(query: TelemetryQuery(scope: .provider(.claude), now: now, calendar: cal), input: input)
        XCTAssertEqual(Set(claude.seriesOrder.map(\.id)), ["claude-opus-5", "claude-fable-5-1"])
        XCTAssertEqual(claude.nativeCount?.label, "messages")
        XCTAssertEqual(claude.nativeCount?.value, 7 * 24)
        XCTAssertEqual(claude.nativeCount?.detail, "17 % from subagents")
        XCTAssertEqual(claude.provenance.map(\.provider), [.claude])

        let codex = TelemetryReportBuilder.build(query: TelemetryQuery(scope: .provider(.codex), now: now, calendar: cal), input: input)
        XCTAssertEqual(codex.nativeCount?.label, "sessions")
        XCTAssertEqual(codex.nativeCount?.value, 7)
        XCTAssertEqual(codex.coverage.attributedShare, 0, "no Codex ownership record and the default home: all unattributed")

        let account = TelemetryReportBuilder.build(query: TelemetryQuery(scope: .account(dRir), now: now, calendar: cal), input: input)
        XCTAssertEqual(account.totals.units, 4 * 24 + 20, "days 6–3 in full plus day 2's morning Opus row")
        XCTAssertEqual(account.accounts.map(\.key.label), ["dRir"])

        let unattributed = TelemetryReportBuilder.build(query: TelemetryQuery(scope: .unattributed(.codex), now: now, calendar: cal), input: input)
        XCTAssertEqual(unattributed.totals.units, 21)

        let byKind = TelemetryReportBuilder.build(query: TelemetryQuery(scope: .provider(.claude), metric: .inputByKind, now: now, calendar: cal), input: input)
        XCTAssertEqual(byKind.seriesOrder.map(\.id), ["uncached", "cacheWrite", "cacheRead"])
        XCTAssertEqual(byKind.buckets[0].series[byKind.seriesOrder[2]]?.cacheRead, 1_200_000)
    }

    func testMovingAverageUsesCompleteBucketsAndOutliersNeedFourteen() {
        let now = date(2026, 9, 30, 12, 0)
        let day = { (offset: Int) in self.cal.date(byAdding: .day, value: -offset, to: self.cal.startOfDay(for: now))!.addingTimeInterval(9 * 3_600) }
        var aggregates: [MinuteAggregate] = []
        for offset in (0...29).reversed() {
            let spike = offset == 10
            aggregates.append(aggregate(.codex, "gpt-5.6-sol", at: day(offset), input: spike ? 35_000_000_000 : 100_000_000, units: 1, source: ".codex"))
        }
        let input = TelemetryReportBuilder.Input(aggregates: aggregates, previousAggregates: [], ownership: [], roster: roster, health: [], codexSessions: 30)
        let report = TelemetryReportBuilder.build(query: TelemetryQuery(scope: .provider(.codex), window: .days30, now: now, calendar: cal), input: input)
        XCTAssertEqual(report.buckets.count, 30)
        XCTAssertNil(report.movingAverage[5])
        XCTAssertEqual(report.movingAverage[6], 100_000_000)
        XCTAssertNil(report.movingAverage[29], "the partial bucket is excluded")
        XCTAssertEqual(report.movingAverage[28], 100_000_000, "a window without the spike")
        XCTAssertEqual(report.movingAverage[19], (35_000_000_000 + 6 * 100_000_000) / 7)
        XCTAssertEqual(report.outliers, OutlierVerdict(indices: [19], typicalMax: 100_000_000))

        let seven = TelemetryReportBuilder.build(query: TelemetryQuery(scope: .provider(.codex), window: .days7, now: now, calendar: cal), input: input)
        XCTAssertNil(seven.outliers)
    }

    func testMoreThanSixModelsFoldIntoOther() {
        let now = date(2026, 9, 4, 16, 0)
        let aggregates = (0..<9).map { i in
            aggregate(.claude, "model-\(i)", at: cal.startOfDay(for: now).addingTimeInterval(3_600), input: 1_000 * (10 - i), units: 1)
        }
        let input = TelemetryReportBuilder.Input(aggregates: aggregates, previousAggregates: [], ownership: [], roster: roster, health: [])
        let report = TelemetryReportBuilder.build(query: TelemetryQuery(scope: .provider(.claude), now: now, calendar: cal), input: input)
        XCTAssertEqual(report.seriesOrder.count, 7)
        XCTAssertEqual(report.seriesOrder.last, .other)
        XCTAssertEqual(report.seriesOrder.first?.id, "model-0")
        XCTAssertEqual(report.buckets.last?.series[.other]?.input, 1_000 * (4 + 3 + 2))
        XCTAssertEqual(report.models.count, 9, "the table keeps every model; only the stack folds")
        XCTAssertEqual(report.totals.unpricedUnits, 9, "unknown models carry tokens but no price")
    }
}
