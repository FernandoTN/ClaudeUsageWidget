//
//  TelemetryQuery.swift
//  Claude Usage
//
//  What the window asks the ledger (spec §2.5): a scope (Fleet, a provider,
//  an account, a provider's unattributed band), a time window, a metric and
//  a stacking dimension. Windows are resolved into LOCAL-calendar buckets at
//  query time from UTC events — never persisted per day, so a time-zone change
//  simply re-buckets. Steps use the calendar (DST days are 23 or 25 hours).
//

import Foundation

nonisolated enum TelemetryWindow: String, Codable, Sendable, CaseIterable {
    case today, days7, days30, allIndexed

    var title: String {
        switch self {
        case .today: return "Today"
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .allIndexed: return "All indexed"
        }
    }
}

nonisolated enum BucketGranularity: String, Sendable, Equatable {
    case hour, day, week, month

    var calendarComponent: Calendar.Component {
        switch self {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}

nonisolated enum TelemetryScope: Sendable, Equatable, Hashable {
    case fleet
    case provider(TelemetryProvider)
    case account(UUID)
    case unattributed(TelemetryProvider)

    var provider: TelemetryProvider? {
        switch self {
        case .fleet, .account: return nil
        case .provider(let p), .unattributed(let p): return p
        }
    }
}

nonisolated enum TelemetryMetric: String, Sendable, CaseIterable {
    /// Uncached input + cache writes + cache reads.
    case inputClass
    /// The same total, stacked by kind (uncached / writes / reads).
    case inputByKind
    case output
    /// API list-price equivalent — not billed.
    case cost
}

nonisolated enum TelemetryStack: String, Sendable, CaseIterable {
    case provider, model, account, kind, originator
}

nonisolated struct TelemetryQuery: Sendable, Equatable {
    var scope: TelemetryScope = .fleet
    var window: TelemetryWindow = .days7
    var metric: TelemetryMetric = .inputClass
    /// nil = the scope's default: Fleet stacks by provider, everything else by model.
    var stack: TelemetryStack?
    var now: Date
    var calendar: Calendar
    /// The ledger's oldest event; `.allIndexed` starts at its week.
    var earliestIndexed: Date?

    init(scope: TelemetryScope = .fleet, window: TelemetryWindow = .days7, metric: TelemetryMetric = .inputClass,
         stack: TelemetryStack? = nil, now: Date = Date(), calendar: Calendar = .current, earliestIndexed: Date? = nil) {
        self.scope = scope; self.window = window; self.metric = metric; self.stack = stack
        self.now = now; self.calendar = calendar; self.earliestIndexed = earliestIndexed
    }

    var effectiveStack: TelemetryStack {
        if metric == .inputByKind { return .kind }
        if let stack { return stack }
        switch scope {
        case .fleet: return .provider
        case .provider, .account, .unattributed: return .model
        }
    }

    struct Bucket: Sendable, Equatable {
        var start: Date
        var end: Date
        /// The bucket containing `now` — drawn hatched, excluded from means.
        var isPartial: Bool
    }

    struct Range: Sendable, Equatable {
        var start: Date
        /// Exclusive; `now` for the live windows.
        var end: Date
        var granularity: BucketGranularity
        var buckets: [Bucket]
        /// The same elapsed portion of the period immediately before.
        var previousStart: Date
        var previousEnd: Date
    }

    /// Resolves the window into buckets through the one containing `now`.
    func range() -> Range {
        let cal = calendar
        switch window {
        case .today:
            let start = cal.startOfDay(for: now)
            return Self.makeRange(start: start, stepping: .hour, count: nil, now: now, calendar: cal, periodLength: (.day, 1))
        case .days7:
            let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)) ?? now
            return Self.makeRange(start: start, stepping: .day, count: nil, now: now, calendar: cal, periodLength: (.day, 7))
        case .days30:
            let start = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now)) ?? now
            return Self.makeRange(start: start, stepping: .day, count: nil, now: now, calendar: cal, periodLength: (.day, 30))
        case .allIndexed:
            guard let earliest = earliestIndexed, earliest < now else {
                let start = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now)) ?? now
                return Self.makeRange(start: start, stepping: .day, count: nil, now: now, calendar: cal, periodLength: (.day, 30))
            }
            let weeks = (cal.dateComponents([.weekOfYear], from: earliest, to: now).weekOfYear ?? 0)
            if weeks > 26 {
                let start = cal.dateInterval(of: .month, for: earliest)?.start ?? earliest
                let months = max(1, (cal.dateComponents([.month], from: start, to: now).month ?? 0) + 1)
                return Self.makeRange(start: start, stepping: .month, count: nil, now: now, calendar: cal, periodLength: (.month, months))
            }
            let start = cal.dateInterval(of: .weekOfYear, for: earliest)?.start ?? earliest
            return Self.makeRange(start: start, stepping: .week, count: nil, now: now, calendar: cal, periodLength: (.weekOfYear, weeks + 1))
        }
    }

    private static func makeRange(start: Date, stepping: BucketGranularity, count: Int?, now: Date, calendar: Calendar,
                                  periodLength: (Calendar.Component, Int)) -> Range {
        var buckets: [Bucket] = []
        var cursor = start
        var guardCount = 0
        while cursor <= now, guardCount < 2_000 {
            guardCount += 1
            guard let next = calendar.date(byAdding: stepping.calendarComponent, value: 1, to: cursor) else { break }
            buckets.append(Bucket(start: cursor, end: next, isPartial: next > now))
            cursor = next
        }
        let previousStart = calendar.date(byAdding: periodLength.0, value: -periodLength.1, to: start) ?? start
        let elapsed = now.timeIntervalSince(start)
        return Range(start: start, end: now, granularity: stepping, buckets: buckets,
                     previousStart: previousStart, previousEnd: previousStart.addingTimeInterval(elapsed))
    }

    /// Index of the bucket containing `date`, by binary search on starts.
    static func bucketIndex(for date: Date, in buckets: [Bucket]) -> Int? {
        guard let first = buckets.first, date >= first.start, let last = buckets.last, date < last.end else { return nil }
        var low = 0, high = buckets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if buckets[mid].start <= date { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
