//
//  DashboardNextSwitchTests.swift
//  Claude UsageTests
//
//  The dashboard header's "switch to the next account now" button: its
//  target is the Claude section's predicted next candidate from the
//  snapshot (never another provider's, never a second ranking), and its
//  four states — ready, blocked / dead, no candidate, switching — are a pure
//  function of that snapshot. Plus the header's width with the fourth
//  button: the left column's lines must still fit beside four 28 pt icons.
//

import AppKit
import SwiftUI
import XCTest
@testable import Claude_Usage

@MainActor
final class DashboardNextSwitchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    private func usage(session: Double = 0, weekly: Double = 0, now: Date? = nil) -> ClaudeUsage {
        let now = now ?? self.now
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(Constants.sessionWindow - 3600)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = now.addingTimeInterval(3 * 86400)
        u.lastUpdated = now.addingTimeInterval(-10)
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?) -> Profile {
        Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org", claudeUsage: u)
    }

    private func codex(_ name: String, _ u: ClaudeUsage?) -> Profile {
        Profile(name: name, codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
                codexEmail: "\(name)@example.com", claudeUsage: u)
    }

    private func snapshot(_ profiles: [Profile], active: Set<UUID>,
                          next: [Profile.ProviderKind: PredictedCandidate] = [:],
                          dead: Set<UUID> = [], verdicts: [UUID: PreflightVerdict] = [:],
                          isSwitching: Bool = false, history: [SwitchEvent] = [],
                          now: Date? = nil) -> DashboardSnapshot {
        DashboardSnapshot.build(DashboardSnapshot.Inputs(
            profiles: profiles, activeIds: active, focusedId: nil,
            context: FleetSummaryContext(
                thresholds: thresholds,
                isLoginDead: { dead.contains($0.id) },
                isExcluded: { !$0.isAutoSwitchEnabled },
                nextCandidates: next, preflightVerdicts: verdicts,
                preferencesDegraded: false, isSwitching: isSwitching, now: now ?? self.now
            ),
            queue: [], history: history
        ))
    }

    private func ranked(_ p: Profile, queued: Bool = false, queueHeadBlocked: Bool = false) -> PredictedCandidate {
        PredictedCandidate(id: p.id, label: p.menuBarDisplayName, queued: queued, queueHeadBlocked: queueHeadBlocked)
    }

    // MARK: - Ready

    func testHealthyClaudeCandidateIsEnabledAndTheTooltipNamesIt() {
        let atlas = claude("Atlas", usage(session: 96)), cedar = claude("Cedar (dev)", usage(weekly: 16))
        let snap = snapshot([atlas, cedar], active: [atlas.id], next: [.claude: ranked(cedar)])
        let action = NextSwitchAction.make(snapshot: snap)
        XCTAssertEqual(action.state, .ready)
        XCTAssertTrue(action.isEnabled)
        XCTAssertFalse(action.showsProgress)
        XCTAssertEqual(action.target, cedar.id)
        XCTAssertEqual(action.name, "Cedar (dev)", "the full profile name, not the bar's 3-letter label")
        XCTAssertEqual(action.help, "Switch Claude now to Cedar (dev) — next in line")
    }

    func testQueuedCandidateSaysItComesFromTheQueue() {
        let atlas = claude("Atlas", usage()), delta = claude("Delta", usage(weekly: 23))
        let queued = NextSwitchAction.make(snapshot: snapshot([atlas, delta], active: [atlas.id],
                                                              next: [.claude: ranked(delta, queued: true)]))
        XCTAssertTrue(queued.isEnabled)
        XCTAssertEqual(queued.target, delta.id)
        XCTAssertEqual(queued.help, "Switch Claude now to Delta — next in your queue")

        let fallback = NextSwitchAction.make(snapshot: snapshot([atlas, delta], active: [atlas.id],
                                                                next: [.claude: ranked(delta, queueHeadBlocked: true)]))
        XCTAssertTrue(fallback.isEnabled)
        XCTAssertTrue(fallback.help.contains("queue head is blocked"), fallback.help)
    }

    // MARK: - Blocked or dead

    func testDeadCandidateIsDisabledAndSaysToLogInFirst() {
        let atlas = claude("Atlas", usage()), echo = claude("Echo", usage(weekly: 10))
        // Dead by readiness (the login flag).
        let byReadiness = NextSwitchAction.make(snapshot: snapshot([atlas, echo], active: [atlas.id],
                                                                   next: [.claude: ranked(echo)], dead: [echo.id]))
        XCTAssertEqual(byReadiness.state, .blocked)
        XCTAssertFalse(byReadiness.isEnabled)
        XCTAssertEqual(byReadiness.target, echo.id, "disabled, not hidden: the target is still named")
        XCTAssertTrue(byReadiness.help.contains("login is dead"), byReadiness.help)
        XCTAssertTrue(byReadiness.help.contains("Log in again first"), byReadiness.help)

        // Dead by the preflight verdict alone (a recent failed check), while
        // the readiness still reads ready.
        let verdict = PreflightVerdict(isLive: false, at: now.addingTimeInterval(-60), kind: .probed)
        let snap = snapshot([atlas, echo], active: [atlas.id], next: [.claude: ranked(echo)], verdicts: [echo.id: verdict])
        XCTAssertEqual(snap.sections[0].next?.readiness, .ready)
        XCTAssertEqual(snap.sections[0].next?.verdict, .dead)
        let byVerdict = NextSwitchAction.make(snapshot: snap)
        XCTAssertEqual(byVerdict.state, .blocked)
        XCTAssertFalse(byVerdict.isEnabled)
        XCTAssertTrue(byVerdict.help.contains("Log in again first"), byVerdict.help)
    }

    func testCandidateWithoutHeadroomIsDisabledWithTheReason() {
        let atlas = claude("Atlas", usage()), harbor = claude("Harbor", usage(weekly: 100))
        let snap = snapshot([atlas, harbor], active: [atlas.id], next: [.claude: ranked(harbor)])
        XCTAssertEqual(snap.sections[0].next?.readiness.blocksSwitchTarget, true)
        let action = NextSwitchAction.make(snapshot: snap)
        XCTAssertEqual(action.state, .blocked)
        XCTAssertFalse(action.isEnabled)
        XCTAssertTrue(action.help.hasPrefix("Harbor is next in line, but its weekly or Fable limit is hit"), action.help)
    }

    // MARK: - No candidate

    func testNoClaudeCandidateIsDisabledWithTheNoCandidateHelp() {
        let atlas = claude("Atlas", usage()), cedar = claude("Cedar", usage())
        let noNext = NextSwitchAction.make(snapshot: snapshot([atlas, cedar], active: [atlas.id]))
        XCTAssertEqual(noNext.state, .noCandidate)
        XCTAssertNil(noNext.target)
        XCTAssertFalse(noNext.isEnabled)
        XCTAssertEqual(noNext.help, "No Claude account to switch to right now")

        let loading = NextSwitchAction.make(snapshot: nil)
        XCTAssertEqual(loading.state, .noCandidate)
        XCTAssertFalse(loading.isEnabled)
    }

    /// The mistake most likely to pass review unnoticed: a Codex (or Grok)
    /// candidate must never become the Claude button's target.
    func testNeverTargetsAnotherProvidersCandidate() {
        let kestrel = codex("Kestrel", usage(weekly: 10)), marlin = codex("Marlin", usage(weekly: 1))
        let codexOnly = snapshot([kestrel, marlin], active: [kestrel.id], next: [.codex: ranked(marlin)])
        XCTAssertEqual(codexOnly.sections.map(\.provider), [.codex])
        XCTAssertEqual(codexOnly.sections[0].next?.candidateId, marlin.id, "the Codex section does have a next")
        let action = NextSwitchAction.make(snapshot: codexOnly)
        XCTAssertNil(action.target)
        XCTAssertNil(action.name)
        XCTAssertEqual(action.state, .noCandidate)
        XCTAssertFalse(action.isEnabled)

        // Both providers present, Claude has nobody: still no target.
        let atlas = claude("Atlas", usage())
        let mixed = snapshot([atlas, kestrel, marlin], active: [atlas.id, kestrel.id], next: [.codex: ranked(marlin)])
        XCTAssertNil(NextSwitchAction.make(snapshot: mixed).target)

        // Both have one: the Claude one wins, whatever the section order.
        let cedar = claude("Cedar", usage())
        let both = snapshot([kestrel, marlin, atlas, cedar], active: [atlas.id, kestrel.id],
                            next: [.codex: ranked(marlin), .claude: ranked(cedar)])
        XCTAssertEqual(NextSwitchAction.make(snapshot: both).target, cedar.id)
    }

    // MARK: - Switching

    func testSwitchInFlightDisablesAndShowsProgress() {
        let atlas = claude("Atlas", usage()), cedar = claude("Cedar", usage())
        // Any switch the snapshot reports (the flag is global).
        let busy = NextSwitchAction.make(snapshot: snapshot([atlas, cedar], active: [atlas.id],
                                                            next: [.claude: ranked(cedar)], isSwitching: true))
        XCTAssertEqual(busy.state, .switching)
        XCTAssertFalse(busy.isEnabled)
        XCTAssertTrue(busy.showsProgress)

        // This button's own task, before the snapshot catches up; it names
        // the account it is switching to even if the snapshot's next moved.
        let idle = snapshot([atlas, cedar], active: [atlas.id], next: [.claude: ranked(cedar)])
        let own = NextSwitchAction.make(snapshot: idle, switchingTo: "Cedar")
        XCTAssertEqual(own.state, .switching)
        XCTAssertFalse(own.isEnabled, "a second click must not start a second switch")
        XCTAssertTrue(own.showsProgress)
        XCTAssertEqual(own.help, "Switching Claude to Cedar…")
    }

    // MARK: - Outcome note

    func testOutcomeNoteReusesTheSharedWordingAndColoursFailures() {
        let ok = HeaderSwitchNote(outcome: .activated, name: "Cedar")
        XCTAssertEqual(ok.text, DashboardFormatting.outcome(.activated, name: "Cedar", provider: .claude))
        XCTAssertEqual(ok.role, .ready)
        let dead = HeaderSwitchNote(outcome: .credentialsRefused, name: "Echo")
        XCTAssertTrue(dead.text.contains("login is dead"))
        XCTAssertEqual(dead.role, .blocking)
        XCTAssertGreaterThan(dead.lifetime, ok.lifetime, "a failure stays long enough to act on")
        XCTAssertEqual(HeaderSwitchNote(outcome: .switchInFlight, name: "Echo").role, .informational)
    }

    // MARK: - Header layout with four buttons

    /// Four 28 pt buttons take 112 of the 380 pt (84 before). Measured, not
    /// assumed: the header's IDEAL width — every line on one line, untruncated
    /// — must fit the dashboard, and at 380 pt it must be no taller than its
    /// ideal (a wrap would add a line).
    func testHeaderWithFourButtonsFitsTheDashboardWidthWithoutTruncating() {
        // Ages come from the wall clock in the header, so the fixture is
        // anchored there; "23 h 59 m ago" is the longest hours form, and
        // "Iris → Atlas (dev)" is the live-shaped fixture's last switch.
        let wall = Date()
        var profiles = [claude("Atlas (dev)", usage(now: wall)), claude("Cedar", usage(now: wall))]
        profiles += (1...22).map { claude("Acct \($0)", usage(now: wall)) }
        let snap = snapshot(profiles, active: [profiles[0].id], next: [.claude: ranked(profiles[1])],
                            history: [SwitchEvent(at: wall.addingTimeInterval(-(23 * 3600 + 59 * 60)),
                                                  from: "Iris", to: "Atlas (dev)", trigger: .auto, reason: nil)],
                            now: wall.addingTimeInterval(-59))
        XCTAssertEqual(snap.accountCount, 24)
        XCTAssertNotNil(snap.recentSwitches.first)

        for nextSwitch in [NextSwitchAction.make(snapshot: snap), NextSwitchAction.make(snapshot: snap, switchingTo: "Cedar")] {
            let header = DashboardHeader(title: "Fleet", snapshot: snap, isRefreshing: false, nextSwitch: nextSwitch,
                                         onRefresh: {}, onNextSwitch: { _ in }, onTokenUsage: {}, onSettings: {})
            let ideal = NSHostingView(rootView: header.fixedSize()).fittingSize
            let atWidth = NSHostingView(rootView: header.frame(width: DashboardSurface.dashboardSize.width)).fittingSize
            XCTAssertLessThanOrEqual(ideal.width, DashboardSurface.dashboardSize.width,
                                     "header wants \(ideal.width) pt untruncated; the dashboard is \(DashboardSurface.dashboardSize.width)")
            XCTAssertEqual(atWidth.height, ideal.height, accuracy: 0.5, "no line wraps at the dashboard width")
        }
    }
}
