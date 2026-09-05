//
//  DashboardQueueResetTests.swift
//  Claude UsageTests
//
//  The roster's three bands and the weekly countdown every row prints
//  (owner ask 2026-09-04: the three rows under a provider are the accounts
//  coming next AND say when their weekly limit resets): next up in the
//  walk's own order, exhausted accounts by when the walk could take them
//  again, the rest last; the countdown's window (all-models weekly, or
//  Fable when it alone is the exhausted one), the projected mark on a
//  boundary the API never reported, and the clock's wording at its edges.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class DashboardQueueResetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    private func usage(session: Double = 0, weekly: Double = 0, fable: Double? = nil,
                       weeklyReset: Date? = nil, fableReset: Date? = nil, sessionReset: Date? = nil,
                       sessionWindow: Bool = true) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = sessionReset ?? at(4)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = weeklyReset ?? at(49)
        u.fableWeeklyPercentage = fable
        u.fableWeeklyResetTime = fable == nil ? nil : (fableReset ?? at(49))
        u.hasSessionWindow = sessionWindow ? nil : false
        u.lastUpdated = now.addingTimeInterval(-10)
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?, autoSwitch: Bool = true) -> Profile {
        Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org",
                claudeUsage: u, includeInAutoSwitch: autoSwitch)
    }

    private func codex(_ name: String, _ u: ClaudeUsage?) -> Profile {
        Profile(name: name, codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
                codexEmail: "\(name)@example.com", claudeUsage: u)
    }

    private func section(_ profiles: [Profile], active: UUID?, dead: Set<UUID> = [], next: UUID? = nil,
                         queue: [UUID] = [], painted: [UUID]? = nil,
                         provider: Profile.ProviderKind = .claude) -> ProviderSection {
        var inputs = DashboardSnapshot.Inputs(
            profiles: profiles, activeIds: active.map { [$0] } ?? [], focusedId: nil,
            context: FleetSummaryContext(
                thresholds: thresholds,
                isLoginDead: { dead.contains($0.id) },
                isExcluded: { !$0.isAutoSwitchEnabled },
                nextCandidates: next.map {
                    [provider: PredictedCandidate(id: $0, label: "n", queued: queue.contains($0), queueHeadBlocked: false)]
                } ?? [:],
                preflightVerdicts: [:], preferencesDegraded: false, isSwitching: false, now: now),
            queue: queue, history: [])
        if let painted { inputs.paintedOrder = [provider: painted] }
        return DashboardSnapshot.build(inputs).sections.first { $0.provider == provider }!
    }

    private func row(_ section: ProviderSection, _ name: String) -> RosterRow {
        section.roster.first { $0.name == name }!
    }

    // MARK: - Countdown source

    func testCountdownWindowIsTheAllModelsWeeklyUnlessFableAloneIsExhausted() {
        func reset(_ u: ClaudeUsage) -> ResetCountdown { DashboardSnapshot.weeklyReset(for: u, thresholds: thresholds, now: now) }
        XCTAssertEqual(reset(usage(weekly: 30, fable: 20)), ResetCountdown(window: .weekly, resetAt: at(49)))
        XCTAssertEqual(reset(usage(weekly: 30, fable: 100, fableReset: at(77))), ResetCountdown(window: .fable, resetAt: at(77)))
        XCTAssertEqual(reset(usage(weekly: 100, fable: 100, fableReset: at(77))).window, .weekly,
                       "both hit: the all-models boundary is the one every window shares")
        XCTAssertEqual(reset(usage(weekly: 30, fable: 100, fableReset: at(-1))).window, .weekly,
                       "a Fable window that rolled over is full again")
        XCTAssertEqual(reset(usage(weekly: 30, sessionWindow: false)), ResetCountdown(window: .weekly, resetAt: at(49)))
    }

    func testSentinelReadsUnknownAndAPastBoundaryProjectsForwardMarked() {
        func reset(_ u: ClaudeUsage) -> ResetCountdown { DashboardSnapshot.weeklyReset(for: u, thresholds: thresholds, now: now) }
        XCTAssertEqual(reset(usage(weeklyReset: ClaudeUsage.unknownResetSentinel)), ResetCountdown(window: .weekly, resetAt: nil))
        XCTAssertEqual(reset(usage(weeklyReset: at(-30))), ResetCountdown(window: .weekly, resetAt: at(7 * 24 - 30), projected: true),
                       "a boundary behind now is projected a week forward, and says so")
        var flagged = usage()
        flagged.weeklyResetProjected = true
        XCTAssertEqual(reset(flagged), ResetCountdown(window: .weekly, resetAt: at(49), projected: true))
        var fableFlag = usage(weekly: 10, fable: 100)
        fableFlag.fableWeeklyResetProjected = true
        XCTAssertEqual(reset(fableFlag), ResetCountdown(window: .fable, resetAt: at(49), projected: true))
    }

    func testHealingMarksAProjectedBoundaryAndAFreshStampClearsIt() throws {
        var carried = usage(weeklyReset: ClaudeUsage.unknownResetSentinel)
        carried.healMissingResetStamps(previous: usage(weeklyReset: at(-30)), now: now)
        XCTAssertEqual(carried.weeklyResetTime, at(7 * 24 - 30))
        XCTAssertEqual(carried.weeklyResetProjected, true)

        var orphan = usage(weeklyReset: ClaudeUsage.unknownResetSentinel)
        orphan.healMissingResetStamps(previous: nil, now: now)
        XCTAssertEqual(orphan.weeklyResetTime, at(7 * 24))
        XCTAssertEqual(orphan.weeklyResetProjected, true, "a week out with nothing to carry is a guess too")

        var reported = usage(weeklyReset: at(49))
        reported.healMissingResetStamps(previous: carried, now: now)
        XCTAssertNil(reported.weeklyResetProjected, "a reported stamp carries the nil default")

        var fableMissing = usage(weekly: 5, fable: 10)
        fableMissing.fableWeeklyResetTime = nil
        fableMissing.healMissingResetStamps(previous: usage(weekly: 5, fable: 10, fableReset: at(-5)), now: now)
        XCTAssertEqual(fableMissing.fableWeeklyResetTime, at(7 * 24 - 5))
        XCTAssertEqual(fableMissing.fableWeeklyResetProjected, true)

        var header = usage(weeklyReset: at(60))
        header.provenance = .headerRescue
        let merged = carried.mergingHeaderMeasurement(header)
        XCTAssertEqual(merged.weeklyResetTime, at(60))
        XCTAssertNil(merged.weeklyResetProjected, "the header's real 7d-reset stamp supersedes the projection")

        let data = try JSONEncoder().encode(ClaudeUsage.empty)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("ResetProjected"), "nil is omitted, like every added field")
        XCTAssertNil(try JSONDecoder().decode(ClaudeUsage.self, from: data).weeklyResetProjected)
    }

    // MARK: - Bands

    func testRosterBandsAreNextUpThenCapacityReturnsThenNotSwitchable() {
        let owner = claude("Atlas", usage(session: 40))
        let cedar = claude("Cedar", usage(weekly: 16))
        let quarry = claude("Quarry", usage(session: 100, weekly: 40))
        let willow = claude("Willow", usage(weekly: 100))
        let echo = claude("Echo", usage())
        let beacon = claude("Beacon", usage(), autoSwitch: false)
        var suspectedUsage = usage(session: 60)
        suspectedUsage.rateLimitedUntil = at(1)
        suspectedUsage.rateLimitedInferred = true
        let harbor = claude("Harbor", suspectedUsage)
        let juniper = claude("Juniper", nil)
        let s = section([owner, echo, willow, harbor, beacon, quarry, juniper, cedar],
                        active: owner.id, dead: [echo.id], next: cedar.id)
        XCTAssertEqual(s.roster.map(\.group),
                       [.nextUp, .nextUp, .capacityReturns, .capacityReturns, .notSwitchable, .notSwitchable, .notSwitchable])
        XCTAssertEqual(s.roster.prefix(2).map(\.name), ["Cedar", "Juniper"], "an unmeasured account is a legal target, ranked last")
        XCTAssertEqual(s.roster[2...3].map(\.name), ["Quarry", "Willow"], "a session back in 4 h before a week in 2 d")
        XCTAssertEqual(Set(s.roster.suffix(3).map(\.name)), ["Echo", "Harbor", "Beacon"], "dead, suspected, excluded")
    }

    func testNextUpKeepsTheWalkOrderWithThePredictedTargetInFront() {
        let owner = claude("Atlas", usage(session: 40))
        let soon = claude("Cedar", usage(weeklyReset: at(10)))
        let later = claude("Delta", usage(weeklyReset: at(30)))
        let latest = claude("Fjord", usage(weeklyReset: at(50)))
        // No queue: soonest weekly reset first — the countdown never re-sorts.
        var s = section([owner, latest, later, soon], active: owner.id)
        XCTAssertEqual(s.roster.map(\.name), ["Cedar", "Delta", "Fjord"])
        XCTAssertEqual(s.roster.map(\.weeklyReset?.resetAt), [at(10), at(30), at(50)])
        // A queue puts its entries first, in queue order.
        s = section([owner, latest, later, soon], active: owner.id, queue: [latest.id, later.id])
        XCTAssertEqual(s.roster.map(\.name), ["Fjord", "Delta", "Cedar"])
        // The manager's predicted target ran the real walk: it leads whatever the plain rank says.
        s = section([owner, latest, later, soon], active: owner.id, next: later.id)
        XCTAssertEqual(s.roster.map(\.name), ["Delta", "Cedar", "Fjord"])
        XCTAssertTrue(s.roster[0].isNext)
    }

    func testCapacityReturnsAtIsTheLatestHitWindowAndUnknownWhenABoundaryIsMissing() {
        func returns(_ u: ClaudeUsage?, _ readiness: AccountReadiness) -> Date? {
            DashboardSnapshot.capacityReturnsAt(u, readiness: readiness, thresholds: thresholds, now: now)
        }
        XCTAssertEqual(returns(usage(session: 100, weekly: 40, sessionReset: at(2)), .sessionHit), at(2))
        var stamped = usage(session: 20, weekly: 40)
        stamped.rateLimitedUntil = at(0.5)
        XCTAssertEqual(returns(stamped, .sessionHit), at(0.5), "an affirmed stamp on a session with headroom lifts with the stamp")
        var stampedFull = usage(session: 97, weekly: 40, sessionReset: at(3))
        stampedFull.rateLimitedUntil = at(0.5)
        XCTAssertEqual(returns(stampedFull, .sessionHit), at(3), "a full session window keeps it out until the window resets")
        XCTAssertEqual(returns(usage(weekly: 100, fable: 100, weeklyReset: at(20), fableReset: at(70)), .weeklyHitSoon), at(70),
                       "every window must have headroom: the later boundary governs")
        var fableUnknown = usage(weekly: 10, fable: 100)
        fableUnknown.fableWeeklyResetTime = nil
        XCTAssertNil(returns(fableUnknown, .weeklyHit), "a hit window with no boundary is unknown, not soon")
        XCTAssertNil(returns(usage(weekly: 10), .ready))
        XCTAssertNil(returns(nil, .weeklyHit))
    }

    func testCapacityReturnsBandOrdersBySoonestReturnThenNameUnknownLast() {
        let owner = claude("Atlas", usage(session: 40))
        let quarry = claude("Quarry", usage(session: 100, weekly: 40, sessionReset: at(2)))
        let willow = claude("Willow", usage(weekly: 100, weeklyReset: at(19)))
        let fjord = claude("Fjord", usage(weekly: 45, fable: 100, fableReset: at(77)))
        let granite = claude("Granite", usage(weekly: 100, weeklyReset: at(98)))
        var unknownFable = usage(weekly: 10, fable: 100)
        unknownFable.fableWeeklyResetTime = nil
        let harbor = claude("Harbor", unknownFable)
        let s = section([owner, harbor, granite, fjord, willow, quarry], active: owner.id)
        XCTAssertEqual(s.roster.map(\.name), ["Quarry", "Willow", "Fjord", "Granite", "Harbor"])
        XCTAssertEqual(Set(s.roster.map(\.group)), [.capacityReturns])
        XCTAssertEqual(row(s, "Fjord").weeklyReset, ResetCountdown(window: .fable, resetAt: at(77)))
        XCTAssertEqual(row(s, "Harbor").weeklyReset, ResetCountdown(window: .fable, resetAt: nil))
        XCTAssertNil(row(s, "Harbor").capacityReturnsAt)
    }

    func testFillersAreNeverPresentedAsNextUp() {
        let owner = claude("Atlas", usage(session: 40))
        let cedar = claude("Cedar", usage(weekly: 16))
        let quarry = claude("Quarry", usage(session: 100, weekly: 40, sessionReset: at(2)))
        let willow = claude("Willow", usage(weekly: 100, weeklyReset: at(19)))
        let s = section([owner, willow, quarry, cedar], active: owner.id, next: cedar.id, queue: [willow.id])
        let three = Array(s.roster.prefix(3))
        XCTAssertEqual(three.map(\.name), ["Cedar", "Quarry", "Willow"], "one eligible, then the soonest returns fill the three")
        XCTAssertEqual(three.map(\.group), [.nextUp, .capacityReturns, .capacityReturns])
        XCTAssertEqual(three.map(\.isNext), [true, false, false])
        XCTAssertEqual(three[2].queuePosition, 1, "a queued but exhausted account keeps its queue fact; its band says it is not next")
        XCTAssertEqual(three[2].candidateStatus, .blocked(.weeklyHitSoon))
    }

    func testEveryRowCarriesItsCountdownAcrossProviders() {
        let owner = claude("Atlas", usage(session: 40))
        let cedar = claude("Cedar", usage(weeklyReset: at(30)))
        let juniper = claude("Juniper", nil)
        let claudeSection = section([owner, juniper, cedar], active: owner.id)
        XCTAssertEqual(row(claudeSection, "Cedar").weeklyReset, ResetCountdown(window: .weekly, resetAt: at(30)))
        XCTAssertNil(row(claudeSection, "Juniper").weeklyReset, "never measured: nothing to count down")
        let marlin = codex("Marlin", usage(weekly: 1, weeklyReset: at(40), sessionWindow: false))
        let osprey = codex("Osprey", usage(weekly: 95, weeklyReset: at(12), sessionWindow: false))
        let codexSection = section([marlin, osprey], active: marlin.id, provider: .codex)
        XCTAssertEqual(row(codexSection, "Osprey").weeklyReset, ResetCountdown(window: .weekly, resetAt: at(12)))
        XCTAssertEqual(row(codexSection, "Osprey").group, .nextUp, "95 % weekly is under the 99 % threshold")
    }

    func testRosterGroupFallsBackOnReadinessWithoutASelection() {
        XCTAssertEqual(DashboardSnapshot.rosterGroup(status: nil, readiness: .ready), .nextUp)
        XCTAssertEqual(DashboardSnapshot.rosterGroup(status: nil, readiness: .unknown), .nextUp)
        XCTAssertEqual(DashboardSnapshot.rosterGroup(status: nil, readiness: .sessionHitLight), .capacityReturns)
        XCTAssertEqual(DashboardSnapshot.rosterGroup(status: nil, readiness: .suspected), .notSwitchable)
        XCTAssertEqual(DashboardSnapshot.rosterGroup(status: .duplicateOfOwner(ownerName: "Atlas"), readiness: .ready), .notSwitchable)
        XCTAssertEqual(DashboardSnapshot.rosterGroup(status: .blocked(.dead), readiness: .dead), .notSwitchable)
        XCTAssertEqual(DashboardSnapshot.rosterGroup(status: .blocked(.weeklyHit), readiness: .weeklyHit), .capacityReturns)
        XCTAssertEqual(DashboardSnapshot.rosterGroup(status: .excluded(.freePlan), readiness: .excluded), .notSwitchable)
    }

    func testActiveCardGaugesCarryTheProjectedMark() {
        var u = usage(weekly: 20, fable: 30)
        u.weeklyResetProjected = true
        u.fableWeeklyResetProjected = true
        let owner = claude("Atlas", u)
        XCTAssertEqual(section([owner], active: owner.id).active?.gauges.map(\.projected), [false, true, true])
        let plain = section([claude("Cedar", usage(weekly: 20, fable: 30))], active: nil)
        XCTAssertEqual(plain.roster.first?.gauges.map(\.projected), [false, false, false])
    }

    // MARK: - Wording

    func testCountdownWordingAtTheBoundaries() {
        func text(_ seconds: TimeInterval, projected: Bool = false, window: ResetCountdown.Window = .weekly) -> String {
            DashboardFormatting.resetCountdown(
                ResetCountdown(window: window, resetAt: now.addingTimeInterval(seconds), projected: projected), now: now)
        }
        XCTAssertEqual(text(59 * 60), "W resets in 59m")
        XCTAssertEqual(text(3600), "W resets in 1h")
        XCTAssertEqual(text(23 * 3600), "W resets in 23h")
        XCTAssertEqual(text(23 * 3600 + 59 * 60), "W resets in 23h 59m")
        XCTAssertEqual(text(24 * 3600), "W resets in 1 day")
        XCTAssertEqual(text(28 * 3600), "W resets in 1d 4h")
        XCTAssertEqual(text(49 * 3600, projected: true), "W resets in ~2d 1h")
        XCTAssertEqual(text(77 * 3600, window: .fable), "F resets in 3d 5h")
        XCTAssertEqual(text(30), "W resets in < 1m")
        XCTAssertEqual(text(0), "W resets now")
        XCTAssertEqual(DashboardFormatting.resetCountdown(ResetCountdown(window: .weekly, resetAt: nil), now: now), "W reset unknown")
        XCTAssertEqual(DashboardFormatting.resetCountdown(nil, now: now), "")
    }

    func testSessionExhaustedRowPrintsTheBindingResetFirst() {
        let owner = claude("Atlas", usage(session: 40))
        let quarry = claude("Quarry", usage(session: 100, weekly: 40, sessionReset: at(2)))
        let willow = claude("Willow", usage(weekly: 100, weeklyReset: at(19)))
        let cedar = claude("Cedar", usage(weekly: 16))
        let s = section([owner, willow, quarry, cedar], active: owner.id)
        XCTAssertEqual(row(s, "Quarry").sessionReturnsAt, at(2), "the reset the band sorted on")
        XCTAssertNil(row(s, "Willow").sessionReturnsAt, "a weekly-hit row is bound by its weekly window")
        XCTAssertNil(row(s, "Cedar").sessionReturnsAt)
        XCTAssertEqual(DashboardFormatting.resetLine(row(s, "Quarry"), now: now), "S resets in 2h · W in 2d 1h")
        XCTAssertEqual(DashboardFormatting.resetLine(row(s, "Willow"), now: now), "W resets in 19h")
        XCTAssertTrue(DashboardFormatting.resetHelp(row(s, "Quarry"), now: now).hasPrefix("Session window resets "))
        var stamped = usage(session: 20, weekly: 40)
        stamped.rateLimitedUntil = at(0.5)
        let harbor = claude("Harbor", stamped)
        let throttled = section([owner, harbor], active: owner.id)
        XCTAssertEqual(row(throttled, "Harbor").sessionReturnsAt, at(0.5), "an affirmed stamp binds like a full session window")
        XCTAssertEqual(DashboardFormatting.resetLine(row(throttled, "Harbor"), now: now), "S resets in 30m · W in 2d 1h")
    }

    func testResetHelpSpellsOutTheWindowAndTheProvenance() {
        let weekly = DashboardFormatting.resetHelp(ResetCountdown(window: .weekly, resetAt: at(49)), now: now)
        XCTAssertTrue(weekly.hasPrefix("Weekly window resets "), weekly)
        XCTAssertFalse(weekly.contains("Estimated"), weekly)
        let projected = DashboardFormatting.resetHelp(ResetCountdown(window: .fable, resetAt: at(49), projected: true), now: now)
        XCTAssertTrue(projected.hasPrefix("Fable weekly window resets "), projected)
        XCTAssertTrue(projected.contains("Estimated (~)"), projected)
        XCTAssertEqual(DashboardFormatting.resetHelp(ResetCountdown(window: .weekly, resetAt: nil), now: now),
                       "Weekly window: the usage endpoint reported no reset stamp for this account.")
    }

    func testBandLabelsAndRosterHeaderNameTheOrder() {
        XCTAssertEqual(RosterGroup.allCases.map(DashboardFormatting.bandLabel), ["next up", "capacity returns", "not switchable"])
        XCTAssertTrue(RosterGroup.nextUp < .capacityReturns && RosterGroup.capacityReturns < .notSwitchable)
        let owner = claude("Atlas", usage(session: 40))
        let s = section([owner, claude("Cedar", usage())], active: owner.id)
        XCTAssertEqual(DashboardFormatting.rosterHeader(s), "ROSTER · 1 · next up, then soonest reset · 2 eligible now")
    }
}
