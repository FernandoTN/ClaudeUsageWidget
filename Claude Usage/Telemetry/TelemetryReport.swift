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
    /// Rate-limit stops the scope's provider(s) — or the account — hit inside
    /// the bucket. Shown only when the overlay is on; always in the tooltip.
    var rateLimitCount: Int = 0
    /// The same stops per series when the stack can place them (provider,
    /// account); empty for model / kind / originator stacks, where a stop
    /// belongs to the provider, not a series.
    var rateLimitsBySeries: [SeriesKey: Int] = [:]
    /// The bucket's own breakdown, whatever the chart stacks by — for the
    /// click-a-bucket popover ("what was 16 July?").
    var byModel: [SeriesKey: TokenTotals] = [:]
    var byAccount: [SeriesKey: TokenTotals] = [:]
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

/// An interval in which the scoped account held a provider's CLI login,
/// clipped to the report's range (the account scope's card, spec §3.2 frame 4).
nonisolated struct OwnershipSpan: Sendable, Equatable {
    var provider: TelemetryProvider
    var start: Date
    /// nil = still the owner at the end of the range.
    var end: Date?
    var basis: OwnershipRecord.Basis
    /// True when `start` was clipped to the range (the span began earlier).
    var startsBeforeRange: Bool
    /// "from Cedar · activate" — who held the login before and why it moved.
    var openedBy: String? = nil
    /// "to Cedar · auto-switch" — who took it and why; nil while open.
    var closedBy: String? = nil
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
    /// Account scope only: when this account held its provider's login.
    var ownershipSpans: [OwnershipSpan] = []
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
        /// Rate-limit / quota-rejected markers inside the window (stage 4a overlay).
        var markers: [TelemetryMarker] = []
        /// Isolated-home Codex rollouts still to be re-attributed (stage 4d).
        var codexReindexPending = 0
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
            buckets[index].byModel[SeriesKey(id: row.aggregate.model, label: row.aggregate.model, provider: row.aggregate.provider),
                                   default: TokenTotals()].add(row.totals)
            buckets[index].byAccount[accountKey(for: row, roster: names), default: TokenTotals()].add(row.totals)
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
        for marker in input.markers where scopeProviders.contains(marker.provider) {
            let attribution = resolver.attribute(provider: marker.provider, at: marker.at, source: nil)
            guard markerInScope(marker, scope: query.scope, attribution: attribution),
                  let index = TelemetryQuery.bucketIndex(for: marker.at, in: range.buckets) else { continue }
            buckets[index].rateLimitCount += 1
            let key: SeriesKey?
            switch stack {
            case .provider: key = providerKey(marker.provider)
            case .account: key = accountKey(for: attribution, provider: marker.provider, roster: names)
            case .model, .kind, .originator, .sidechain: key = nil
            }
            if let key { buckets[index].rateLimitsBySeries[keptSet.contains(key) ? key : .other, default: 0] += 1 }
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
                                      caveats: caveats(for: provider, firstIndexedAt: input.firstIndexedAt, query: query,
                                                       codexReindexPending: input.codexReindexPending), health: health)
        }

        var spans: [OwnershipSpan] = []
        if case .account(let id) = query.scope {
            spans = ownershipSpans(for: id, ownership: input.ownership, from: range.start, to: range.end, names: names.mapValues(\.name))
        }

        return TelemetryReport(
            query: query, range: range, buckets: buckets, seriesOrder: kept, totals: totals, previousTotals: previousTotals,
            movingAverage: movingAverage, models: models, accounts: accounts,
            nativeCount: nativeCount(for: query.scope, totals: totals, codexSessions: input.codexSessions,
                                     accountProvider: { id in input.roster.first { $0.id == id }?.provider }),
            coverage: coverage, provenance: provenance, outliers: outlierVerdict(values: values, partial: buckets.map(\.isPartial)),
            priceTable: input.prices, ownershipSpans: spans)
    }

    /// The intervals in `[from, to)` during which `profileId` was the recorded
    /// owner of a provider's login: a span opens at a record naming it and
    /// closes at the next record naming someone else (heartbeats and repeat
    /// sightings of the same owner keep it open). A nil `end` means the
    /// profile still held the login when the window ended — "→ now".
    static func ownershipSpans(for profileId: UUID, ownership: [OwnershipRecord], from: Date, to: Date,
                               names: [UUID: String] = [:]) -> [OwnershipSpan] {
        // "took over from Alpha (activate)" / "first claim (activate)" /
        // "handed to Beta (auto-switch)": the switch in words, cause in brackets.
        func edge(_ verb: String, _ id: UUID?, _ name: String?, _ cause: String?, orElse: String) -> String {
            let who = id.flatMap { names[$0] } ?? name
            let head = who.map { "\(verb) \($0)" } ?? orElse
            return cause.map { "\(head) (\($0))" } ?? head
        }
        var spans: [OwnershipSpan] = []
        for provider in TelemetryProvider.allCases {
            let records = ownership.filter { $0.provider == provider }.sorted { ($0.at, $0.seq ?? 0) < ($1.at, $1.seq ?? 0) }
            var open: (start: Date, basis: OwnershipRecord.Basis, openedBy: String?)?
            for record in records {
                if record.profileId == profileId {
                    if open == nil {
                        open = (record.at, record.basis, edge("took over from", record.previousProfileId, nil, record.cause, orElse: "first claim"))
                    }
                } else if let current = open {
                    spans.append(OwnershipSpan(provider: provider, start: current.start, end: record.at, basis: current.basis, startsBeforeRange: false,
                                               openedBy: current.openedBy,
                                               closedBy: edge("handed to", record.profileId, record.name, record.cause, orElse: "released")))
                    open = nil
                }
            }
            if let current = open {
                spans.append(OwnershipSpan(provider: provider, start: current.start, end: nil, basis: current.basis, startsBeforeRange: false,
                                           openedBy: current.openedBy))
            }
        }
        return spans.compactMap { span in
            let end = span.end ?? to
            guard end > from, span.start < to else { return nil }
            var clipped = span
            if span.start < from { clipped.start = from; clipped.startsBeforeRange = true }
            // Past the window's end is "→ now": every window ends at now.
            if let spanEnd = span.end, spanEnd > to { clipped.end = nil }
            return clipped
        }.sorted { $0.start < $1.start }
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

    /// A marker carries a session, never an account: in the account and
    /// unattributed scopes it is attributed by time exactly like a unit.
    static func markerInScope(_ marker: TelemetryMarker, scope: TelemetryScope, attribution: Attribution) -> Bool {
        switch scope {
        case .fleet: return true
        case .provider(let p): return marker.provider == p
        case .account(let id): return attribution.profileId == id
        case .unattributed(let p): return marker.provider == p && attribution.profileId == nil
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
            // Codex: "juniper-dev/exec" reads "exec (juniper-dev)" — two homes with
            // the same originator would otherwise be two series with one label.
            var label = source
            if row.aggregate.provider == .codex, source.contains("/"), let home = AttributionResolver.codexHomeSlug(in: source) {
                label = "\(AttributionResolver.codexOriginator(in: source)) (\(home))"
            }
            return SeriesKey(id: "\(row.aggregate.provider.rawValue):\(source)", label: label, provider: row.aggregate.provider)
        case .sidechain:
            return row.aggregate.sidechain
                ? SeriesKey(id: "\(row.aggregate.provider.rawValue):subagents", label: "Subagents", provider: row.aggregate.provider)
                : SeriesKey(id: "\(row.aggregate.provider.rawValue):main", label: "Main", provider: row.aggregate.provider)
        }
    }

    static func accountKey(for row: AttributedRow, roster: [UUID: ProfileSummary]) -> SeriesKey {
        accountKey(for: row.attribution, provider: row.aggregate.provider, roster: roster)
    }

    static func accountKey(for attribution: Attribution, provider: TelemetryProvider, roster: [UUID: ProfileSummary]) -> SeriesKey {
        switch attribution {
        case .profile(let id, _):
            return SeriesKey(id: id.uuidString, label: roster[id]?.name ?? String(id.uuidString.prefix(8)), provider: provider)
        case .unattributed:
            return SeriesKey(id: "unattributed:\(provider.rawValue)", label: "Unattributed", provider: provider)
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

    static func nativeCount(for scope: TelemetryScope, totals: TokenTotals, codexSessions: Int?,
                            accountProvider: (UUID) -> TelemetryProvider? = { _ in nil }) -> NativeCount? {
        let provider: TelemetryProvider?
        switch scope {
        case .fleet: return nil
        case .provider(let p), .unattributed(let p): provider = p
        // An account's tile speaks its provider's unit; "units" only when the
        // roster no longer knows the profile.
        case .account(let id): provider = accountProvider(id)
        }
        switch provider {
        case .claude:
            let share = totals.units > 0 ? Int((Double(totals.sidechainUnits) / Double(totals.units) * 100).rounded()) : 0
            return NativeCount(label: "messages", value: totals.units, detail: "\(share) % from subagents")
        case .codex:
            return NativeCount(label: "sessions", value: codexSessions ?? 0, detail: "\(TelemetryFormatting.compact(totals.units)) usage records")
        case .grok:
            return NativeCount(label: "completed turns", value: totals.units, detail: "cancelled turns are not logged")
        case nil:
            return NativeCount(label: "units", value: totals.units, detail: nil)
        }
    }

    static func caveats(for provider: TelemetryProvider, firstIndexedAt: Date?, query: TelemetryQuery,
                        codexReindexPending: Int = 0) -> [String] {
        switch provider {
        case .claude:
            var list = ["The Claude CLI deletes transcripts after 30 days; the ledger is the archive."]
            if let first = firstIndexedAt {
                let formatter = DateFormatter(); formatter.calendar = query.calendar; formatter.dateStyle = .medium; formatter.timeStyle = .none
                list.append("Nothing before \(formatter.string(from: first.addingTimeInterval(-30 * 86_400))) was still on disk when indexing began.")
            }
            return list
        case .codex:
            var list = ["Default-home sessions are attributed by time; isolated homes by path."]
            if codexReindexPending > 0 {
                list.append("Re-attributing isolated-home Codex sessions · \(codexReindexPending) file\(codexReindexPending == 1 ? "" : "s") to go — the Unattributed share moves until this finishes.")
            }
            return list
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
