//
//  TranscriptLimitAttributionTests.swift
//  Claude UsageTests
//
//  2026-09-04 22:53 incident: the auto-switch moved the CLI login from
//  'dFr(fermin-dev)' to 'dJormun' at 22:52:45; at 22:53:35–40 three of dFr's
//  still-running sessions died on "You've hit your session limit · resets
//  3:40am" (dFr's window, 03:39:59); the widget attributed the event to the
//  new owner by the wall clock, stamped dJormun exhausted while its own
//  endpoint read 22 % in the same second, and switched again at 22:53:45 —
//  abandoning a fresh window and re-reading the whole fleet's context on
//  'Google' (0→58 % in four minutes).
//
//  These tests pin the replacement: attribution by the reset time the event
//  names, a live re-measure of the blamed owner before any switch, and a
//  post-switch grace. Fixture roster: Basalt (current owner), Cobalt (the
//  previous owner), Dune (an older one), Lagoon (a Codex account), Marsh,
//  Quarry.
//

import XCTest
@testable import Claude_Usage

final class TranscriptLimitAttributionTests: XCTestCase {

    private typealias Attribution = TranscriptLimitAttribution
    private typealias Candidate = TranscriptLimitAttribution.Candidate

    // MARK: - Fixtures (the incident's own timestamps, in UTC)

    /// 2026-09-05 hh:mm:ss UTC — the incident night.
    private func utc(_ hour: Int, _ minute: Int, _ second: Int, fraction: Double = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let whole = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: hour, minute: minute, second: second))!
        return whole.addingTimeInterval(fraction)
    }

    /// The moment the third of dFr's sessions died.
    private var eventAt: Date { utc(5, 53, 42) }
    /// "resets 3:40am (America/Los_Angeles)" as `parseResetTime` returns it.
    private var eventReset: Date { utc(10, 40, 0) }
    /// The switch dFr → dJormun, 57 s before the event.
    private var switchAt: Date { utc(5, 52, 45) }

    private func candidate(_ name: String, reset: Date?, session: Double) -> Candidate {
        Candidate(id: UUID(), name: name, sessionResetTime: reset, sessionPercentage: session)
    }

    /// dJormun as the store held it: 22 %, window ends 03:49:59 local.
    /// Stored (not computed): a candidate's identity is its id, and the
    /// expected verdict must carry the same one the resolver was given.
    private lazy var basalt: Candidate = candidate("Basalt", reset: utc(10, 49, 59), session: 22)
    /// dFr as the store held it: 100 %, window ends 03:39:59 local.
    private lazy var cobalt: Candidate = candidate("Cobalt", reset: utc(10, 39, 59), session: 100)

    private func resolve(
        reset: Date?,
        current: Candidate,
        previous: [Candidate],
        lastSwitchAt: Date?
    ) -> Attribution.Verdict {
        Attribution.resolve(
            eventAt: eventAt, eventResetsAt: reset,
            currentOwner: current, previousOwners: previous, lastSwitchAt: lastSwitchAt
        )
    }

    private func switchRow(_ minutesBeforeEvent: Double, from: String, to: String) -> SwitchEvent {
        SwitchEvent(at: eventAt.addingTimeInterval(-minutesBeforeEvent * 60), from: from, to: to, trigger: .auto, reason: nil)
    }

    // MARK: - Attribution by reset match

    /// The regression: today's sequence must attribute the event to the
    /// previous owner and never reach the switch.
    func testReplayOfTheIncidentAttributesTheEventToThePreviousOwner() {
        let verdict = resolve(reset: eventReset, current: basalt, previous: [cobalt], lastSwitchAt: switchAt)
        XCTAssertEqual(verdict, .previousOwner(cobalt),
                       "3:40am is Cobalt's window (03:39:59), not Basalt's (03:49:59)")
    }

    func testResetMatchingTheCurrentOwnerIsAttributedToIt() {
        let verdict = resolve(reset: utc(10, 50, 0), current: basalt, previous: [cobalt], lastSwitchAt: switchAt)
        XCTAssertEqual(verdict, .currentOwner(basalt, basis: .resetMatch))
    }

    /// The server rounds 03:39:59.889 to "3:40am"; the widget's own stamp may
    /// be a header- or cache-derived boundary a few seconds off. ±3 min covers
    /// both, and the edge is exact.
    func testToleranceCoversTheServerRoundingAndStopsAtThreeMinutes() {
        let rounded = candidate("Cobalt", reset: utc(10, 39, 59, fraction: 0.889), session: 100)
        XCTAssertEqual(resolve(reset: eventReset, current: basalt, previous: [rounded], lastSwitchAt: nil),
                       .previousOwner(rounded))

        let justInside = candidate("Cobalt", reset: eventReset.addingTimeInterval(-179), session: 100)
        XCTAssertEqual(resolve(reset: eventReset, current: basalt, previous: [justInside], lastSwitchAt: nil),
                       .previousOwner(justInside))

        let justOutside = candidate("Cobalt", reset: eventReset.addingTimeInterval(-181), session: 100)
        XCTAssertEqual(resolve(reset: eventReset, current: basalt, previous: [justOutside], lastSwitchAt: nil),
                       .unmatched(currentOwner: basalt),
                       "181 s away is a different window; Basalt's measured window disagrees too")
    }

    /// Two accounts whose windows opened within minutes of each other: the
    /// current owner is preferred because its live corroboration decides —
    /// it switches only if that account really is out.
    func testBothWindowsMatchingPrefersTheCurrentOwnerForCorroboration() {
        let nearTwin = candidate("Basalt", reset: utc(10, 40, 30), session: 60)
        XCTAssertEqual(resolve(reset: eventReset, current: nearTwin, previous: [cobalt], lastSwitchAt: nil),
                       .currentOwner(nearTwin, basis: .resetMatch))
    }

    func testTheMostRecentMatchingPreviousOwnerWins() {
        let older = candidate("Dune", reset: utc(10, 40, 10), session: 100)
        let verdict = resolve(reset: eventReset, current: basalt, previous: [cobalt, older], lastSwitchAt: nil)
        XCTAssertEqual(verdict, .previousOwner(cobalt), "the list is most-recent first and the first match is taken")
    }

    // MARK: - The clock is only a fallback

    func testWithoutAnyStampTheEventFallsBackToTheClockOwner() {
        let unmeasured = candidate("Basalt", reset: nil, session: 0)
        let unmeasuredPrevious = candidate("Cobalt", reset: nil, session: 0)
        XCTAssertEqual(resolve(reset: eventReset, current: unmeasured, previous: [unmeasuredPrevious], lastSwitchAt: nil),
                       .currentOwner(unmeasured, basis: .clock))
        XCTAssertEqual(resolve(reset: nil, current: basalt, previous: [cobalt], lastSwitchAt: nil),
                       .currentOwner(basalt, basis: .clock),
                       "an event whose text carried no reset cannot be matched")
    }

    /// A stamp from a window that already rolled over, or a healed boundary
    /// (always paired with 0 %), proves nothing about which account a 429 hit.
    func testStaleOrIdleStampsAreNotEvidence() {
        let rolledOver = candidate("Cobalt", reset: utc(5, 0, 0), session: 100)
        let idle = candidate("Basalt", reset: utc(10, 49, 59), session: 0)
        XCTAssertEqual(resolve(reset: utc(5, 0, 0), current: idle, previous: [rolledOver], lastSwitchAt: nil),
                       .currentOwner(idle, basis: .clock),
                       "the previous owner's stamp is in the event's past; the current owner's pairs with 0 %")
        let healed = candidate("Basalt", reset: eventReset, session: 0)
        XCTAssertEqual(resolve(reset: eventReset, current: healed, previous: [], lastSwitchAt: nil),
                       .currentOwner(healed, basis: .clock),
                       "a matching stamp with no measured usage cannot claim the event either")
    }

    // MARK: - Post-switch grace

    func testInsideTheGraceAnUnmatchedEventIsNeverActionable() {
        let inGrace = resolve(reset: eventReset, current: basalt, previous: [], lastSwitchAt: eventAt.addingTimeInterval(-60))
        XCTAssertEqual(inGrace, .postSwitchGrace(newOwner: basalt))

        let atTheEdge = resolve(reset: eventReset, current: basalt, previous: [], lastSwitchAt: eventAt.addingTimeInterval(-Attribution.postSwitchGrace))
        XCTAssertEqual(atTheEdge, .unmatched(currentOwner: basalt), "the grace is half-open: exactly 120 s is outside it")

        let later = resolve(reset: eventReset, current: basalt, previous: [], lastSwitchAt: eventAt.addingTimeInterval(-130))
        XCTAssertEqual(later, .unmatched(currentOwner: basalt))
    }

    func testInsideTheGraceAnEventWithoutAResetIsNeverActionable() {
        XCTAssertEqual(resolve(reset: nil, current: basalt, previous: [], lastSwitchAt: eventAt.addingTimeInterval(-30)),
                       .postSwitchGrace(newOwner: basalt))
        XCTAssertEqual(resolve(reset: nil, current: basalt, previous: [], lastSwitchAt: eventAt.addingTimeInterval(-600)),
                       .currentOwner(basalt, basis: .clock))
    }

    // MARK: - Switch-history helpers

    func testPreviousOwnersComeFromTheLookbackMostRecentFirstWithoutRepeatsOrOtherProviders() {
        let history = [
            switchRow(-1, from: "Basalt", to: "Quarry"),      // after the event — not a previous owner
            switchRow(3, from: "Lagoon", to: "Lagoon-2"),    // Codex row in the shared ring
            switchRow(5, from: "Cobalt", to: "Basalt"),
            switchRow(8, from: "Cobalt", to: "Marsh"),       // a repeat
            switchRow(12, from: "Dune", to: "Cobalt"),
            switchRow(20, from: "Marsh", to: "Dune")         // outside the 15-minute lookback
        ]
        let names = Attribution.previousOwnerNames(
            history: history, eventTime: eventAt,
            claudeProfileNames: ["Basalt", "Cobalt", "Dune", "Marsh", "Quarry"],
            excluding: "Basalt"
        )
        XCTAssertEqual(names, ["Cobalt", "Dune"])
    }

    func testTheGraceClockIsTheLastClaudeSwitchAtOrBeforeTheEvent() {
        let history = [
            switchRow(-1, from: "Basalt", to: "Quarry"),
            switchRow(1, from: "Lagoon", to: "Lagoon-2"),
            switchRow(5, from: "Cobalt", to: "Basalt"),
            switchRow(12, from: "Dune", to: "Cobalt")
        ]
        let claude: Set<String> = ["Basalt", "Cobalt", "Dune", "Quarry"]
        XCTAssertEqual(Attribution.lastClaudeSwitchAt(history: history, before: eventAt, claudeProfileNames: claude),
                       eventAt.addingTimeInterval(-5 * 60),
                       "the Codex switch a minute ago and the Claude switch after the event are not the clock")
        XCTAssertNil(Attribution.lastClaudeSwitchAt(history: [], before: eventAt, claudeProfileNames: claude))
    }

    // MARK: - Live corroboration

    func testCorroborationConfirmsContradictsOrIsUnavailable() {
        var live = ClaudeUsage.empty
        live.sessionResetTime = Date().addingTimeInterval(3600)
        live.sessionPercentage = 96
        XCTAssertEqual(Attribution.corroborate(live: live, sessionThreshold: 95), .confirmed(sessionPercent: 96))

        live.sessionPercentage = 22
        XCTAssertEqual(Attribution.corroborate(live: live, sessionThreshold: 95), .contradicted(sessionPercent: 22),
                       "dJormun's own reading in the same second — the event was not its")

        var stamped = live
        stamped.rateLimitedUntil = Date().addingTimeInterval(1800)
        XCTAssertEqual(Attribution.corroborate(live: stamped, sessionThreshold: 95), .confirmed(sessionPercent: 100),
                       "an account-level Retry-After is itself the confirmation")

        XCTAssertEqual(Attribution.corroborate(live: nil, sessionThreshold: 95), .unavailable)
    }

    // MARK: - Dashboard row

    func testInsightsRowSaysWhatBecameOfTheEvent() {
        let now = Date()
        let previous = FleetInsights.Incident(
            at: now.addingTimeInterval(-60), profileId: nil, name: "Cobalt", provider: .claude, kind: .tripwire,
            detail: nil, tripwire: .previousOwner(currentOwner: "Basalt"))
        XCTAssertEqual(InsightsFormatting.incident(previous, now: now),
                       "1 m ago · 429 from the previous owner — ignored, Basalt kept the login")

        let contradicted = FleetInsights.Incident(
            at: now.addingTimeInterval(-60), profileId: nil, name: "Basalt", provider: .claude, kind: .tripwire,
            detail: nil, tripwire: .contradicted(livePercent: 22))
        XCTAssertEqual(InsightsFormatting.incident(contradicted, now: now),
                       "1 m ago · session 429 contradicted — live read 22 %, ignored")

        let acted = FleetInsights.Incident(
            at: now.addingTimeInterval(-60), profileId: nil, name: "Basalt", provider: .claude, kind: .tripwire,
            detail: nil, tripwire: .actedOn(basis: "reset match", liveRead: "live read 97%"))
        XCTAssertEqual(InsightsFormatting.incident(acted, now: now),
                       "1 m ago · a running session hit the limit (reset match, live read 97%)")

        let legacy = FleetInsights.Incident(
            at: now.addingTimeInterval(-60), profileId: nil, name: "Basalt", provider: .claude, kind: .tripwire, detail: nil)
        XCTAssertEqual(InsightsFormatting.incident(legacy, now: now), "1 m ago · a running session hit the limit",
                       "rows recorded before the attribution existed keep the old wording")
    }
}
