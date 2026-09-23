//
//  FleetCapacityTests.swift
//  Claude UsageTests
//
//  The Claude fleet's weekly pool and its forecast
//  (docs/specs/fleet-capacity-forecast.md): the pool over usable accounts
//  only, the sustainable ceiling, a least-squares burn that steps cannot
//  fool, the forward simulation through each account's renewal, and the
//  rule that no runway is ever printed without the evidence for one.
//  Deterministic clocks only: `now` is a fixed Tuesday, 15:30 UTC.
//

import AppKit
import XCTest
@testable import Claude_Usage

@MainActor
final class FleetCapacityTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Tuesday 2026-09-22, 15:30 UTC.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 15, minute: 30))! }

    private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    private func account(_ name: String, used: Double, resetIn hours: Double) -> FleetCapacityAccount {
        FleetCapacityAccount(id: UUID(), name: name, weeklyPercentage: used, weeklyResetTime: at(hours))
    }

    /// `count` samples ending at `now`, `every` minutes apart, draining at
    /// `burn` points per hour from `startPool`, with optional per-sample noise.
    private func series(count: Int, every minutes: Double, burn: Double, startPool: Double = 1000,
                        accounts: Int = 24, key: Int = 1, noise: [Double] = []) -> [FleetCapacitySample] {
        (0..<count).map { i in
            let hoursBack = Double(count - 1 - i) * minutes / 60
            let elapsed = Double(i) * minutes / 60
            let jitter = noise.isEmpty ? 0 : noise[i % noise.count]
            return FleetCapacitySample(at: at(-hoursBack), pool: startPool - burn * elapsed + jitter,
                                       accounts: accounts, scheduleKey: key)
        }
    }

    private func usage(weekly: Double, resetIn hours: Double = 48, age: TimeInterval = 30) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.weeklyPercentage = weekly
        u.weeklyResetTime = at(hours)
        u.lastUpdated = now.addingTimeInterval(-age)
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?, autoSwitch: Bool = true, account: String? = nil) -> Profile {
        var p = Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org",
                        claudeUsage: u, includeInAutoSwitch: autoSwitch)
        p.claudeAccountUUID = account
        return p
    }

    // MARK: - Pool

    /// Σ (100 − weekly %) over USABLE accounts: an auto-switch-off account,
    /// a dead login and a profile with no credentials add nothing; a
    /// duplicate pair is one quota read from its freshest reading; a window
    /// that already rolled over is full; a usable account never measured is
    /// reported, not guessed; Codex is not in the Claude pool.
    func testPoolSumsHeadroomOverUsableAccountsOnly() {
        let atlas = claude("Atlas", usage(weekly: 30, age: 600), account: "acct-a")
        let atlasTwin = claude("Atlas twin", usage(weekly: 40, age: 20), account: "acct-a")
        let spent = claude("Beacon", usage(weekly: 100))
        let rolledOver = claude("Cedar", usage(weekly: 90, resetIn: -2))
        let optedOut = claude("Delta", usage(weekly: 0), autoSwitch: false)
        let dead = claude("Echo", usage(weekly: 0))
        let noCredentials = Profile(name: "Fjord", claudeUsage: usage(weekly: 0))
        let unmeasured = claude("Granite", nil)
        let codex = Profile(name: "Kestrel", codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
                            codexEmail: "k@example.com", claudeUsage: usage(weekly: 0))
        XCTAssertFalse(noCredentials.hasUsageCredentials, "fixture: no credentials at all")

        let usable = FleetCapacity.accounts(
            from: [atlas, atlasTwin, spent, rolledOver, optedOut, dead, noCredentials, unmeasured, codex],
            isUsable: { profile in
                FleetCapacity.isUsable(profile, isLoginDead: { $0.id == dead.id }, isExcluded: { !$0.isAutoSwitchEnabled })
            }
        )

        XCTAssertEqual(usable.accounts.map(\.name), ["Atlas twin", "Beacon", "Cedar"],
                       "one account per quota, the freshest reading of the pair")
        XCTAssertEqual(usable.unmeasured, 1)
        XCTAssertEqual(FleetCapacity.pool(usable.accounts, now: now), 60 + 0 + 100, accuracy: 1e-9)

        let forecast = FleetCapacity.forecast(accounts: usable.accounts, unmeasured: usable.unmeasured,
                                              series: [], now: now, calendar: calendar)
        XCTAssertEqual(forecast?.maximum, 300)
        XCTAssertEqual(forecast?.accounts, 3)
        XCTAssertNil(FleetCapacity.forecast(accounts: [], series: [], now: now), "nothing measured: no pool to show")
    }

    func testCeilingIsAccountsTimesAHundredOverAWeekOfHours() {
        XCTAssertEqual(FleetCapacity.ceiling(accounts: 24), 2400.0 / 168, accuracy: 1e-12)
        XCTAssertEqual(FleetCapacity.ceiling(accounts: 24), 14.29, accuracy: 0.01)
        XCTAssertEqual(FleetCapacity.ceiling(accounts: 0), 0)
    }

    // MARK: - Burn

    func testLeastSquaresBurnRecoversTheRateThroughJitter() {
        let clean = FleetCapacity.burnRate(series(count: 8, every: 15, burn: 37), now: now)
        XCTAssertEqual(clean.rate ?? .nan, 37, accuracy: 1e-9)
        XCTAssertEqual(clean.samples, 8)
        XCTAssertEqual(clean.span, 105 * 60, accuracy: 1e-6)

        // Background accounts re-measured every few minutes move the pool in
        // small steps. First-minus-last reads the endpoints' noise; the fit
        // reads every point.
        let noisy = series(count: 8, every: 15, burn: 37, noise: [3, -3])
        let fit = FleetCapacity.burnRate(noisy, now: now).rate ?? .nan
        let endpoints = (noisy.first!.pool - noisy.last!.pool) / (noisy.last!.at.timeIntervalSince(noisy.first!.at) / 3600)
        XCTAssertEqual(fit, 37, accuracy: 1.5)
        XCTAssertLessThan(abs(fit - 37), abs(endpoints - 37), "least squares beats first-minus-last")
    }

    /// A renewal or an account joining steps the pool UP. Regressed across,
    /// the step reads as negative burn; cut into runs of equal
    /// (accounts, scheduleKey), it contributes nothing.
    func testAccountCountAndRenewalStepsAreNotReadAsBurn() {
        var samples = series(count: 13, every: 10, burn: 30)
        for i in 6..<13 {
            samples[i].accounts = 25          // an account joined …
            samples[i].pool += 100            // … and brought its 100 points
        }
        for i in 10..<13 {
            samples[i].scheduleKey = 2        // a renewal: the key moves …
            samples[i].pool += 80             // … as the pool jumps
        }
        let fit = FleetCapacity.burnRate(samples, now: now)
        XCTAssertEqual(fit.rate ?? .nan, 30, accuracy: 1e-9)
        XCTAssertEqual(fit.samples, 13)

        // Unsegmented, the same points would say the pool is FILLING.
        var naive = samples
        for i in naive.indices { naive[i].accounts = 24; naive[i].scheduleKey = 1 }
        XCTAssertLessThan(FleetCapacity.burnRate(naive, now: now).rate ?? .nan, 0)

        // Every sample its own run: no slope anywhere, no rate.
        var shattered = series(count: 12, every: 10, burn: 30)
        for i in shattered.indices { shattered[i].scheduleKey = i }
        let none = FleetCapacity.burnRate(shattered, now: now)
        XCTAssertNil(none.rate)
        XCTAssertEqual(none.samples, 0)
    }

    func testScheduleKeyMovesWhenAnAccountRenews() {
        let before = [account("A", used: 60, resetIn: 0.5), account("B", used: 20, resetIn: 30)]
        let keyBefore = FleetCapacity.scheduleKey(before, now: now)
        XCTAssertEqual(FleetCapacity.scheduleKey(before, now: at(0.25)), keyBefore, "draining never moves the key")
        XCTAssertNotEqual(FleetCapacity.scheduleKey(before, now: at(1)), keyBefore,
                          "A's boundary passed: it is a week ahead now, and so is the key")
        // ±1 s of API jitter on a boundary is the same minute.
        var jittered = before
        jittered[1].weeklyResetTime = jittered[1].weeklyResetTime.addingTimeInterval(1)
        XCTAssertEqual(FleetCapacity.scheduleKey(jittered, now: now), keyBefore)
    }

    // MARK: - Forward simulation

    func testARenewalBeforeTheZeroRescuesThePool() {
        let alone = FleetCapacity.zeroTime(pool: 100, burnPerHour: 40, renewals: [], now: now)
        XCTAssertEqual(alone, at(2.5))

        // 100 − 2 h × 40 = 20 left when 60 come back; 80 more at 40/h is 2 h.
        let rescue = FleetCapacityForecast.Renewal(id: UUID(), name: "Wed", at: at(2), points: 60)
        XCTAssertEqual(FleetCapacity.zeroTime(pool: 100, burnPerHour: 40, renewals: [rescue], now: now), at(4))
    }

    func testARenewalAfterTheZeroArrivesTooLate() {
        let late = FleetCapacityForecast.Renewal(id: UUID(), name: "Last", at: at(3), points: 90)
        XCTAssertEqual(FleetCapacity.zeroTime(pool: 100, burnPerHour: 40, renewals: [late], now: now), at(2.5))

        // Through the forecast: the runway names the renewal it misses.
        // Two accounts, 60 points left, burning 50/h against a 1.19/h ceiling.
        let accounts = [account("Harbor", used: 70, resetIn: 1), account("Last", used: 70, resetIn: 25.5)]
        let forecast = FleetCapacity.forecast(accounts: accounts, series: series(count: 8, every: 10, burn: 50),
                                              now: now, calendar: calendar)!
        // 60 − 50 = 10 at +1 h, Harbor returns 70 → 80, gone 1.6 h later.
        XCTAssertEqual(forecast.pool, 60, accuracy: 1e-9)
        guard case .zero(let zero, let next) = forecast.runway else {
            return XCTFail("expected a runway, got \(forecast.runway)")
        }
        XCTAssertEqual(zero.timeIntervalSince(now), 2.6 * 3600, accuracy: 1)
        XCTAssertEqual(next?.name, "Last")
        XCTAssertEqual(CapacityAffix(forecast).full, "60·2h")
        XCTAssertEqual(CapacityAffix(forecast).urgency, .imminent)
    }

    /// Above the ceiling a full week's horizon ALWAYS ends in a zero: the
    /// pool plus every renewal is at most accounts × 100, and the burn takes
    /// more than that in 168 h. `.survives` exists so the simulation never
    /// invents one, not because it is reachable.
    func testAboveTheCeilingTheWeekAlwaysRunsDry() {
        let accounts = (0..<24).map { i in account("A\(i)", used: Double((i * 37) % 101), resetIn: Double(i * 7 % 168) + 0.5) }
        let pool = FleetCapacity.pool(accounts, now: now)
        let renewals = FleetCapacity.renewals(accounts, now: now)
        let ceiling = FleetCapacity.ceiling(accounts: accounts.count)
        XCTAssertNotNil(FleetCapacity.zeroTime(pool: pool, burnPerHour: ceiling * 1.01, renewals: renewals, now: now))
        XCTAssertNil(FleetCapacity.zeroTime(pool: 2400, burnPerHour: ceiling * 0.99, renewals: [], now: now),
                     "a full pool just under the ceiling lasts the week")
    }

    // MARK: - When there is no runway to print

    func testBurnAtOrBelowTheCeilingIsSustainedWithNoETA() {
        let accounts = (0..<24).map { account("A\($0)", used: 80, resetIn: 100) }
        let forecast = FleetCapacity.forecast(accounts: accounts, series: series(count: 12, every: 10, burn: 10),
                                              now: now, calendar: calendar)!
        XCTAssertEqual(forecast.burn ?? .nan, 10, accuracy: 1e-9)
        XCTAssertLessThan(forecast.burnRatio ?? .nan, 1)
        XCTAssertEqual(forecast.runway, .sustainable)
        XCTAssertNil(forecast.zeroAt)
        let affix = CapacityAffix(forecast)
        XCTAssertEqual(affix.pool, "480")
        XCTAssertNil(affix.runway)
        XCTAssertEqual(affix.full, "480", "the pool alone")

        let filling = FleetCapacity.forecast(accounts: accounts, series: series(count: 12, every: 10, burn: -5),
                                             now: now, calendar: calendar)!
        XCTAssertEqual(filling.runway, .notDraining)
        XCTAssertNil(CapacityAffix(filling).runway)
    }

    /// Never fabricate a runway: under six samples, or under an hour of
    /// history, the pool is shown and the ETA is not — however fast the
    /// burn looks.
    func testInsufficientHistoryShowsThePoolWithoutAnETA() {
        let accounts = (0..<24).map { account("A\($0)", used: 75, resetIn: 100) }
        let cases: [(String, [FleetCapacitySample])] = [
            ("no series yet", []),
            ("five samples over two hours", series(count: 5, every: 30, burn: 90)),
            ("nine samples over forty minutes", series(count: 9, every: 5, burn: 90)),
        ]
        for (label, samples) in cases {
            let forecast = FleetCapacity.forecast(accounts: accounts, series: samples, now: now, calendar: calendar)!
            XCTAssertNil(forecast.burn, label)
            XCTAssertEqual(forecast.runway, .insufficientHistory, label)
            XCTAssertNil(forecast.zeroAt, label)
            XCTAssertEqual(CapacityAffix(forecast).full, "600", label)
        }
        // One more sample over the hour and the same burn earns its ETA.
        let enough = FleetCapacity.forecast(accounts: accounts, series: series(count: 13, every: 5, burn: 90),
                                            now: now, calendar: calendar)!
        XCTAssertNotNil(enough.zeroAt)
    }

    // MARK: - Renewal profile

    func testWeekdayProfileStartsTodayAndShowsTheCluster() {
        // Tuesday 15:30: Wed 17:00 is +25.5 h, Sat 09:00 +89.5 h, Sun 12:00 +116.5 h.
        let accounts = [
            account("Wed", used: 50, resetIn: 25.5),
            account("Sat1", used: 80, resetIn: 89.5), account("Sat2", used: 20, resetIn: 90),
            account("Sun", used: 10, resetIn: 116.5),
            account("Unknown", used: 10, resetIn: 0),
        ]
        var withSentinel = accounts
        withSentinel[4].weeklyResetTime = ClaudeUsage.unknownResetSentinel
        let profile = FleetCapacity.forecast(accounts: withSentinel, series: [], now: now, calendar: calendar)!.weekdayProfile
        XCTAssertEqual(profile.map(\.weekday), [3, 4, 5, 6, 7, 1, 2], "Tuesday first")
        XCTAssertEqual(profile.map(\.accounts), [0, 1, 0, 0, 2, 1, 0], "a boundary never reported renews nowhere")
        XCTAssertEqual(profile[4].points, 100, accuracy: 1e-9)
        XCTAssertEqual(FleetCapacityFormatting.weekdayName(7, calendar: calendar), calendar.shortWeekdaySymbols[6])
    }

    // MARK: - Series

    func testSeriesAppendsEveryFiveMinutesKeepsADayAndCaps() {
        let s0 = FleetCapacitySample(at: now, pool: 600, accounts: 24, scheduleKey: 1)
        let one = FleetCapacity.appending(s0, to: [])!
        XCTAssertEqual(one.count, 1)
        XCTAssertNil(FleetCapacity.appending(FleetCapacitySample(at: at(4 / 60), pool: 598, accounts: 24, scheduleKey: 1), to: one),
                     "within five minutes: nothing to write")
        let fiveLater = FleetCapacitySample(at: now.addingTimeInterval(FleetCapacity.sampleInterval), pool: 597, accounts: 24, scheduleKey: 1)
        XCTAssertEqual(FleetCapacity.appending(fiveLater, to: one)?.count, 2)

        let old = FleetCapacitySample(at: at(-25), pool: 900, accounts: 24, scheduleKey: 1)
        XCTAssertEqual(FleetCapacity.appending(s0, to: [old])?.map(\.pool), [600], "older than a day is dropped")

        let future = FleetCapacitySample(at: at(1), pool: 500, accounts: 24, scheduleKey: 1)
        XCTAssertEqual(FleetCapacity.appending(s0, to: [future])?.map(\.pool), [600], "a clock that jumped back drops the future")

        let full = (0..<400).map { FleetCapacitySample(at: at(-Double(400 - $0) / 60), pool: 1, accounts: 1, scheduleKey: 1) }
        XCTAssertEqual(FleetCapacity.appending(FleetCapacitySample(at: at(1), pool: 2, accounts: 1, scheduleKey: 1), to: full)?.count,
                       FleetCapacity.maxSamples)
    }

    func testSeriesRoundTripsThroughTheStoreAndIsRegistered() {
        let store = SharedDataStore.shared
        defer { UserDefaults(suiteName: "com.claudeusagewidget.tests")?.removeObject(forKey: "fleetCapacitySeries_v1") }
        let samples = series(count: 3, every: 5, burn: 12)
        store.saveFleetCapacitySeries(samples)
        let loaded = store.loadFleetCapacitySeries()
        XCTAssertEqual(loaded.count, 3)
        for (a, b) in zip(loaded, samples) {
            XCTAssertEqual(a.at.timeIntervalSince1970, b.at.timeIntervalSince1970, accuracy: 1e-6)
            XCTAssertEqual(a.pool, b.pool, accuracy: 1e-9)
            XCTAssertEqual(a.accounts, b.accounts)
            XCTAssertEqual(a.scheduleKey, b.scheduleKey)
        }
        XCTAssertEqual(SettingsKeyRegistry.lookup("fleetCapacitySeries_v1")?.status, .live)
    }

    // MARK: - Words

    func testCompactRunwayRoundsDownAndUrgencyFollowsIt() {
        func affix(zeroIn hours: Double?, pool: Double = 609) -> CapacityAffix {
            CapacityAffix(FleetCapacityForecast(
                now: now, pool: pool, accounts: 24, unmeasured: 0, ceiling: 14.3, burn: 37, fitSamples: 12, fitSpan: 7200,
                runway: hours.map { .zero(at: at($0), nextRenewal: nil) } ?? .sustainable, renewals: [], weekdayProfile: []))
        }
        XCTAssertEqual(affix(zeroIn: 31.5).full, "609·31h")
        XCTAssertEqual(affix(zeroIn: 31.5).urgency, .calm)
        XCTAssertEqual(affix(zeroIn: 10).urgency, .soon)
        XCTAssertEqual(affix(zeroIn: 5).urgency, .imminent)
        XCTAssertEqual(affix(zeroIn: nil).urgency, .calm)
        XCTAssertEqual(affix(zeroIn: nil, pool: 0).urgency, .imminent, "an empty pool is red with or without a runway")
        XCTAssertEqual(affix(zeroIn: 5, pool: 1450.9).pool, "1450", "rounded down")

        XCTAssertEqual(CapacityAffix.compact(45 * 60 + 59), "45m")
        XCTAssertEqual(CapacityAffix.compact(31 * 3600 + 3599), "31h")
        XCTAssertEqual(CapacityAffix.compact(60 * 3600), "2d")
        XCTAssertEqual(CapacityAffix.compact(-5), "0m")
        XCTAssertEqual(FleetCapacityFormatting.hours(31 * 3600 + 1800), "31 h")
        XCTAssertEqual(FleetCapacityFormatting.hours(50 * 3600), "2 d 2 h")
    }

    func testTooltipCarriesOneLineEachForPoolBurnAndRunway() {
        let accounts = (0..<24).map { i in account("A\(i)", used: i < 6 ? 0 : 100, resetIn: 200) }
        let forecast = FleetCapacity.forecast(accounts: accounts, series: series(count: 12, every: 10, burn: 37),
                                              now: now, calendar: calendar)!
        XCTAssertEqual(forecast.pool, 600)
        let lines = FleetCapacityFormatting.tooltipLines(forecast)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "Weekly pool: 600 of 2400 points (24 accounts)")
        XCTAssertEqual(lines[1], "Burn 37.0 pt/h vs sustainable 14.3 pt/h (2.6×)")
        XCTAssertTrue(lines[2].hasPrefix("Runway: zero "), lines[2])
        XCTAssertTrue(lines[2].contains("(in 16 h)"), lines[2])

        let summary = ProviderSummary.build(provider: .claude, orderedMembers: [UUID()], activeId: nil, readiness: [:],
                                            keyedPercentage: nil, next: nil, preferencesDegraded: false,
                                            activeLastMeasured: nil, now: now)
        let tooltip = StatusBarUIManager.summaryTooltip(summary, activeName: "Atlas", byId: [:], capacity: forecast)
        for line in lines { XCTAssertTrue(tooltip.contains(line), line) }
        XCTAssertFalse(StatusBarUIManager.summaryTooltip(summary, activeName: "Atlas", byId: [:]).contains("Weekly pool"))
    }
}
