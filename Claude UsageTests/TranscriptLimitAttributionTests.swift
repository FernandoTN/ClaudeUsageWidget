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
//  2026-09-05 15:47 incident: four transcripts said "You've reached your
//  Fable limit" (no reset in the text) while the owner sat at session 89 % /
//  Fable 100 %; the session read "contradicted" a genuine Fable hit and the
//  fallback stamped it as a session limit with a 30-minute placeholder. The
//  window-aware tests use Tundra (the owner) and Reef (a previous owner).
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

    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    private func resolve(
        reset: Date?,
        window: LimitWindow = .session,
        current: Candidate,
        previous: [Candidate],
        lastSwitchAt: Date?
    ) -> Attribution.Verdict {
        Attribution.resolve(
            eventAt: eventAt, eventResetsAt: reset, window: window,
            currentOwner: current, previousOwners: previous, lastSwitchAt: lastSwitchAt,
            thresholds: thresholds
        )
    }

    /// A candidate with a Fable window beside its session one.
    private func fableCandidate(_ name: String, session: Double, fable: Double?, fableReset: Date? = nil) -> Candidate {
        Candidate(id: UUID(), name: name, sessionResetTime: utc(10, 49, 59), sessionPercentage: session,
                  weeklyResetTime: utc(20, 0, 0), weeklyPercentage: 40,
                  fableWeeklyResetTime: fableReset ?? utc(20, 0, 0), fableWeeklyPercentage: fable)
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
        XCTAssertEqual(resolve(reset: nil, window: .unknown, current: basalt, previous: [cobalt], lastSwitchAt: nil),
                       .currentOwner(basalt, basis: .clock),
                       "an unknown-window event whose text carried no reset cannot be matched")
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
        XCTAssertEqual(Attribution.corroborate(live: live, window: .session, thresholds: thresholds), .confirmed(percent: 96))

        live.sessionPercentage = 22
        XCTAssertEqual(Attribution.corroborate(live: live, window: .session, thresholds: thresholds), .contradicted(percent: 22),
                       "dJormun's own reading in the same second — the event was not its")

        var stamped = live
        stamped.rateLimitedUntil = Date().addingTimeInterval(1800)
        XCTAssertEqual(Attribution.corroborate(live: stamped, window: .session, thresholds: thresholds), .confirmed(percent: 100),
                       "an account-level Retry-After is itself the confirmation")

        XCTAssertEqual(Attribution.corroborate(live: nil, window: .session, thresholds: thresholds), .unavailable)
    }

    // MARK: - Window-aware attribution (2026-09-05 15:47)

    /// The Fable text carries no reset: the owner whose Fable window already
    /// reads at the limit is the one it names — the current owner first,
    /// then a previous one; nobody at the limit falls back to the clock.
    func testFableEventWithoutAResetIsAttributedByWindowState() {
        let tundraOut = fableCandidate("Tundra", session: 89, fable: 100)
        let reefOut = fableCandidate("Reef", session: 30, fable: 100)
        XCTAssertEqual(resolve(reset: nil, window: .fableWeekly, current: tundraOut, previous: [reefOut], lastSwitchAt: nil),
                       .currentOwner(tundraOut, basis: .windowState),
                       "both at the limit: the current owner, because its live read decides")

        let tundraFresh = fableCandidate("Tundra", session: 89, fable: 40)
        XCTAssertEqual(resolve(reset: nil, window: .fableWeekly, current: tundraFresh, previous: [reefOut], lastSwitchAt: switchAt),
                       .previousOwner(reefOut),
                       "the previous owner's Fable window is the exhausted one — even inside the grace")

        let nearLimit = fableCandidate("Reef", session: 30, fable: 97)
        XCTAssertEqual(resolve(reset: nil, window: .fableWeekly, current: tundraFresh, previous: [nearLimit], lastSwitchAt: nil),
                       .previousOwner(nearLimit),
                       "97 % measured a sweep ago clears the 95 % floor under the 99 % weekly threshold")

        let reefFresh = fableCandidate("Reef", session: 30, fable: 40)
        XCTAssertEqual(resolve(reset: nil, window: .fableWeekly, current: tundraFresh, previous: [reefFresh], lastSwitchAt: nil),
                       .currentOwner(tundraFresh, basis: .clock))

        // Only the NAMED window is evidence: a session at 100 % says nothing
        // about a Fable 429, and an account with no Fable window at all is
        // never the one a Fable limit refused.
        let sessionOut = fableCandidate("Tundra", session: 100, fable: 40)
        let noFable = fableCandidate("Reef", session: 100, fable: nil)
        XCTAssertEqual(resolve(reset: nil, window: .fableWeekly, current: sessionOut, previous: [noFable], lastSwitchAt: nil),
                       .currentOwner(sessionOut, basis: .clock))
        XCTAssertEqual(resolve(reset: nil, window: .session, current: sessionOut, previous: [], lastSwitchAt: nil),
                       .currentOwner(sessionOut, basis: .windowState),
                       "the same state names the owner for a SESSION event")
    }

    /// A dated weekly text ("resets Aug 22 at 3pm") is matched against the
    /// owners' WEEKLY stamps; their session stamps do not take part.
    func testResetMatchUsesTheNamedWindowsStamp() {
        let weeklyReset = utc(20, 0, 0)
        let tundra = Candidate(id: UUID(), name: "Tundra", sessionResetTime: weeklyReset, sessionPercentage: 60,
                               weeklyResetTime: utc(21, 30, 0), weeklyPercentage: 50)
        let reef = Candidate(id: UUID(), name: "Reef", sessionResetTime: nil, sessionPercentage: 0,
                             weeklyResetTime: weeklyReset.addingTimeInterval(-1), weeklyPercentage: 100)
        XCTAssertEqual(resolve(reset: weeklyReset, window: .weekly, current: tundra, previous: [reef], lastSwitchAt: nil),
                       .previousOwner(reef),
                       "Tundra's SESSION stamp equals the reset, but the event named the weekly window")
        XCTAssertEqual(resolve(reset: weeklyReset, window: .weekly, current: tundra, previous: [], lastSwitchAt: nil),
                       .unmatched(currentOwner: tundra))
    }

    /// The live read is judged in the window the event named: Fable against
    /// the weekly threshold, and a header rescue — which carries no Fable
    /// window — is no reading at all for a Fable event.
    func testCorroborationReadsTheNamedWindow() {
        var live = ClaudeUsage.empty
        live.sessionResetTime = Date().addingTimeInterval(3600)
        live.sessionPercentage = 89
        live.fableWeeklyPercentage = 100
        live.fableWeeklyResetTime = Date().addingTimeInterval(86_400)
        XCTAssertEqual(Attribution.corroborate(live: live, window: .fableWeekly, thresholds: thresholds), .confirmed(percent: 100))
        XCTAssertEqual(Attribution.corroborate(live: live, window: .session, thresholds: thresholds), .contradicted(percent: 89),
                       "the same reading contradicts a SESSION event — the 15:47 misreading")

        live.fableWeeklyPercentage = 40
        XCTAssertEqual(Attribution.corroborate(live: live, window: .fableWeekly, thresholds: thresholds), .contradicted(percent: 40))

        live.fableWeeklyPercentage = 100
        live.provenance = .headerRescue
        XCTAssertEqual(Attribution.corroborate(live: live, window: .fableWeekly, thresholds: thresholds), .unavailable,
                       "a header-rescued Fable number is the stored one carried forward")
        live.weeklyPercentage = 99
        XCTAssertEqual(Attribution.corroborate(live: live, window: .weekly, thresholds: thresholds), .confirmed(percent: 99),
                       "the headers DO carry the all-models weekly window")

        var noFable = ClaudeUsage.empty
        noFable.fableWeeklyPercentage = nil
        XCTAssertEqual(Attribution.corroborate(live: noFable, window: .fableWeekly, thresholds: thresholds), .unavailable)
    }

    /// The stamp lands on the named window and nowhere else, readiness and
    /// the dashboard's "capacity returns" read it as a Fable hit, and an
    /// event without a reset records no reset — no 30-minute placeholder.
    func testStampingMovesOnlyTheNamedWindow() {
        let now = Date()
        let eventTime = now.addingTimeInterval(-30)
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 89
        usage.fableWeeklyPercentage = 97
        usage.fableWeeklyResetTime = now.addingTimeInterval(2 * 86_400)
        usage.weeklyPercentage = 40

        var fable = usage
        fable.stampLimitHit(.fableWeekly, at: eventTime, resetsAt: nil)
        XCTAssertEqual(fable.fableWeeklyPercentage, 100)
        XCTAssertEqual(fable.sessionPercentage, 89)
        XCTAssertNil(fable.rateLimitedUntil, "a Fable hit is not a session stamp")
        XCTAssertEqual(fable.fableWeeklyResetTime, usage.fableWeeklyResetTime, "no reset in the text: the stored boundary stands")
        XCTAssertEqual(fable.lastUpdated, eventTime)
        XCTAssertEqual(AccountReadiness.classify(usage: fable, isLoginDead: false, isExcluded: false, thresholds: thresholds, now: now),
                       .weeklyHit)
        XCTAssertEqual(DashboardSnapshot.capacityReturnsAt(fable, readiness: .weeklyHit, thresholds: thresholds, now: now),
                       usage.fableWeeklyResetTime, "capacity returns with the FABLE window, not in 30 minutes")

        var session = usage
        session.stampLimitHit(.session, at: eventTime, resetsAt: nil)
        XCTAssertNil(session.rateLimitedUntil, "the 30-minute placeholder is gone")
        XCTAssertEqual(session.sessionPercentage, 100)
        XCTAssertEqual(session.fableWeeklyPercentage, 97)

        let reset = now.addingTimeInterval(3 * 86_400)
        var weekly = usage
        weekly.weeklyResetProjected = true
        weekly.stampLimitHit(.weekly, at: eventTime, resetsAt: reset)
        XCTAssertEqual(weekly.weeklyPercentage, 100)
        XCTAssertEqual(weekly.weeklyResetTime, reset)
        XCTAssertNil(weekly.weeklyResetProjected, "the text's reset is a measured boundary")
    }

    /// Today's 15:47 sequence end to end: the Fable text classifies as a
    /// Fable event, window state names the owner, and its live read —
    /// session 89 %, Fable 100 % — CONFIRMS it. Before this the same read
    /// contradicted it ("live read says 89%").
    func testReplayOfTheFableIncidentIsConfirmedNotContradicted() {
        let text = "You've reached your Fable limit. Run /usage-credits to continue or switch models with /model."
        let window = LocalLimitSignalService.classifyWindow(text)
        XCTAssertEqual(window, .fableWeekly)
        XCTAssertNil(LocalLimitSignalService.parseResetTime(from: text, eventTime: eventAt))

        let tundra = fableCandidate("Tundra", session: 89, fable: 100)
        XCTAssertEqual(resolve(reset: nil, window: window, current: tundra, previous: [], lastSwitchAt: nil),
                       .currentOwner(tundra, basis: .windowState))

        var live = ClaudeUsage.empty
        live.sessionResetTime = Date().addingTimeInterval(3600)
        live.sessionPercentage = 89
        live.fableWeeklyPercentage = 100
        live.fableWeeklyResetTime = Date().addingTimeInterval(86_400)
        XCTAssertEqual(Attribution.corroborate(live: live, window: window, thresholds: thresholds), .confirmed(percent: 100))
    }

    func testInsightsRowNamesTheWindow() {
        let now = Date()
        let contradicted = FleetInsights.Incident(
            at: now.addingTimeInterval(-60), profileId: nil, name: "Tundra", provider: .claude, kind: .tripwire,
            detail: nil, tripwire: .contradicted(livePercent: 40), window: .fableWeekly)
        XCTAssertEqual(InsightsFormatting.incident(contradicted, now: now),
                       "1 m ago · Fable 429 contradicted — live read 40 %, ignored")

        let acted = FleetInsights.Incident(
            at: now.addingTimeInterval(-60), profileId: nil, name: "Tundra", provider: .claude, kind: .tripwire,
            detail: nil, tripwire: .actedOn(basis: "window state", liveRead: "live read Fable 100%"), window: .fableWeekly)
        XCTAssertEqual(InsightsFormatting.incident(acted, now: now),
                       "1 m ago · a running session hit the Fable limit (window state, live read Fable 100%)")

        let weekly = FleetInsights.Incident(
            at: now.addingTimeInterval(-60), profileId: nil, name: "Reef", provider: .claude, kind: .tripwire,
            detail: nil, tripwire: .unmatched, window: .weekly)
        XCTAssertEqual(InsightsFormatting.incident(weekly, now: now),
                       "1 m ago · weekly 429 matches no tracked window — ignored")
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
