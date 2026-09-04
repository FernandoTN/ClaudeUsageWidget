//
//  ActiveSelectorMenuTests.swift
//  Claude UsageTests
//
//  The ⇄ selector's menu model, frame by frame (docs/specs/ux-revamp.md
//  §12.1): the rows each state produces, the badge precedence, the tooltip
//  sentence, the never-suppressible confirmation text, and the setting.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class ActiveSelectorMenuTests: XCTestCase {
    typealias Model = ActiveSelectorMenuModel
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    private func usage(session: Double = 0, weekly: Double = 0, fable: Double? = nil,
                       sessionWindow: Bool = true, age: TimeInterval = 10,
                       weeklyResetIn: TimeInterval = 3 * 86400, suspected: Bool = false,
                       resets: Int? = nil) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(3600)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = now.addingTimeInterval(weeklyResetIn)
        u.fableWeeklyPercentage = fable
        u.fableWeeklyResetTime = fable == nil ? nil : now.addingTimeInterval(weeklyResetIn)
        u.hasSessionWindow = sessionWindow ? nil : false
        u.lastUpdated = now.addingTimeInterval(-age)
        if suspected {
            u.rateLimitedUntil = now.addingTimeInterval(300)
            u.rateLimitedInferred = true
        }
        u.codexResetCreditsAvailable = resets
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?, account: String? = nil) -> Profile {
        Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org",
                claudeAccountUUID: account, claudeUsage: u)
    }

    private func codex(_ name: String, _ u: ClaudeUsage?) -> Profile {
        Profile(name: name, codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
                codexEmail: "\(name)@example.com", claudeUsage: u)
    }

    private func grok(_ name: String, _ u: ClaudeUsage?) -> Profile {
        Profile(name: name, grokCredentialsJSON: "{\"k\":{\"key\":\"x\"}}", grokEmail: "\(name)@x.ai", claudeUsage: u)
    }

    private func selections(_ profiles: [Profile], active: Set<UUID>, dead: Set<UUID> = [],
                            next: [Profile.ProviderKind: PredictedCandidate] = [:],
                            verdicts: [UUID: PreflightVerdict] = [:], switching: Bool = false,
                            degraded: Bool = false, queue: [UUID] = []) -> [ProviderActiveSelection] {
        let context = FleetSummaryContext(
            thresholds: thresholds,
            isLoginDead: { dead.contains($0.id) },
            isExcluded: { !$0.isAutoSwitchEnabled },
            nextCandidates: next, preflightVerdicts: verdicts,
            preferencesDegraded: degraded, isSwitching: switching, now: now)
        return ProviderActiveSelection.build(ProviderActiveSelection.Inputs(
            profiles: profiles, activeIds: active, focusedId: nil, context: context, queue: queue,
            duplicateGroups: FleetCounts.duplicateGroups(in: profiles, published: [])))
    }

    private func predicted(_ profile: Profile) -> [Profile.ProviderKind: PredictedCandidate] {
        [profile.providerKind: PredictedCandidate(id: profile.id, label: String(profile.name.prefix(3)), queued: false, queueHeadBlocked: false)]
    }

    private func rows(_ selections: [ProviderActiveSelection], degraded: Bool = false,
                      external: [Profile.ProviderKind: String] = [:]) -> [Model.Row] {
        Model.rows(selections: selections, preferencesDegraded: degraded, externalChanges: external, switching: nil, now: now)
    }

    private func titles(_ rows: [Model.Row]) -> [String] { rows.map(\.title) }

    // MARK: - Frame 1: healthy

    func testHealthyFrameHasHeaderOwnerEvidenceActionsAndFooter() {
        let owner = claude("dRir", usage(session: 78, weekly: 16, fable: 16, age: 28))
        let next = claude("dJormun", usage(session: 12, weekly: 70, fable: 90, age: 180, weeklyResetIn: 86400))
        let other = claude("Memori", usage(session: 40, weekly: 55))
        let maxed = claude("Commits", usage(session: 10, weekly: 99.5))
        let probedAt = now.addingTimeInterval(-720)
        let sel = selections([owner, next, other, maxed], active: [owner.id],
                             next: [.claude: PredictedCandidate(id: next.id, label: "dJo", queued: false, queueHeadBlocked: false)],
                             verdicts: [next.id: PreflightVerdict(isLive: true, at: probedAt, kind: .probed)])
        let out = rows(sel)

        XCTAssertEqual(out[0].kind, .header)
        XCTAssertEqual(out[0].title, "ACTIVE FOR CLAUDE")
        let ownerRow = out[1]
        XCTAssertEqual(ownerRow.title, "dRir")
        XCTAssertEqual(ownerRow.glyphTint, .cyan)
        XCTAssertTrue(ownerRow.detail?.contains("S 78 % · W 16 % · F 16 %") == true, ownerRow.detail ?? "")
        XCTAssertTrue(ownerRow.detail?.contains("measured 28 s ago") == true, "provenance + age on the owner row")
        XCTAssertFalse(ownerRow.enabled)

        let evidence = out[2]
        XCTAssertEqual(evidence.title, "next → dJormun")
        XCTAssertTrue(evidence.detail?.contains("ranked · ✓ probed 12 m ago · headroom 3 m ago") == true, evidence.detail ?? "")

        let switchNext = out[3]
        XCTAssertEqual(switchNext.title, "Switch Claude to next (dJormun)…")
        XCTAssertEqual(switchNext.action, .switchTo(next.id, .claude))
        XCTAssertTrue(switchNext.enabled)

        let submenu = out[4]
        XCTAssertEqual(submenu.title, "Switch Claude to")
        XCTAssertEqual(titles(submenu.submenu), ["dJormun", "Memori", "", "Commits"], "eligible, separator, blocked")
        if let blocked = submenu.submenu.last {
            XCTAssertFalse(blocked.enabled)
            XCTAssertTrue(blocked.detail?.hasPrefix("weekly maxed") == true, blocked.detail ?? "")
        }

        XCTAssertEqual(out[5].title, "Queue next")
        XCTAssertEqual(titles(out[5].submenu), ["dJormun", "Memori"])
    }

    func testFooterOrderAndNoCountsSentenceWhenHealthy() {
        let owner = claude("dRir", usage(session: 78))
        let other = claude("dJormun", usage(session: 12))
        let out = rows(selections([owner, other], active: [owner.id], next: predicted(other)))
        XCTAssertEqual(Array(titles(out).suffix(6)),
                       ["", "Auto-switch on · 95 % session / 99 % weekly", "Active & Auto-switch…", "Accounts…", "Dashboard…", "Token usage…"])
        XCTAssertFalse(titles(out).contains { $0.contains("profiles,") }, "a healthy group is not told it is healthy")
    }

    func testEligibleRowCarriesAnOptionAlternateThatQueues() {
        let owner = claude("dRir", usage(session: 78))
        let other = claude("dJormun", usage(session: 12))
        let out = rows(selections([owner, other], active: [owner.id], next: predicted(other)))
        let submenu = out.first { $0.title == "Switch Claude to" }!
        let row = submenu.submenu[0]
        XCTAssertEqual(row.action, .switchTo(other.id, .claude))
        XCTAssertEqual(row.alternate?.title, "Queue dJormun next")
        XCTAssertEqual(row.alternate?.action, .queueNext(other.id))
    }

    // MARK: - Frame 2: no candidate, dead logins

    func testNoCandidateFrameShowsRedEvidenceCountsAndRepair() {
        let owner = codex("xFernando", usage(weekly: 95, sessionWindow: false))
        let dead1 = codex("xFenrir", usage(weekly: 10, sessionWindow: false))
        let dead2 = codex("xFho", usage(weekly: 10, sessionWindow: false))
        let maxed = codex("xFme", usage(weekly: 99.5, sessionWindow: false))
        let sel = selections([owner, dead1, dead2, maxed], active: [owner.id], dead: [dead1.id, dead2.id])
        let out = rows(sel)
        let owners = out.first { $0.title == "xFernando" }!
        XCTAssertTrue(owners.detail?.contains("W 95 % · fires at 99 %") == true, owners.detail ?? "")
        XCTAssertTrue(titles(out).contains { $0.hasPrefix("4 Codex profiles, 4 accounts") }, titles(out).joined(separator: " | "))
        let evidence = out.first { $0.glyph == "→" }!
        XCTAssertEqual(evidence.title, "next → — nobody with headroom (2 of 4 dead)")
        XCTAssertEqual(evidence.titleTint, .red)
        XCTAssertFalse(titles(out).contains { $0.hasPrefix("Switch Codex to next") })
        let repair = out.first { $0.title == "Repair 2 dead Codex logins…" }!
        XCTAssertEqual(repair.action, .repairDead(dead1.id, .codex))
        XCTAssertEqual(Model.badge(selections: sel, preferencesDegraded: false), .red)
    }

    func testDeadCandidateRowIsEnabledAsARepair() {
        let owner = claude("dRir", usage(session: 78))
        let ok = claude("dJormun", usage(session: 12))
        let dead = claude("Ai", usage(session: 20))
        let out = rows(selections([owner, ok, dead], active: [owner.id], dead: [dead.id]))
        let submenu = out.first { $0.title == "Switch Claude to" }!
        let deadRow = submenu.submenu.first { $0.title == "Ai" }!
        XCTAssertTrue(deadRow.enabled)
        XCTAssertEqual(deadRow.action, .repairDead(dead.id, .claude))
        XCTAssertEqual(deadRow.detail, "login dead — Repair…")
    }

    // MARK: - Frames 3–8

    func testSingleAccountAndNoOwnerRows() {
        let sole = grok("Grok", usage(weekly: 12, sessionWindow: false))
        let a = claude("dRir", usage(session: 10))
        let b = claude("dJormun", usage(session: 12))
        let out = rows(selections([a, b, sole], active: [sole.id]))
        XCTAssertEqual(out[1].title, "No active Claude login chosen")
        XCTAssertTrue(titles(out).contains("Switch Claude to"))
        let grokHeader = out.firstIndex { $0.title == "ACTIVE FOR GROK" }!
        XCTAssertEqual(out[grokHeader + 1].title, "Grok")
        XCTAssertEqual(out[grokHeader + 2].title, "single account")
    }

    func testSuspectedOwnerShowsLastMeasuredAndPurpleBadge() {
        var u = usage(session: 74, weekly: 30, age: 720, suspected: true)
        u.projectedSessionPercentage = 81
        let owner = claude("Outlook", u)
        let other = claude("dJormun", usage(session: 12))
        let sel = selections([owner, other], active: [owner.id], next: predicted(other))
        let ownerRow = rows(sel)[1]
        XCTAssertEqual(ownerRow.titleTint, .purple)
        XCTAssertTrue(ownerRow.detail?.contains("last measured 74 % · 12 m ago (projection 81 %)") == true, ownerRow.detail ?? "")
        XCTAssertFalse(ownerRow.detail?.contains("100") == true, "never a synthetic 100")
        XCTAssertEqual(Model.badge(selections: sel, preferencesDegraded: false), .purple)
    }

    func testDegradedBannerComesFirstAndSwitchingDisablesActions() {
        let owner = claude("dRir", usage(session: 78))
        let other = claude("dJormun", usage(session: 12))
        let sel = selections([owner, other], active: [owner.id], next: predicted(other), switching: true)
        let out = rows(sel, degraded: true)
        XCTAssertEqual(out[0].kind, .banner)
        XCTAssertEqual(out[0].title, "macOS preferences unavailable — values may be cached")
        for row in out where row.action != nil && row.kind == .action && row.title.hasPrefix("Switch") {
            XCTAssertFalse(row.enabled, row.title)
        }
        XCTAssertEqual(Model.badge(selections: sel, preferencesDegraded: true), .amber)
    }

    func testExternalChangeRowAndResetsRow() {
        let owner = codex("xFernando", usage(weekly: 40, sessionWindow: false, resets: 2))
        let other = codex("xFho", usage(weekly: 10, sessionWindow: false))
        let out = rows(selections([owner, other], active: [owner.id], next: predicted(other)), external: [.codex: "xFme"])
        XCTAssertEqual(out[2].title, "Active for Codex changed outside the app: now xFme")
        XCTAssertEqual(out[2].titleTint, .cyan)
        XCTAssertEqual(out[3].title, "Usage limit resets: 2 available")
        let none = rows(selections([codex("a", usage(weekly: 40, sessionWindow: false)), other], active: []))
        XCTAssertFalse(titles(none).contains { $0.hasPrefix("Usage limit resets") }, "nil count → no row, never \"0\"")
    }

    func testBadgePrecedenceRedOverPurpleOverAmber() {
        let suspected = claude("Outlook", usage(session: 74, suspected: true))
        let deadOwner = codex("xFernando", usage(weekly: 40, sessionWindow: false))
        let other = codex("xFho", usage(weekly: 10, sessionWindow: false))
        let sel = selections([suspected, claude("dJormun", usage(session: 12)), deadOwner, other],
                             active: [suspected.id, deadOwner.id], dead: [deadOwner.id])
        XCTAssertEqual(Model.badge(selections: sel, preferencesDegraded: true), .red)
        let a = claude("dRir", usage(session: 10)), b = claude("dJormun", usage(session: 12))
        let healthy = selections([a, b], active: [a.id], next: predicted(b))
        XCTAssertNil(Model.badge(selections: healthy, preferencesDegraded: false))
    }

    // MARK: - Frame 0: tooltip

    func testTooltipNamesEveryOwnerAndTheFleetCounts() {
        let owner = claude("dRir", usage(session: 78), account: "a")
        let twin = claude("Google", usage(session: 78), account: "a")
        let dead = claude("Ai", usage(session: 5))
        let codexOwner = codex("xFernando", usage(weekly: 95, sessionWindow: false))
        let sel = selections([owner, twin, dead, codexOwner], active: [owner.id, codexOwner.id], dead: [dead.id])
        XCTAssertEqual(Model.tooltip(selections: sel),
                       "Active: Claude dRir 78 % · Codex xFernando 95 % — 4 profiles / 3 accounts · 1 dead · 2 duplicate rows")
    }

    // MARK: - Frame 9: confirmation

    func testConfirmationStatesTheCostTheEvidenceAndWhatTheOwnerKeeps() {
        let owner = claude("dRir", usage(session: 78, weekly: 16))
        let next = claude("dJormun", usage(session: 12, weekly: 70, fable: 99))
        let sel = selections([owner, next], active: [owner.id],
                             verdicts: [next.id: PreflightVerdict(isLive: true, at: now.addingTimeInterval(-720), kind: .probed)])[0]
        let candidate = sel.candidates[0]
        let c = Model.confirmation(provider: .claude, candidate: candidate, owner: sel.owner, now: now)
        XCTAssertEqual(c.title, "Switch the Claude Code login to dJormun?")
        XCTAssertTrue(c.body.contains("Every running Claude Code session re-reads its context on the new account (≈10–15 % of dJormun's window)."), c.body)
        XCTAssertTrue(c.body.contains("dJormun: S 12 % · W 70 % · F 99 % — login verified (probed 12 m ago)."), c.body)
        XCTAssertTrue(c.body.contains("dRir keeps 22 % of its session for another"), c.body)
        XCTAssertFalse(c.risky)
        XCTAssertEqual(c.confirmButton, "Switch now")
    }

    func testConfirmationForAnUnverifiedCandidateIsRisky() {
        let owner = codex("xFernando", usage(weekly: 95, sessionWindow: false))
        let next = codex("xFho", usage(weekly: 10, sessionWindow: false))
        let sel = selections([owner, next], active: [owner.id])[0]
        let c = Model.confirmation(provider: .codex, candidate: sel.candidates[0], owner: sel.owner, now: now)
        XCTAssertEqual(c.title, "Switch the Codex CLI login to xFho?")
        XCTAssertTrue(c.body.contains("its login has not been verified recently — the switch may be refused"), c.body)
        XCTAssertTrue(c.body.contains("xFernando is at 95 % of its weekly window."), c.body)
        XCTAssertTrue(c.risky)
    }

    // MARK: - Setting

    func testSelectorSettingDefaultsToShownAndRoundTrips() {
        let store = SharedDataStore.shared
        XCTAssertTrue(store.loadActiveSelectorItemEnabled(), "absent = shown; hiding is the opt-out")
        store.saveActiveSelectorItemEnabled(false)
        XCTAssertFalse(store.loadActiveSelectorItemEnabled())
        store.saveActiveSelectorItemEnabled(true)
        XCTAssertTrue(store.loadActiveSelectorItemEnabled())
    }
}
