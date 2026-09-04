//
//  TelemetryReport.swift
//  Claude Usage
//
//  The pure aggregation behind the window (spec §2.5): minute-level sums from
//  the ledger → attributed, bucketed, stacked series; KPI totals with the
//  previous period; per-model and per-account rows; coverage and per-provider
//  provenance; the moving average and the outlier verdict. No I/O, no dates
//  from the wall clock — everything comes in through `Input` and `query.now`.
//

import Foundation

/// Token sums that add. `costNanoUSD` is the sum of what could be priced;
/// `unpricedUnits` counts what could not (unknown model, null Grok cost).
nonisolated struct TokenTotals: Sendable, Equatable {
    var units = 0
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cacheWrite1h = 0
    var output = 0
    var reasoning = 0
    var costNanoUSD = 0
    var unpricedUnits = 0
    var sidechainUnits = 0

    var inputClass: Int { input + cacheRead + cacheWrite }
    var isEmpty: Bool { units == 0 }

    mutating func add(_ other: TokenTotals) {
        units += other.units; input += other.input; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
        cacheWrite1h += other.cacheWrite1h; output += other.output; reasoning += other.reasoning
        costNanoUSD += other.costNanoUSD; unpricedUnits += other.unpricedUnits; sidechainUnits += other.sidechainUnits
    }

    func value(for metric: TelemetryMetric) -> Int {
        switch metric {
        case .inputClass, .inputByKind: return inputClass
        case .output: return output
        case .cost: return costNanoUSD
        }
    }
}

/// One row of the ledger's minute aggregation: one (provider, model, source,
/// sidechain) combination within one UTC minute.
nonisolated struct MinuteAggregate: Sendable, Equatable {
    var provider: TelemetryProvider
    var model: String
    var source: String?
    var sidechain: Bool
    var minute: Date
    var totals: TokenTotals
}

nonisolated struct SeriesKey: Sendable, Hashable {
    var id: String
    var label: String
    var provider: TelemetryProvider?

    static let other = SeriesKey(id: "other", label: "Other", provider: nil)
    static let unattributed = SeriesKey(id: "unattributed", label: "Unattributed", provider: nil)
}

nonisolated struct TelemetryBucket: Sendable, Equatable {
    var start: Date
    var end: Date
    var isPartial: Bool
    var series: [SeriesKey: TokenTotals]
    var total: TokenTotals
    /// Ownership changes of the scope's provider(s) inside the bucket (heartbeats excluded).
    var switchCount: Int
}

nonisolated struct TelemetryRow: Sendable, Equatable {
    var key: SeriesKey
    var totals: TokenTotals
    /// Share of the scope's input-class total.
    var share: Double
    var lastActive: Date?
    var attribution: Attribution?
}

nonisolated struct ProviderProvenance: Sendable, Equatable {
    var provider: TelemetryProvider
    var scannedAt: Date?
    var dataThrough: Date?
    var caveats: [String]
    var health: ProviderHealth
}

nonisolated struct CoverageSummary: Sendable, Equatable {
    /// Input-class share attributed to a profile (timeline, by path or sole account).
    var attributedShare: Double
    var unattributedShare: Double
    var oldestDataThrough: Date?
}

nonisolated struct OutlierVerdict: Sendable, Equatable {
    var indices: Set<Int>
    var typicalMax: Int
}

nonisolated struct NativeCount: Sendable, Equatable {
    var label: String
    var value: Int
    var detail: String?
}

nonisolated struct TelemetryReport: Sendable, Equatable {
    var query: TelemetryQuery
    var range: TelemetryQuery.Range
    var buckets: [TelemetryBucket]
    var seriesOrder: [SeriesKey]
    var totals: TokenTotals
    var previousTotals: TokenTotals
    /// Trailing 7-bucket mean of the metric, nil where fewer than 7 complete buckets precede.
    var movingAverage: [Int?]
    var models: [TelemetryRow]
    var accounts: [TelemetryRow]
    var nativeCount: NativeCount?
    var coverage: CoverageSummary
    var provenance: [ProviderProvenance]
    var outliers: OutlierVerdict?
    var priceTable: TokenPriceTable
}

nonisolated enum TelemetryReportBuilder {

    struct Input: Sendable {
        var aggregates: [MinuteAggregate]
        var previousAggregates: [MinuteAggregate]
        var ownership: [OwnershipRecord]
        var roster: [ProfileSummary]
        var health: [ProviderHealth]
        var codexSessions: Int?
        var prices: TokenPriceTable = .shipped
        var firstIndexedAt: Date?
    }

    static let outlierMinimumBuckets = 14
    static let outlierRatio = 20.0
    static let movingAverageWindow = 7
    static let stackedSeriesCap = 6

    static func build(query: TelemetryQuery, input: Input) -> TelemetryReport {
        let range = query.range()
        let resolver = AttributionResolver(ownership: input.ownership, roster: input.roster)
        let stack = query.effectiveStack

        // The ledger query is expected to be range-bounded already; filter again
        // so a caller passing a wider slice cannot inflate the totals.
        let current = attributedRows(input.aggregates, resolver: resolver, prices: input.prices)
            .filter { inScope($0, query.scope) && $0.aggregate.minute >= range.start && $0.aggregate.minute < range.end }
        let previous = attributedRows(input.previousAggregates, resolver: resolver, prices: input.prices)
            .filter { inScope($0, query.scope) && $0.aggregate.minute >= range.previousStart && $0.aggregate.minute < range.previousEnd }
        let names = resolver.roster

        var totals = TokenTotals()
        for row in current { totals.add(row.totals) }
        var previousTotals = TokenTotals()
        for row in previous { previousTotals.add(row.totals) }

        // Series keys, capped: the top N by input-class keep their identity, the tail folds into Other.
        var perKey: [SeriesKey: TokenTotals] = [:]
        for row in current where stack != .kind {
            perKey[seriesKey(for: row, stack: stack, roster: names), default: TokenTotals()].add(row.totals)
        }
        let ranked = perKey.sorted { $0.value.inputClass > $1.value.inputClass }.map(\.key)
        let kept: [SeriesKey]
        if stack == .kind {
            kept = [SeriesKey(id: "uncached", label: "Uncached input", provider: nil),
                    SeriesKey(id: "cacheWrite", label: "Cache writes", provider: nil),
                    SeriesKey(id: "cacheRead", label: "Cache reads", provider: nil)]
        } else if stack == .provider {
            kept = TelemetryProvider.allCases.map(providerKey).filter { perKey[$0] != nil }
        } else if ranked.count > stackedSeriesCap {
            kept = Array(ranked.prefix(stackedSeriesCap)) + [.other]
        } else {
            kept = ranked
        }
        let keptSet = Set(kept)

        // Buckets.
        var buckets = range.buckets.map {
            TelemetryBucket(start: $0.start, end: $0.end, isPartial: $0.isPartial, series: [:], total: TokenTotals(), switchCount: 0)
        }
        for row in current {
            guard let index = TelemetryQuery.bucketIndex(for: row.aggregate.minute, in: range.buckets) else { continue }
            buckets[index].total.add(row.totals)
            if stack == .kind {
                var uncached = TokenTotals(); uncached.input = row.totals.input; uncached.units = row.totals.units
                var writes = TokenTotals(); writes.cacheWrite = row.totals.cacheWrite; writes.cacheWrite1h = row.totals.cacheWrite1h
                var reads = TokenTotals(); reads.cacheRead = row.totals.cacheRead
                buckets[index].series[kept[0], default: TokenTotals()].add(uncached)
                buckets[index].series[kept[1], default: TokenTotals()].add(writes)
                buckets[index].series[kept[2], default: TokenTotals()].add(reads)
            } else {
                var key = seriesKey(for: row, stack: stack, roster: names)
                if !keptSet.contains(key) { key = .other }
                buckets[index].series[key, default: TokenTotals()].add(row.totals)
            }
        }
        let scopeProviders: Set<TelemetryProvider> = query.scope.provider.map { [$0] } ?? Set(TelemetryProvider.allCases)
        for record in input.ownership where record.basis != .heartbeat && scopeProviders.contains(record.provider) {
            if let index = TelemetryQuery.bucketIndex(for: record.at, in: range.buckets) { buckets[index].switchCount += 1 }
        }

        // Moving average over complete buckets only.
        let values = buckets.map { $0.total.value(for: query.metric) }
        var movingAverage: [Int?] = Array(repeating: nil, count: buckets.count)
        for index in buckets.indices where index >= movingAverageWindow - 1 {
            let slice = (index - movingAverageWindow + 1)...index
            guard !slice.contains(where: { buckets[$0].isPartial }) else { continue }
            movingAverage[index] = slice.reduce(0) { $0 + values[$1] } / movingAverageWindow
        }

        // Tables.
        let models = rows(current, groupedBy: { SeriesKey(id: $0.aggregate.model, label: $0.aggregate.model, provider: $0.aggregate.provider) },
                          totalInputClass: totals.inputClass, attribution: { _ in nil })
        var accounts = rows(current, groupedBy: { accountKey(for: $0, roster: resolver.roster) },
                            totalInputClass: totals.inputClass, attribution: { $0.attribution })
        accounts.sort { lhs, rhs in
            let lhsUnattributed = lhs.key.id.hasPrefix("unattributed"), rhsUnattributed = rhs.key.id.hasPrefix("unattributed")
            if lhsUnattributed != rhsUnattributed { return !lhsUnattributed }
            return lhs.totals.inputClass > rhs.totals.inputClass
        }

        // Coverage and provenance.
        let attributedInputClass = current.filter { $0.attribution.profileId != nil }.reduce(0) { $0 + $1.totals.inputClass }
        let coverage = CoverageSummary(
            attributedShare: totals.inputClass > 0 ? Double(attributedInputClass) / Double(totals.inputClass) : 0,
            unattributedShare: totals.inputClass > 0 ? Double(totals.inputClass - attributedInputClass) / Double(totals.inputClass) : 0,
            oldestDataThrough: input.health.compactMap(\.dataThrough).min())
        let provenance = TelemetryProvider.allCases.filter(scopeProviders.contains).map { provider in
            let health = input.health.first { $0.provider == provider } ?? ProviderHealth(provider: provider)
            return ProviderProvenance(provider: provider, scannedAt: health.scannedAt, dataThrough: health.dataThrough,
                                      caveats: caveats(for: provider, firstIndexedAt: input.firstIndexedAt, query: query), health: health)
        }

        return TelemetryReport(
            query: query, range: range, buckets: buckets, seriesOrder: kept, totals: totals, previousTotals: previousTotals,
            movingAverage: movingAverage, models: models, accounts: accounts,
            nativeCount: nativeCount(for: query.scope, totals: totals, codexSessions: input.codexSessions),
            coverage: coverage, provenance: provenance, outliers: outlierVerdict(values: values, partial: buckets.map(\.isPartial)),
            priceTable: input.prices)
    }

    // MARK: - Pieces

    struct AttributedRow: Sendable {
        var aggregate: MinuteAggregate
        var attribution: Attribution
        var totals: TokenTotals
    }

    static func attributedRows(_ aggregates: [MinuteAggregate], resolver: AttributionResolver, prices: TokenPriceTable) -> [AttributedRow] {
        aggregates.map { aggregate in
            var totals = aggregate.totals
            if aggregate.provider != .grok {
                if let cost = prices.costNanoUSD(model: aggregate.model, input: totals.input, cacheRead: totals.cacheRead,
                                                 cacheWrite: totals.cacheWrite, cacheWrite1h: totals.cacheWrite1h, output: totals.output) {
                    totals.costNanoUSD = cost
                    totals.unpricedUnits = 0
                } else {
                    totals.costNanoUSD = 0
                    totals.unpricedUnits = totals.units
                }
            }
            return AttributedRow(aggregate: aggregate,
                                 attribution: resolver.attribute(provider: aggregate.provider, at: aggregate.minute, source: aggregate.source),
                                 totals: totals)
        }
    }

    static func inScope(_ row: AttributedRow, _ scope: TelemetryScope) -> Bool {
        switch scope {
        case .fleet: return true
        case .provider(let p): return row.aggregate.provider == p
        case .account(let id): return row.attribution.profileId == id
        case .unattributed(let p): return row.aggregate.provider == p && row.attribution.profileId == nil
        }
    }

    static func providerKey(_ provider: TelemetryProvider) -> SeriesKey {
        SeriesKey(id: provider.rawValue, label: providerLabel(provider), provider: provider)
    }

    static func providerLabel(_ provider: TelemetryProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    static func seriesKey(for row: AttributedRow, stack: TelemetryStack, roster: [UUID: ProfileSummary]) -> SeriesKey {
        switch stack {
        case .provider: return providerKey(row.aggregate.provider)
        case .model, .kind: return SeriesKey(id: row.aggregate.model, label: row.aggregate.model, provider: row.aggregate.provider)
        case .account: return accountKey(for: row, roster: roster)
        case .originator:
            let source = row.aggregate.source ?? "unknown"
            return SeriesKey(id: "\(row.aggregate.provider.rawValue):\(source)", label: source, provider: row.aggregate.provider)
        }
    }

    static func accountKey(for row: AttributedRow, roster: [UUID: ProfileSummary]) -> SeriesKey {
        switch row.attribution {
        case .profile(let id, _):
            return SeriesKey(id: id.uuidString, label: roster[id]?.name ?? String(id.uuidString.prefix(8)), provider: row.aggregate.provider)
        case .unattributed:
            return SeriesKey(id: "unattributed:\(row.aggregate.provider.rawValue)", label: "Unattributed", provider: row.aggregate.provider)
        }
    }

    static func rows(_ rows: [AttributedRow], groupedBy key: (AttributedRow) -> SeriesKey, totalInputClass: Int,
                     attribution: (AttributedRow) -> Attribution?) -> [TelemetryRow] {
        var grouped: [SeriesKey: (TokenTotals, Date?, Attribution?)] = [:]
        for row in rows {
            let k = key(row)
            var entry = grouped[k] ?? (TokenTotals(), nil, attribution(row))
            entry.0.add(row.totals)
            if entry.1.map({ row.aggregate.minute > $0 }) ?? true { entry.1 = row.aggregate.minute }
            grouped[k] = entry
        }
        return grouped.map { key, entry in
            TelemetryRow(key: key, totals: entry.0,
                         share: totalInputClass > 0 ? Double(entry.0.inputClass) / Double(totalInputClass) : 0,
                         lastActive: entry.1, attribution: entry.2)
        }.sorted { $0.totals.inputClass > $1.totals.inputClass }
    }

    static func nativeCount(for scope: TelemetryScope, totals: TokenTotals, codexSessions: Int?) -> NativeCount? {
        let provider: TelemetryProvider?
        switch scope {
        case .fleet: return nil
        case .provider(let p), .unattributed(let p): provider = p
        case .account: provider = nil
        }
        switch provider {
        case .claude:
            let share = totals.units > 0 ? Int((Double(totals.sidechainUnits) / Double(totals.units) * 100).rounded()) : 0
            return NativeCount(label: "messages", value: totals.units, detail: "\(share) % from subagents")
        case .codex:
            return NativeCount(label: "sessions", value: codexSessions ?? 0, detail: "\(totals.units) counter deltas")
        case .grok:
            return NativeCount(label: "completed turns", value: totals.units, detail: "cancelled turns are not logged")
        case nil:
            return NativeCount(label: "units", value: totals.units, detail: nil)
        }
    }

    static func caveats(for provider: TelemetryProvider, firstIndexedAt: Date?, query: TelemetryQuery) -> [String] {
        switch provider {
        case .claude:
            var list = ["The Claude CLI deletes transcripts after 30 days; the ledger is the archive."]
            if let first = firstIndexedAt {
                let formatter = DateFormatter(); formatter.calendar = query.calendar; formatter.dateStyle = .medium; formatter.timeStyle = .none
                list.append("Nothing before \(formatter.string(from: first.addingTimeInterval(-30 * 86_400))) was still on disk when indexing began.")
            }
            return list
        case .codex:
            return ["Default-home sessions are attributed by time; isolated homes by path."]
        case .grok:
            return ["Completed turns only — cancelled turns are not logged (≈ 5–10 % under the per-call log)."]
        }
    }

    /// Complete buckets only; ≥ 14 of them; largest > 20 × the median of the
    /// non-zero ones. Never fires for a 7-day window by construction.
    static func outlierVerdict(values: [Int], partial: [Bool]) -> OutlierVerdict? {
        let complete = zip(values, partial).filter { !$0.1 }.map(\.0)
        guard complete.count >= outlierMinimumBuckets else { return nil }
        let nonZero = complete.filter { $0 > 0 }.sorted()
        guard !nonZero.isEmpty else { return nil }
        let median = Double(nonZero[nonZero.count / 2])
        let threshold = median * outlierRatio
        let indices = Set(values.indices.filter { !partial[$0] && Double(values[$0]) > threshold })
        guard !indices.isEmpty else { return nil }
        let typical = values.indices.filter { !indices.contains($0) }.map { values[$0] }.max() ?? 0
        return OutlierVerdict(indices: indices, typicalMax: typical)
    }
}
