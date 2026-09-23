//
//  FleetCapacity.swift
//  Claude Usage
//
//  The Claude fleet's weekly capacity as ONE pool of points, and a forecast
//  of when it runs dry (docs/specs/fleet-capacity-forecast.md). A point is
//  one percent of one account's weekly window, so an account is worth 100
//  and a fleet of 24 is worth 2 400 a week. Four quantities:
//
//    pool      Σ (100 − weekly %) over the usable accounts, right now
//    ceiling   accounts × 100 / 168 points per hour — every account renews
//              once a week, so no arrangement sustains a burn above this
//    burn      measured points per hour, least squares over the series
//    runway    when the pool reaches zero, simulated forward through each
//              account's own weekly renewal
//
//  Claude only. Everything here is pure and `now`-injectable (see
//  FleetCapacityTests); `MenuBarManager` gathers the inputs, keeps the series
//  and appends to it on the sweep.
//

import Foundation

// MARK: - Inputs

/// One usable Claude ACCOUNT as the forecast reads it: the freshest measured
/// profile of a distinct account (`FleetCounts.accountKey`), so a duplicate
/// pair is one quota, never two.
struct FleetCapacityAccount: Hashable {
    var id: UUID
    var name: String
    /// Measured all-models weekly percentage.
    var weeklyPercentage: Double
    /// The reported (or projected) weekly boundary;
    /// `ClaudeUsage.unknownResetSentinel` when the API never reported one.
    var weeklyResetTime: Date
}

/// One point of the rolling series (`fleetCapacitySeries_v1`): the pool as
/// it stood, over how many accounts, and a key that changes exactly when the
/// pool STEPS rather than drains — an account renewing, joining or leaving.
struct FleetCapacitySample: Hashable {
    var at: Date
    var pool: Double
    var accounts: Int
    /// Σ over the accounts of their next weekly boundary in whole minutes
    /// (the API reports a boundary with ±1 s jitter; the menu-bar ranking
    /// quantizes to the minute for the same reason). A renewal moves one
    /// boundary a week ahead, so the key changes at the very moment the
    /// pool jumps up; two samples with different keys are never regressed
    /// against each other.
    var scheduleKey: Int
}

// MARK: - Forecast

struct FleetCapacityForecast: Hashable {
    /// One account's next weekly renewal inside the forecast horizon.
    struct Renewal: Hashable {
        var id: UUID
        var name: String
        var at: Date
        /// What comes back: the account's used percent as measured NOW. An
        /// account used further before its reset returns more, so the
        /// simulation errs early, never late. Zero for an account whose
        /// window already rolled over (it is full now; what its next reset
        /// returns is not known yet).
        var points: Double
    }

    /// Renewals falling on one weekday of the coming week.
    struct WeekdayRenewals: Hashable {
        /// `Calendar.component(.weekday, …)`: 1 = Sunday … 7 = Saturday.
        var weekday: Int
        var accounts: Int
        var points: Double
    }

    enum Runway: Hashable {
        /// Fewer than `FleetCapacity.minSamples` usable samples, or less than
        /// `FleetCapacity.minSpan` of history between them. No ETA.
        case insufficientHistory
        /// The pool is flat or filling. No ETA.
        case notDraining
        /// Draining, at or below the sustainable ceiling. No ETA.
        case sustainable
        /// Above the ceiling: the simulated pool reaches zero at `at`;
        /// `nextRenewal` is the first renewal after it (nil past the horizon).
        case zero(at: Date, nextRenewal: Renewal?)
        /// Above the ceiling, yet the pool survives every scheduled renewal
        /// inside the horizon. Unreachable over a full week (Σ renewals +
        /// pool = accounts × 100 < burn × 168), kept so the simulation never
        /// has to invent a zero.
        case survives
    }

    var now: Date
    /// Points left right now across the usable, measured accounts.
    var pool: Double
    /// Usable accounts with a measurement — the pool's denominator.
    var accounts: Int
    /// Usable accounts never measured: in neither the pool nor the ceiling.
    var unmeasured: Int
    /// Sustainable burn, points per hour.
    var ceiling: Double
    /// Measured burn, points per hour (negative = filling); nil below the
    /// evidence bar.
    var burn: Double?
    /// The evidence the fit rests on.
    var fitSamples: Int
    var fitSpan: TimeInterval
    var runway: Runway
    /// Every usable account's next renewal inside the horizon, soonest first.
    var renewals: [Renewal]
    /// The coming seven days from today, one entry per weekday.
    var weekdayProfile: [WeekdayRenewals]

    nonisolated var maximum: Double { Double(accounts) * FleetCapacity.pointsPerAccount }

    /// burn ÷ ceiling — above 1 the pool drains, below it refills.
    nonisolated var burnRatio: Double? {
        guard let burn, ceiling > 0 else { return nil }
        return burn / ceiling
    }

    nonisolated var zeroAt: Date? {
        if case .zero(let at, _) = runway { return at }
        return nil
    }
}

// MARK: - The maths

enum FleetCapacity {
    nonisolated static let pointsPerAccount: Double = 100
    nonisolated static let weekHours: Double = 168
    nonisolated static let week: TimeInterval = 7 * 24 * 3600

    /// Evidence bar for a burn rate (the owner's rule: never fabricate a
    /// runway): at least this many samples …
    nonisolated static let minSamples = 6
    /// … spanning at least this much history.
    nonisolated static let minSpan: TimeInterval = 3600
    /// The series takes one sample per this interval at most …
    nonisolated static let sampleInterval: TimeInterval = 300
    /// … and keeps this much history (≈ 288 samples, a few KB).
    nonisolated static let retention: TimeInterval = 24 * 3600
    /// Hard cap on stored samples, whatever the clock does.
    nonisolated static let maxSamples = 300

    // MARK: Pool and ceiling

    /// Points left in one account's week. A window whose reset already
    /// passed is full again (the readiness rule); a sentinel reset is not a
    /// reset, so it reads its measured percentage.
    nonisolated static func remaining(_ account: FleetCapacityAccount, now: Date) -> Double {
        let reset = account.weeklyResetTime
        if reset != ClaudeUsage.unknownResetSentinel, reset < now { return pointsPerAccount }
        return max(0, min(pointsPerAccount, pointsPerAccount - account.weeklyPercentage))
    }

    nonisolated static func pool(_ accounts: [FleetCapacityAccount], now: Date) -> Double {
        accounts.reduce(0) { $0 + remaining($1, now: now) }
    }

    /// The highest burn the fleet can sustain indefinitely: each account
    /// renews its 100 points once every 168 hours.
    nonisolated static func ceiling(accounts: Int) -> Double {
        Double(accounts) * pointsPerAccount / weekHours
    }

    // MARK: Renewals

    /// Each account's next weekly boundary inside `horizon`, soonest first.
    /// Accounts with no known boundary have no renewal.
    nonisolated static func renewals(
        _ accounts: [FleetCapacityAccount],
        now: Date,
        horizon: TimeInterval = week
    ) -> [FleetCapacityForecast.Renewal] {
        accounts.compactMap { account -> FleetCapacityForecast.Renewal? in
            let reset = account.weeklyResetTime
            guard reset != ClaudeUsage.unknownResetSentinel else { return nil }
            let rolledOver = reset < now
            let next = rolledOver ? ClaudeUsage.projectedWeeklyBoundary(reset, after: now) : reset
            guard next <= now.addingTimeInterval(horizon) else { return nil }
            let points = rolledOver ? 0 : max(0, min(pointsPerAccount, account.weeklyPercentage))
            return FleetCapacityForecast.Renewal(id: account.id, name: account.name, at: next, points: points)
        }
        .sorted { ($0.at, $0.name) < ($1.at, $1.name) }
    }

    /// See `FleetCapacitySample.scheduleKey`.
    nonisolated static func scheduleKey(_ accounts: [FleetCapacityAccount], now: Date) -> Int {
        accounts.reduce(0) { key, account in
            let reset = account.weeklyResetTime
            guard reset != ClaudeUsage.unknownResetSentinel else { return key }
            let next = reset < now ? ClaudeUsage.projectedWeeklyBoundary(reset, after: now) : reset
            return key &+ Int((next.timeIntervalSince1970 / 60).rounded())
        }
    }

    /// How many accounts renew on each of the next seven weekdays, today
    /// first — the Saturday cluster the owner asked to see.
    nonisolated static func weekdayProfile(
        _ renewals: [FleetCapacityForecast.Renewal],
        now: Date,
        calendar: Calendar
    ) -> [FleetCapacityForecast.WeekdayRenewals] {
        let today = calendar.component(.weekday, from: now)
        var byDay: [Int: FleetCapacityForecast.WeekdayRenewals] = [:]
        for offset in 0..<7 {
            let weekday = (today - 1 + offset) % 7 + 1
            byDay[weekday] = FleetCapacityForecast.WeekdayRenewals(weekday: weekday, accounts: 0, points: 0)
        }
        for renewal in renewals {
            let weekday = calendar.component(.weekday, from: renewal.at)
            byDay[weekday]?.accounts += 1
            byDay[weekday]?.points += renewal.points
        }
        return (0..<7).compactMap { byDay[(today - 1 + $0) % 7 + 1] }
    }

    // MARK: Burn

    struct BurnFit: Hashable {
        /// Points per hour, positive = draining; nil below the evidence bar.
        var rate: Double?
        /// Samples the fit used (segments of two or more).
        var samples: Int
        /// Σ of the segments' own spans.
        var span: TimeInterval
    }

    /// Least-squares burn over the series, robust to the two things that
    /// make a pool series lie:
    ///
    ///  - **Steps.** A renewal, an eligibility edit or an account joining
    ///    moves the pool at once; regressed across, a renewal reads as
    ///    negative burn. The series is cut into runs of equal
    ///    (`accounts`, `scheduleKey`) and the slope is pooled WITHIN runs
    ///    (one intercept per run), so a step between runs contributes
    ///    nothing. A run of one sample carries no slope and is dropped.
    ///  - **Jitter.** Background accounts are re-measured every few minutes,
    ///    so the pool moves in small steps; the fit uses every point, not
    ///    first-minus-last.
    ///
    /// Only samples inside `window` before `now` count.
    nonisolated static func burnRate(
        _ series: [FleetCapacitySample],
        now: Date,
        window: TimeInterval = retention
    ) -> BurnFit {
        let recent = series
            .filter { $0.at <= now && now.timeIntervalSince($0.at) <= window }
            .sorted { $0.at < $1.at }
        var runs: [[FleetCapacitySample]] = []
        for sample in recent {
            if let last = runs.last?.last, last.accounts == sample.accounts, last.scheduleKey == sample.scheduleKey {
                runs[runs.count - 1].append(sample)
            } else {
                runs.append([sample])
            }
        }
        runs = runs.filter { $0.count >= 2 }

        let used = runs.reduce(0) { $0 + $1.count }
        let span = runs.reduce(0) { $0 + $1.last!.at.timeIntervalSince($1.first!.at) }
        guard used >= minSamples, span >= minSpan else {
            return BurnFit(rate: nil, samples: used, span: span)
        }

        var sxy = 0.0
        var sxx = 0.0
        for run in runs {
            // Hours relative to the run's first sample keep the sums small.
            let origin = run[0].at
            let xs = run.map { $0.at.timeIntervalSince(origin) / 3600 }
            let ys = run.map(\.pool)
            let mx = xs.reduce(0, +) / Double(xs.count)
            let my = ys.reduce(0, +) / Double(ys.count)
            for (x, y) in zip(xs, ys) {
                sxy += (x - mx) * (y - my)
                sxx += (x - mx) * (x - mx)
            }
        }
        guard sxx > 0 else { return BurnFit(rate: nil, samples: used, span: span) }
        // The pool falls as the fleet burns: burn is the negated slope.
        return BurnFit(rate: -sxy / sxx, samples: used, span: span)
    }

    // MARK: Runway

    /// Walks the pool forward at `burnPerHour`, adding each renewal's points
    /// at its boundary, and returns the moment it reaches zero — nil when it
    /// survives every renewal and the rest of `horizon`.
    nonisolated static func zeroTime(
        pool: Double,
        burnPerHour: Double,
        renewals: [FleetCapacityForecast.Renewal],
        now: Date,
        horizon: TimeInterval = week
    ) -> Date? {
        guard burnPerHour > 0 else { return nil }
        if pool <= 0 { return now }
        let end = now.addingTimeInterval(horizon)
        var level = pool
        var t = now
        for renewal in renewals.sorted(by: { $0.at < $1.at }) where renewal.at > now && renewal.at <= end {
            let drained = burnPerHour * renewal.at.timeIntervalSince(t) / 3600
            if drained >= level {
                return t.addingTimeInterval(level / burnPerHour * 3600)
            }
            level -= drained
            level += renewal.points
            t = renewal.at
        }
        let drained = burnPerHour * end.timeIntervalSince(t) / 3600
        if drained >= level {
            return t.addingTimeInterval(level / burnPerHour * 3600)
        }
        return nil
    }

    // MARK: Forecast

    /// The whole picture, or nil when no usable account has been measured
    /// (there is no pool to speak of).
    nonisolated static func forecast(
        accounts: [FleetCapacityAccount],
        unmeasured: Int = 0,
        series: [FleetCapacitySample],
        now: Date,
        calendar: Calendar = .current
    ) -> FleetCapacityForecast? {
        guard !accounts.isEmpty else { return nil }
        let pool = pool(accounts, now: now)
        let ceiling = ceiling(accounts: accounts.count)
        let renewals = renewals(accounts, now: now)
        let fit = burnRate(series, now: now)

        let runway: FleetCapacityForecast.Runway
        if let burn = fit.rate {
            if burn <= 0 {
                runway = .notDraining
            } else if burn <= ceiling {
                runway = .sustainable
            } else if let zero = zeroTime(pool: pool, burnPerHour: burn, renewals: renewals, now: now) {
                runway = .zero(at: zero, nextRenewal: renewals.first { $0.at > zero })
            } else {
                runway = .survives
            }
        } else {
            runway = .insufficientHistory
        }

        return FleetCapacityForecast(
            now: now, pool: pool, accounts: accounts.count, unmeasured: unmeasured,
            ceiling: ceiling, burn: fit.rate, fitSamples: fit.samples, fitSpan: fit.span,
            runway: runway, renewals: renewals,
            weekdayProfile: weekdayProfile(renewals, now: now, calendar: calendar)
        )
    }

    // MARK: Series

    /// The sample for this moment, or nil with nothing to measure.
    nonisolated static func sample(_ accounts: [FleetCapacityAccount], now: Date) -> FleetCapacitySample? {
        guard !accounts.isEmpty else { return nil }
        return FleetCapacitySample(at: now, pool: pool(accounts, now: now), accounts: accounts.count,
                                   scheduleKey: scheduleKey(accounts, now: now))
    }

    /// The series with `sample` appended, trimmed to `retention` and
    /// `maxSamples`; nil when the newest sample is younger than
    /// `sampleInterval` (nothing to write). A clock that jumped backwards
    /// drops the samples now in the future.
    nonisolated static func appending(
        _ sample: FleetCapacitySample,
        to series: [FleetCapacitySample]
    ) -> [FleetCapacitySample]? {
        let kept = series.filter { $0.at <= sample.at && sample.at.timeIntervalSince($0.at) <= retention }
        if let last = kept.last, sample.at.timeIntervalSince(last.at) < sampleInterval { return nil }
        return Array((kept + [sample]).suffix(maxSamples))
    }
}

// MARK: - From the roster

extension FleetCapacity {
    /// A Claude account is in the pool when the rotation can reach it: it
    /// holds usage credentials, its login is not dead, and the auto-switch
    /// would accept it (`isExcluded`: toggle off, or a free plan). The two
    /// predicates are the fleet dots' own (`FleetSummaryContext`), so the
    /// pool counts exactly the accounts a green dot could stand for.
    static func isUsable(
        _ profile: Profile,
        isLoginDead: (Profile) -> Bool,
        isExcluded: (Profile) -> Bool
    ) -> Bool {
        profile.providerKind == .claude && profile.hasUsageCredentials && !isLoginDead(profile) && !isExcluded(profile)
    }

    /// The usable Claude accounts behind `profiles`, one per DISTINCT account
    /// (`FleetCounts.accountKey` — the rule `capacityRemaining` already uses,
    /// so a duplicate pair is one quota, never two) and read from its
    /// freshest measured profile. `isUsable` is the caller's rule: auto-switch
    /// eligible, holding usage credentials, not on the dead-login list. A
    /// usable account never measured is counted in `unmeasured` and nowhere
    /// else — no evidence, no points.
    static func accounts(
        from profiles: [Profile],
        isUsable: (Profile) -> Bool
    ) -> (accounts: [FleetCapacityAccount], unmeasured: Int) {
        var order: [String] = []
        var groups: [String: [Profile]] = [:]
        for profile in profiles where profile.providerKind == .claude && isUsable(profile) {
            let key = FleetCounts.accountKey(profile)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(profile)
        }
        var accounts: [FleetCapacityAccount] = []
        var unmeasured = 0
        for key in order {
            let freshest = groups[key, default: []]
                .compactMap { profile in profile.claudeUsage.map { (profile, $0) } }
                .max { $0.1.lastUpdated < $1.1.lastUpdated }
            guard let (profile, usage) = freshest else {
                unmeasured += 1
                continue
            }
            accounts.append(FleetCapacityAccount(
                id: profile.id, name: profile.name,
                weeklyPercentage: usage.weeklyPercentage, weeklyResetTime: usage.weeklyResetTime))
        }
        return (accounts, unmeasured)
    }
}

// MARK: - Words

/// The forecast in words — the Claude tile's tooltip (one line each for the
/// pool, the burn against the ceiling, and the runway) and the dashboard
/// card read the same sentences.
enum FleetCapacityFormatting {
    static func points(_ value: Double) -> String {
        String(Int(max(0, value).rounded(.down)))
    }

    static func rate(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// "Weekly pool: 609 of 2400 points (24 accounts)".
    static func poolLine(_ f: FleetCapacityForecast) -> String {
        var line = "Weekly pool: \(points(f.pool)) of \(points(f.maximum)) points (\(f.accounts) account\(f.accounts == 1 ? "" : "s")"
        if f.unmeasured > 0 { line += ", \(f.unmeasured) unmeasured" }
        return line + ")"
    }

    /// "Burn 37.1 pt/h vs sustainable 14.3 pt/h (2.6×)".
    static func burnLine(_ f: FleetCapacityForecast) -> String {
        let ceiling = "sustainable \(rate(f.ceiling)) pt/h"
        guard let burn = f.burn else {
            return "Burn: measuring (\(f.fitSamples) of \(FleetCapacity.minSamples) samples, "
                + "\(Int(f.fitSpan / 60)) of \(Int(FleetCapacity.minSpan / 60)) min) · \(ceiling)"
        }
        let ratio = f.burnRatio.map { String(format: " (%.1f×)", max(0, $0)) } ?? ""
        return burn <= 0
            ? "Burn \(rate(burn)) pt/h (filling) vs \(ceiling)"
            : "Burn \(rate(burn)) pt/h vs \(ceiling)\(ratio)"
    }

    /// "Runway: zero Wed 22:36 (in 31 h), before Last renews Thu 17:00".
    static func runwayLine(_ f: FleetCapacityForecast) -> String {
        switch f.runway {
        case .insufficientHistory:
            return "Runway: needs \(FleetCapacity.minSamples) samples over \(Int(FleetCapacity.minSpan / 60)) min of history"
        case .notDraining:
            return "Runway: none, the pool is not draining"
        case .sustainable:
            return "Runway: none, burn is at or below the sustainable rate"
        case .survives:
            return "Runway: the pool survives every renewal this week"
        case .zero(let at, let next):
            var line = "Runway: zero \(weekdayTime(at)) (in \(hours(at.timeIntervalSince(f.now))))"
            if let next { line += ", before \(next.name) renews \(weekdayTime(next.at))" }
            return line
        }
    }

    static func tooltipLines(_ f: FleetCapacityForecast) -> [String] {
        [poolLine(f), burnLine(f), runwayLine(f)]
    }

    /// "31 h" / "45 min" / "3 d 4 h", rounded down.
    static func hours(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h" }
        return hours % 24 == 0 ? "\(hours / 24) d" : "\(hours / 24) d \(hours % 24) h"
    }

    /// "Wed 22:36" in the user's locale and clock preference.
    static func weekdayTime(_ date: Date) -> String {
        weekdayTimeFormatter.string(from: date)
    }

    /// "Sat" for `Calendar` weekday 7.
    static func weekdayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "?"
    }

    private static let weekdayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter
    }()
}

// MARK: - Bar text

/// What the fleet block draws to the right of the candidate row:
/// `609·31h`, or the pool alone when there is no runway to state or no room
/// for one. Claude only.
struct CapacityAffix: Hashable {
    enum Urgency: Hashable {
        case calm, soon, imminent
    }

    /// The pool, rounded down (a forecast that errs, errs low).
    var pool: String
    /// Hours / days / minutes to zero; nil when there is no ETA.
    var runway: String?
    var urgency: Urgency

    /// Runway within this reads orange …
    nonisolated static let soon: TimeInterval = 24 * 3600
    /// … and within this, red.
    nonisolated static let imminent: TimeInterval = 6 * 3600

    nonisolated static let separator = "·"

    nonisolated init(pool: String, runway: String?, urgency: Urgency) {
        self.pool = pool
        self.runway = runway
        self.urgency = urgency
    }

    nonisolated init(_ forecast: FleetCapacityForecast) {
        pool = String(Int(max(0, forecast.pool).rounded(.down)))
        if let zero = forecast.zeroAt, zero > forecast.now {
            let left = zero.timeIntervalSince(forecast.now)
            runway = Self.compact(left)
            urgency = left <= Self.imminent ? .imminent : (left <= Self.soon ? .soon : .calm)
        } else {
            // No time left to state: an empty pool is still worth a red.
            runway = nil
            urgency = forecast.pool <= 0 || forecast.zeroAt != nil ? .imminent : .calm
        }
    }

    /// `pool·runway`, or the pool alone.
    var full: String { runway.map { pool + Self.separator + $0 } ?? pool }

    /// `45m` under an hour, `31h` under two days, `3d` beyond — always
    /// rounded DOWN, so the bar never promises time the forecast lacks.
    nonisolated static func compact(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
