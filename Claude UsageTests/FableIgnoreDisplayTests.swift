//
//  FableIgnoreDisplayTests.swift
//  Claude UsageTests
//
//  `autoSwitchIgnoreFableWeekly` on the DISPLAY side. The preference took the
//  Fable weekly window out of the switch DECISION (AutoSwitchExhaustionTests);
//  readiness kept reading a spent Fable window as exhaustion, so with the flag
//  on the ⇄ menu named a Fable-maxed account `next →` while that same
//  account's row sat in the blocked half reading "Fable weekly maxed", its dot
//  stayed red, and the dashboard filed it under "capacity returns" — and the
//  submenu row, being blocked, could not be clicked at all.
//
//  What every case here is really guarding: the flag must move ONLY the Fable
//  arm. A flag that made everything read ready would look like a working
//  feature while hiding real exhaustion, so overall-weekly and session
//  exhaustion are asserted to survive it, every time.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class FableIgnoreDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func thresholds(ignoreFable: Bool) -> ReadinessThresholds {
        ReadinessThresholds(session: 95, weekly: 99, ignoreFableWeekly: ignoreFable)
    }

    private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    /// Fresh usage with live windows. Defaults are the 2026-09-21 incident's
    /// shape minus the Fable number: plenty of overall weekly left.
    private func usage(session: Double = 10, weekly: Double = 62, fable: Double? = nil,
                       weeklyReset: Date? = nil, fableReset: Date? = nil,
                       sessionReset: Date? = nil) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = sessionReset ?? at(4)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = weeklyReset ?? at(72)
        u.fableWeeklyPercentage = fable
        u.fableWeeklyResetTime = fable == nil ? nil : (fableReset ?? at(72))
        u.lastUpdated = now.addingTimeInterval(-10)
        return u
    }

    private func classify(_ u: ClaudeUsage?, ignoreFable: Bool) -> AccountReadiness {
        AccountReadiness.classify(usage: u, isLoginDead: false, isExcluded: false,
                                  thresholds: thresholds(ignoreFable: ignoreFable), now: now)
    }

    private func claude(_ name: String, _ u: ClaudeUsage?) -> Profile {
        Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org", claudeUsage: u)
    }

    // MARK: - classify

    /// The incident's exact reading: `Stanford`, 62 % of its overall week —
    /// 38 points of usable capacity — with Fable at 100 %.
    func testFableOnlySpentReadsReadyOnlyWhenFableIsIgnored() {
        let fableMaxed = usage(fable: 100)

        // Flag off: unchanged from before this change — light red, blocked.
        XCTAssertEqual(classify(fableMaxed, ignoreFable: false), .weeklyHit)
        XCTAssertTrue(classify(fableMaxed, ignoreFable: false).blocksSwitchTarget)

        // Flag on: the account is serving and is a legal target, so it must
        // not paint as limit-hit.
        XCTAssertFalse(classify(fableMaxed, ignoreFable: true).blocksSwitchTarget)
        XCTAssertFalse(classify(fableMaxed, ignoreFable: true).isAtLimit)
        XCTAssertTrue(classify(fableMaxed, ignoreFable: true).hasHeadroom)
    }

    /// The spent window is dropped from the DECISION, not from the display:
    /// the remaining-Fable shade still reports it. An account with a roomy
    /// overall week reads BRIGHT green on its own and LIGHT green once Fable
    /// is spent — so the owner can still see which accounts have no Fable
    /// left, while none of them is blocked.
    func testIgnoringFableStillShowsTheSpentWindowAsTheLighterShade() {
        XCTAssertEqual(classify(usage(weekly: 20), ignoreFable: true), .ready)
        XCTAssertEqual(classify(usage(weekly: 20, fable: 100), ignoreFable: true), .readyLight)
        XCTAssertEqual(classify(usage(weekly: 20, fable: 10), ignoreFable: true), .ready)
        // Same shade rule on the session-hit side.
        XCTAssertEqual(classify(usage(session: 96, weekly: 20), ignoreFable: true), .sessionHit)
        XCTAssertEqual(classify(usage(session: 96, weekly: 20, fable: 100), ignoreFable: true), .sessionHitLight)
    }

    /// The discriminator. Overall weekly spent is real exhaustion and the flag
    /// must not touch it — with OR without a spent Fable window beside it.
    func testOverallWeeklySpentStaysLimitHitUnderBothFlagStates() {
        for ignore in [false, true] {
            XCTAssertTrue(classify(usage(weekly: 99.5), ignoreFable: ignore).isWeeklyHit,
                          "overall weekly 99.5 ≥ 99 is exhaustion regardless of the Fable policy (ignore: \(ignore))")
            XCTAssertTrue(classify(usage(weekly: 100, fable: 100), ignoreFable: ignore).isWeeklyHit,
                          "both weeklies spent must stay blocked (ignore: \(ignore))")
            XCTAssertTrue(classify(usage(weekly: 99.5), ignoreFable: ignore).blocksSwitchTarget)
        }
        // The shade still means what it meant: a reset within the day is bright.
        XCTAssertEqual(classify(usage(weekly: 100, weeklyReset: at(6)), ignoreFable: true), .weeklyHitSoon)
    }

    /// Session exhaustion likewise survives. With Fable also spent the flag
    /// changes only WHICH window is named — never that a limit is hit.
    func testSessionCappedStaysLimitHitUnderBothFlagStates() {
        for ignore in [false, true] {
            let capped = classify(usage(session: 96), ignoreFable: ignore)
            XCTAssertTrue(capped.isSessionHit, "session 96 ≥ 95 is a session hit (ignore: \(ignore))")
            XCTAssertTrue(capped.blocksSwitchTarget)
        }
        // Session capped AND Fable spent: weekly/Fable outranks the session
        // arm, so ignoring Fable moves the name from weekly to session. Both
        // readings are at a limit — that is the invariant that matters.
        XCTAssertEqual(classify(usage(session: 96, fable: 100), ignoreFable: false), .weeklyHit)
        XCTAssertEqual(classify(usage(session: 96, fable: 100), ignoreFable: true), .sessionHitLight)
        XCTAssertTrue(classify(usage(session: 96, fable: 100), ignoreFable: true).isAtLimit)
    }

    /// The flag drops the Fable arm; it does not invent capacity. An account
    /// with no Fable window at all, or one whose Fable week already rolled
    /// over, classified the same before and must classify the same now.
    func testReadingsFableCannotDecideAreUntouched() {
        for ignore in [false, true] {
            XCTAssertEqual(classify(usage(weekly: 20), ignoreFable: ignore), .ready)
            XCTAssertEqual(classify(usage(), ignoreFable: ignore), .readyLight,
                           "62 % of the week spent leaves 38 %: light green, as it always was")
            XCTAssertEqual(classify(nil, ignoreFable: ignore), .unknown)
            // Fable 100 % on a window that reset an hour ago: full quota again.
            XCTAssertEqual(classify(usage(weekly: 20, fable: 100, fableReset: at(-1)), ignoreFable: ignore), .ready)
        }
    }

    // MARK: - Tile label colour

    /// `isWeeklyMaxed` paints the tile label red. Same split as readiness.
    func testTileLabelIsRedForFableOnlyExhaustionOnlyWhenFableCounts() {
        let fableMaxed = usage(fable: 100)
        XCTAssertTrue(MenuBarManager.isWeeklyMaxed(fableMaxed, weeklyThreshold: 99, now: now),
                      "default is OFF — today's behaviour, byte for byte")
        XCTAssertTrue(MenuBarManager.isWeeklyMaxed(fableMaxed, weeklyThreshold: 99,
                                                   ignoreFableWeekly: false, now: now))
        XCTAssertFalse(MenuBarManager.isWeeklyMaxed(fableMaxed, weeklyThreshold: 99,
                                                    ignoreFableWeekly: true, now: now))

        // Real exhaustion stays red with the flag on.
        XCTAssertTrue(MenuBarManager.isWeeklyMaxed(usage(weekly: 99.5), weeklyThreshold: 99,
                                                   ignoreFableWeekly: true, now: now))
        XCTAssertTrue(MenuBarManager.isWeeklyMaxed(usage(weekly: 100, fable: 100), weeklyThreshold: 99,
                                                   ignoreFableWeekly: true, now: now))
        // A session cap never made a tile maxed (owner spec 2026-07-29).
        XCTAssertFalse(MenuBarManager.isWeeklyMaxed(usage(session: 100), weeklyThreshold: 99,
                                                    ignoreFableWeekly: true, now: now))
    }

    // MARK: - The dashboard's bands and countdowns

    private func section(_ profiles: [Profile], active: UUID?, ignoreFable: Bool) -> ProviderSection {
        let inputs = DashboardSnapshot.Inputs(
            profiles: profiles, activeIds: active.map { [$0] } ?? [], focusedId: nil,
            context: FleetSummaryContext(
                thresholds: thresholds(ignoreFable: ignoreFable),
                isLoginDead: { _ in false },
                isExcluded: { !$0.isAutoSwitchEnabled },
                nextCandidates: [:], preflightVerdicts: [:],
                preferencesDegraded: false, isSwitching: false, now: now),
            queue: [], history: [])
        return DashboardSnapshot.build(inputs).sections.first { $0.provider == .claude }!
    }

    func testFableOnlySpentIsFiledUnderNextUpWhenFableIsIgnored() {
        let owner = claude("Atlas", usage(session: 20, weekly: 30))
        let fableMaxed = claude("Stanford", usage(fable: 100))
        let reallyMaxed = claude("Harbor", usage(weekly: 100))

        let counting = section([owner, fableMaxed, reallyMaxed], active: owner.id, ignoreFable: false)
        let stanfordCounting = counting.roster.first { $0.name == "Stanford" }!
        XCTAssertEqual(stanfordCounting.group, .capacityReturns)
        XCTAssertEqual(stanfordCounting.capacityReturnsAt, at(72))
        XCTAssertEqual(stanfordCounting.weeklyReset?.window, .fable)
        XCTAssertEqual(stanfordCounting.chip, .fableMaxed)

        let ignoring = section([owner, fableMaxed, reallyMaxed], active: owner.id, ignoreFable: true)
        let stanford = ignoring.roster.first { $0.name == "Stanford" }!
        XCTAssertEqual(stanford.group, .nextUp, "the switch will take it, so the roster must not file it under capacity returns")
        XCTAssertNil(stanford.capacityReturnsAt, "nothing is being waited for")
        XCTAssertEqual(stanford.weeklyReset?.window, .weekly,
                       "the countdown names the window the switch still respects")
        XCTAssertEqual(stanford.chip, .readyLight)

        // The genuinely exhausted account is still filed as returning, under
        // the same flag — the band split is not a blanket "everyone is ready".
        let harbor = ignoring.roster.first { $0.name == "Harbor" }!
        XCTAssertEqual(harbor.group, .capacityReturns)
        XCTAssertEqual(harbor.capacityReturnsAt, at(72))
        XCTAssertEqual(harbor.chip, .weeklyMaxed)
    }

    /// `capacityReturnsAt` is the LATEST hit window's reset. A window the
    /// switch ignores is not one capacity waits for: a session-capped account
    /// whose Fable week is also spent comes back when its SESSION resets (4 h),
    /// not when Fable does (72 h).
    func testCapacityReturnsSkipsTheFableBoundaryWhenFableIsIgnored() {
        let capped = usage(session: 100, fable: 100)
        let readiness = classify(capped, ignoreFable: true)
        XCTAssertEqual(
            DashboardSnapshot.capacityReturnsAt(capped, readiness: readiness,
                                                thresholds: thresholds(ignoreFable: true), now: now),
            at(4))
        let counted = classify(capped, ignoreFable: false)
        XCTAssertEqual(
            DashboardSnapshot.capacityReturnsAt(capped, readiness: counted,
                                                thresholds: thresholds(ignoreFable: false), now: now),
            at(72))
    }

    /// The row countdown in isolation, including the case the flag must not
    /// touch: overall weekly spent still counts down the overall boundary.
    func testWeeklyResetCountdownWindowFollowsTheFlag() {
        let fableOnly = usage(fable: 100, fableReset: at(24))
        XCTAssertEqual(DashboardSnapshot.weeklyReset(for: fableOnly, thresholds: thresholds(ignoreFable: false), now: now).window, .fable)
        XCTAssertEqual(DashboardSnapshot.weeklyReset(for: fableOnly, thresholds: thresholds(ignoreFable: true), now: now).window, .weekly)

        let both = usage(weekly: 100, fable: 100, fableReset: at(24))
        for ignore in [false, true] {
            XCTAssertEqual(DashboardSnapshot.weeklyReset(for: both, thresholds: thresholds(ignoreFable: ignore), now: now).window, .weekly,
                           "the all-models weekly is the hit window either way (ignore: \(ignore))")
        }
    }

    // MARK: - The ⇄ submenu: the manual switch path

    private func selections(_ profiles: [Profile], active: Set<UUID>, ignoreFable: Bool) -> [ProviderActiveSelection] {
        let context = FleetSummaryContext(
            thresholds: thresholds(ignoreFable: ignoreFable),
            isLoginDead: { _ in false },
            isExcluded: { !$0.isAutoSwitchEnabled },
            nextCandidates: [:], preflightVerdicts: [:],
            preferencesDegraded: false, isSwitching: false, now: now)
        return ProviderActiveSelection.build(ProviderActiveSelection.Inputs(
            profiles: profiles, activeIds: active, focusedId: nil, context: context, queue: []))
    }

    /// Consequence 2 of the display gap: a blocked candidate's submenu row is
    /// appended with `enabled: false` and no action, so while the flag was
    /// decision-only the owner could not force a switch to exactly the
    /// accounts the flag had just made legal. Eligibility is the fix — no
    /// special case in the menu model.
    func testFableMaxedCandidateRowIsClickableOnlyWhenFableIsIgnored() {
        let owner = claude("Atlas", usage(session: 20, weekly: 30))
        let fableMaxed = claude("Stanford", usage(fable: 100))

        let blocked = selections([owner, fableMaxed], active: [owner.id], ignoreFable: false)
        let blockedClaude = blocked.first { $0.provider == .claude }!
        XCTAssertEqual(blockedClaude.eligibleCandidates.count, 0)
        XCTAssertEqual(blockedClaude.blockedCandidates.map(\.name), ["Stanford"])
        let blockedRow = row(named: "Stanford", in: blocked)
        XCTAssertFalse(blockedRow.enabled)
        XCTAssertNil(blockedRow.action)

        let open = selections([owner, fableMaxed], active: [owner.id], ignoreFable: true)
        let openClaude = open.first { $0.provider == .claude }!
        XCTAssertEqual(openClaude.eligibleCandidates.map(\.name), ["Stanford"])
        XCTAssertEqual(openClaude.candidates.first?.status, .eligible)
        XCTAssertTrue(openClaude.autoSwitch.ignoreFableWeekly,
                      "the policy row's flag and the readiness flag are now one value")
        let openRow = row(named: "Stanford", in: open)
        XCTAssertTrue(openRow.enabled)
        XCTAssertEqual(openRow.action, .switchTo(fableMaxed.id, .claude))
    }

    /// The same submenu must still refuse a genuinely exhausted account while
    /// the flag is on — otherwise the fix would have opened every row.
    func testGenuinelyExhaustedCandidateStaysUnclickableWithFableIgnored() {
        let owner = claude("Atlas", usage(session: 20, weekly: 30))
        let weeklyMaxed = claude("Harbor", usage(weekly: 100))
        let sessionCapped = claude("Fjord", usage(session: 100))

        let open = selections([owner, weeklyMaxed, sessionCapped], active: [owner.id], ignoreFable: true)
        XCTAssertEqual(open.first { $0.provider == .claude }!.eligibleCandidates.count, 0)
        for name in ["Harbor", "Fjord"] {
            let blockedRow = row(named: name, in: open)
            XCTAssertFalse(blockedRow.enabled, "\(name) is really out of capacity")
            XCTAssertNil(blockedRow.action)
        }
    }

    /// The submenu row for `name`, out of the "Switch to ▸" submenu the
    /// selector builds — the rows the owner actually clicks.
    private func row(named name: String, in selections: [ProviderActiveSelection]) -> ActiveSelectorMenuModel.Row {
        let rows = ActiveSelectorMenuModel.rows(selections: selections, preferencesDegraded: false,
                                                externalChanges: [:], switching: nil, now: now)
        let submenu = rows.flatMap(\.submenu)
        guard let match = (submenu + rows).first(where: { $0.title == name }) else {
            XCTFail("no selector row titled \(name)")
            return ActiveSelectorMenuModel.Row(kind: .info, title: name)
        }
        return match
    }

    // MARK: - The settings seam

    /// Every display surface builds its thresholds through `fromSettings()`,
    /// so the owner's flag must arrive on them. Absent still reads OFF.
    func testThresholdsFromSettingsCarryTheOwnersFlag() {
        SharedDataStore.shared.saveAutoSwitchIgnoreFableWeekly(false)
        XCTAssertFalse(ReadinessThresholds.fromSettings().ignoreFableWeekly)

        SharedDataStore.shared.saveAutoSwitchIgnoreFableWeekly(true)
        let live = ReadinessThresholds.fromSettings()
        XCTAssertTrue(live.ignoreFableWeekly)
        XCTAssertEqual(live.session, SharedDataStore.shared.loadAutoSwitchThreshold())
        XCTAssertEqual(live.weekly, SharedDataStore.shared.loadAutoSwitchWeeklyThreshold())

        SharedDataStore.shared.saveAutoSwitchIgnoreFableWeekly(false)
        XCTAssertFalse(ReadinessThresholds.fromSettings().ignoreFableWeekly)
    }

    /// The plain initialiser keeps today's behaviour, which is what makes
    /// every pre-existing test a regression guard for the flag being off.
    func testThresholdsDefaultToCountingFable() {
        XCTAssertFalse(ReadinessThresholds(session: 95, weekly: 99).ignoreFableWeekly)
    }

    override func tearDown() {
        SharedDataStore.shared.saveAutoSwitchIgnoreFableWeekly(false)
        UserDefaults(suiteName: "com.claudeusagewidget.tests")?
            .removeObject(forKey: "autoSwitchIgnoreFableWeekly")
        super.tearDown()
    }
}
