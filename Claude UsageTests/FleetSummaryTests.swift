//
//  FleetSummaryTests.swift
//  Claude UsageTests
//
//  The pure model behind the fleet-summary menu-bar layouts
//  (docs/specs/menubar-redesign.md): one readiness per account, one summary
//  per provider, fixed pixel budgets measured against the real fonts, and a
//  config field that older saved JSON must decode without changing what is
//  on the bar.
//

import AppKit
import XCTest
@testable import Claude_Usage

final class FleetSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    /// Fresh usage with live windows.
    private func usage(session: Double = 0, weekly: Double = 0, fable: Double? = nil,
                       sessionWindow: Bool = true, age: TimeInterval = 10) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(3600)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = now.addingTimeInterval(3 * 86400)
        u.fableWeeklyPercentage = fable
        u.fableWeeklyResetTime = fable == nil ? nil : now.addingTimeInterval(3 * 86400)
        u.hasSessionWindow = sessionWindow ? nil : false
        u.lastUpdated = now.addingTimeInterval(-age)
        return u
    }

    private func classify(_ u: ClaudeUsage?, dead: Bool = false, excluded: Bool = false) -> AccountReadiness {
        AccountReadiness.classify(usage: u, isLoginDead: dead, isExcluded: excluded, thresholds: thresholds, now: now)
    }

    // MARK: - Readiness precedence

    func testDeadOutranksEverythingAndExcludedOutranksCapacity() {
        XCTAssertEqual(classify(usage(session: 99), dead: true, excluded: true), .dead)
        XCTAssertEqual(classify(usage(session: 99), excluded: true), .excluded)
        XCTAssertEqual(classify(nil, dead: true), .dead)
        XCTAssertEqual(classify(nil, excluded: true), .excluded)
    }

    func testMeasuredExhaustionOutranksSuspectedStamp() {
        // Weekly/Fable maxed is a measured fact; a suspected session stamp
        // must not hide it (same precedence as the tile tints).
        var u = usage(session: 40, weekly: 60, fable: 99)
        u.rateLimitedUntil = now.addingTimeInterval(300)
        u.rateLimitedInferred = true
        XCTAssertEqual(classify(u), .weeklyHit, "Fable maxed with the reset days away: light red, blocked")

        var suspected = usage(session: 74, weekly: 60)
        suspected.rateLimitedUntil = now.addingTimeInterval(300)
        suspected.rateLimitedInferred = true
        XCTAssertEqual(classify(suspected), .suspected)
    }

    func testServerAffirmedStampSessionThresholdAndExpiredWindow() {
        var affirmed = usage(session: 10, weekly: 10)
        affirmed.rateLimitedUntil = now.addingTimeInterval(2000)
        XCTAssertEqual(classify(affirmed), .sessionHit, "a server-affirmed stamp is a session hit")
        XCTAssertEqual(classify(usage(session: 95)), .sessionHit)
        XCTAssertEqual(classify(usage(session: 95, weekly: 60)), .sessionHitLight, "session hit with the weekly half gone: faded orange")
        XCTAssertEqual(classify(usage(session: 94.9, weekly: 50)), .readyLight, "session available, weekly at half: light green")
        XCTAssertEqual(classify(usage(session: 94.9, weekly: 49)), .ready)
        var rolled = usage(session: 100, weekly: 10)
        rolled.sessionResetTime = now.addingTimeInterval(-60)
        XCTAssertEqual(classify(rolled), .ready, "an expired session window counts as zero")
    }

    func testWeeklyOnlyProviderIgnoresSessionAndUsesWeeklyRules() {
        XCTAssertEqual(classify(usage(session: 100, weekly: 20, sessionWindow: false)), .ready)
        XCTAssertEqual(classify(usage(weekly: 90, sessionWindow: false)), .readyLight)
        XCTAssertEqual(classify(usage(weekly: 99, sessionWindow: false)), .weeklyHit)
        var soon = usage(weekly: 99, sessionWindow: false)
        soon.weeklyResetTime = now.addingTimeInterval(3600)
        XCTAssertEqual(classify(soon), .weeklyHitSoon, "the reset within a day: bright red")
    }

    func testNoCacheIsUnknownAndOldCacheIsStaleNotUnknown() {
        XCTAssertEqual(classify(nil), .unknown)
        let old = usage(session: 30, weekly: 30, age: 4000)
        XCTAssertEqual(classify(old), .ready)
        XCTAssertTrue(AccountReadiness.isStale(old, thresholds: thresholds, now: now))
        XCTAssertFalse(AccountReadiness.isStale(usage(), thresholds: thresholds, now: now))
        XCTAssertFalse(AccountReadiness.isStale(nil, thresholds: thresholds, now: now))
    }

    // MARK: - Next-candidate verdict

    func testVerdictRequiresAProvingFreshLiveCheck() {
        XCTAssertEqual(NextCandidate.verdict(readiness: .dead, preflight: nil, now: now), .dead)
        XCTAssertEqual(NextCandidate.verdict(readiness: .ready, preflight: nil, now: now), .unverified)
        let probed = PreflightVerdict(isLive: true, at: now.addingTimeInterval(-60), kind: .probed)
        XCTAssertEqual(NextCandidate.verdict(readiness: .ready, preflight: probed, now: now), .verified)
        let expiryOnly = PreflightVerdict(isLive: true, at: now, kind: .expiryOnly)
        XCTAssertEqual(NextCandidate.verdict(readiness: .ready, preflight: expiryOnly, now: now), .unverified,
                       "an expiry check proves nothing about an externally revoked login")
        let old = PreflightVerdict(isLive: true, at: now.addingTimeInterval(-3600), kind: .probed)
        XCTAssertEqual(NextCandidate.verdict(readiness: .ready, preflight: old, now: now), .unverified)
        let failed = PreflightVerdict(isLive: false, at: now, kind: .switched)
        XCTAssertEqual(NextCandidate.verdict(readiness: .ready, preflight: failed, now: now), .dead)
    }

    // MARK: - Provider summary

    private func candidate(_ id: UUID, queued: Bool = false, blocked: Bool = false,
                           readiness: AccountReadiness = .ready,
                           verdict: NextCandidate.Verdict = .verified) -> NextCandidate {
        NextCandidate(id: id, label: "Memori", queued: queued, queueHeadBlocked: blocked,
                      readiness: readiness, verdict: verdict)
    }

    private func build(members: [UUID], active: UUID?, readiness: [UUID: AccountReadiness],
                       keyed: Double?, next: NextCandidate?, switching: Bool = false,
                       degraded: Bool = false, activeMeasured: Date? = nil) -> ProviderSummary {
        ProviderSummary.build(
            provider: .claude, orderedMembers: members, activeId: active, readiness: readiness,
            keyedPercentage: keyed, next: next, isSwitching: switching,
            preferencesDegraded: degraded, activeLastMeasured: activeMeasured, now: now
        )
    }

    func testMembersExcludeTheActiveAccountAndKeepPaintOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let s = build(members: [a, b, c], active: b, readiness: [a: .ready, b: .readyLight, c: .dead],
                      keyed: 10, next: candidate(a), activeMeasured: now)
        XCTAssertEqual(s.members.map(\.id), [a, c])
        XCTAssertEqual(s.members.map(\.readiness), [.ready, .dead])
        XCTAssertEqual(s.activeReadiness, .readyLight)
        XCTAssertEqual(s.counts, [.ready: 1, .dead: 1])
        XCTAssertEqual(s.alert, .deadLogins)
    }

    func testAffixArmsAtSeventyFivePercentOrOnAQueuedTarget() {
        let a = UUID(), active = UUID()
        let idle = build(members: [a, active], active: active, readiness: [:], keyed: 74,
                         next: candidate(a), activeMeasured: now)
        XCTAssertFalse(idle.armed)
        XCTAssertNil(idle.affix)
        XCTAssertNil(idle.activeDigits)

        let armed = build(members: [a, active], active: active, readiness: [:], keyed: 91.4,
                          next: candidate(a), activeMeasured: now)
        XCTAssertEqual(armed.affix, "→Mem")
        XCTAssertEqual(armed.verdictGlyph, "✓")
        XCTAssertEqual(armed.activeDigits, 91)

        let queued = build(members: [a, active], active: active, readiness: [:], keyed: 10,
                           next: candidate(a, queued: true, verdict: .unverified), activeMeasured: now)
        XCTAssertTrue(queued.armed, "a queued hand-off is shown regardless of usage")
        XCTAssertEqual(queued.affix, "→Mem", "the queue state is the arrow's colour, not a letter")
        XCTAssertNil(queued.verdictGlyph, "unverified shows no glyph — the missing check is the information")
    }

    func testBlockedQueueHeadNoCandidateAndSwitchingAffixes() {
        let a = UUID(), active = UUID()
        let fallback = build(members: [a, active], active: active, readiness: [:], keyed: 80,
                             next: candidate(a, blocked: true, verdict: .dead), activeMeasured: now)
        XCTAssertEqual(fallback.affix, "→Mem", "same affix — the renderer paints the arrow red")
        XCTAssertEqual(fallback.verdictGlyph, "×")
        XCTAssertEqual(fallback.alert, .noCandidate, "a dead next candidate is no candidate")

        let none = build(members: [a, active], active: active, readiness: [:], keyed: 80,
                         next: nil, activeMeasured: now)
        XCTAssertEqual(none.affix, "→—")
        XCTAssertNil(none.verdictGlyph)
        XCTAssertEqual(none.alert, .noCandidate)

        let switching = build(members: [a, active], active: active, readiness: [:], keyed: 80,
                              next: candidate(a), switching: true, activeMeasured: now)
        XCTAssertEqual(switching.affix, "⇄")
        XCTAssertNil(switching.verdictGlyph)
    }

    func testNoCandidateIsShownAtAnyUsageAndKeyedPercentageNeverSynthesises100() {
        let a = UUID(), active = UUID()
        let quiet = build(members: [a, active], active: active, readiness: [a: .dead], keyed: 20,
                          next: nil, activeMeasured: now)
        XCTAssertTrue(quiet.armed, "nobody to go to is the group's one fact — shown at 20 %")
        XCTAssertEqual(quiet.affix, "→—")
        XCTAssertEqual(quiet.alert, .noCandidate)
        let alone = build(members: [active], active: active, readiness: [:], keyed: 20,
                          next: nil, activeMeasured: now)
        XCTAssertFalse(alone.armed, "a single-account provider has no fleet row to arm")

        var suspected = usage(session: 74, weekly: 30)
        suspected.rateLimitedUntil = now.addingTimeInterval(300)
        suspected.rateLimitedInferred = true
        XCTAssertEqual(ProviderSummary.keyedDisplayPercentage(suspected), 74,
                       "the last measured value, never the stamp's 100")
        suspected.projectedSessionPercentage = 81
        XCTAssertEqual(ProviderSummary.keyedDisplayPercentage(suspected), 81)
        XCTAssertEqual(ProviderSummary.keyedDisplayPercentage(usage(session: 10, weekly: 60, sessionWindow: false)), 60)
    }

    func testActiveStalenessAndDegradedAlert() {
        let a = UUID(), active = UUID()
        let stale = build(members: [a, active], active: active, readiness: [:], keyed: 10,
                          next: candidate(a), activeMeasured: now.addingTimeInterval(-700))
        XCTAssertTrue(stale.activeIsStale)
        XCTAssertNil(stale.alert)
        let fresh = build(members: [a, active], active: active, readiness: [:], keyed: 10,
                          next: candidate(a), degraded: true, activeMeasured: now)
        XCTAssertFalse(fresh.activeIsStale)
        XCTAssertEqual(fresh.alert, .degraded)
        let noActive = build(members: [a], active: nil, readiness: [:], keyed: nil,
                             next: nil, activeMeasured: nil)
        XCTAssertFalse(noActive.activeIsStale, "no active login is not a stale reading")
        XCTAssertNil(noActive.activeReadiness)
    }

    func testDotOverflowKeepsTheSoonestAccountsAndReservesPlusNColumns() {
        let ids = (0..<25).map { _ in UUID() }
        let s = build(members: ids, active: nil, readiness: [:], keyed: nil, next: nil)
        let (shown, overflow) = s.dotMembers()
        XCTAssertEqual(shown.count, 18)
        XCTAssertEqual(overflow, 7)
        XCTAssertEqual(shown.map(\.id), Array(ids.suffix(18)),
                       "the soonest-reset (rightmost) accounts are the ones kept")
        let small = build(members: Array(ids.prefix(20)), active: nil, readiness: [:], keyed: nil, next: nil)
        XCTAssertEqual(small.dotMembers().overflow, 0)
        XCTAssertEqual(small.dotMembers().shown.count, 20)
        // 18 dots in 9 columns + 2 reserved columns for "+N" = 11 columns,
        // plus the gap between "+N" and the matrix (round 1, B3).
        // 18 dots in 9 columns + 2 reserved columns at a 7 pt pitch with 5 pt dots.
        XCTAssertEqual(FleetBlockGeometry.dotMatrixWidth(memberCount: 25), 75 + FleetBlockGeometry.overflowGap)
        XCTAssertEqual(FleetBlockGeometry.fleetWidth(memberCount: 40, layout: .fleetDots),
                       FleetBlockGeometry.fleetWidth(memberCount: 25, layout: .fleetDots),
                       "fixed once the roster overflows the grid")
    }

    // MARK: - Geometry: widths are fixed per roster + layout, heights follow the active tile

    func testFleetWidthIsFixedAndIndependentOfArming() {
        XCTAssertEqual(FleetBlockGeometry.fleetWidth(memberCount: 0, layout: .fleetDots), 0,
                       "a single-account provider has no fleet block")
        XCTAssertEqual(FleetBlockGeometry.dotGrid(count: 17).columns, 9, "two balanced rows past ten")
        XCTAssertEqual(FleetBlockGeometry.dotGrid(count: 17).rows, 2)
        XCTAssertEqual(FleetBlockGeometry.dotGrid(count: 10).rows, 2, "two rows from four accounts")
        // Two rows from four accounts (owner round B1): 10 → 5 × 2, 17 → 9 × 2.
        XCTAssertEqual(FleetBlockGeometry.dotGrid(count: 3).rows, 1)
        XCTAssertEqual(FleetBlockGeometry.dotGrid(count: 4).rows, 2)
        XCTAssertEqual(FleetBlockGeometry.dotMatrixWidth(memberCount: 10), 33)
        XCTAssertEqual(FleetBlockGeometry.dotMatrixWidth(memberCount: 17), 61)
        // 17 others: mark (10) + max(dots 52, candidate row 52) = 62; arming never widens it.
        XCTAssertEqual(FleetBlockGeometry.fleetWidth(memberCount: 17, layout: .fleetDots), 71, "width follows the count")
        // 2 others: mark (10) + max(dots 10, candidate row 52) = 62 — reserved even while idle.
        XCTAssertEqual(FleetBlockGeometry.fleetWidth(memberCount: 2, layout: .fleetDots), 62)
        XCTAssertEqual(FleetBlockGeometry.fleetWidth(memberCount: 2, layout: .fleetCounts), 82)
        XCTAssertEqual(FleetBlockGeometry.tileWidth(activeWidth: 24, memberCount: 17, layout: .fleetDots), 98)
        XCTAssertEqual(FleetBlockGeometry.tileWidth(activeWidth: 24, memberCount: 0, layout: .fleetDots), 24)
        XCTAssertEqual(FleetBlockGeometry.tileWidth(activeWidth: 24, memberCount: 5, layout: .everyAccount), 24)
        // Heights: the block matches the active tile whenever it fits, so the
        // dot row sits on the tile's bar; two dot rows need the 22 pt tile.
        // Always the full bar height: the mark column carries the account count.
        XCTAssertEqual(FleetBlockGeometry.blockHeight(activeHeight: 16, memberCount: 2, layout: .fleetDots), 22)
        XCTAssertEqual(FleetBlockGeometry.blockHeight(activeHeight: 16, memberCount: 2, layout: .fleetCounts), 22)
        XCTAssertEqual(FleetBlockGeometry.blockHeight(activeHeight: 16, memberCount: 17, layout: .fleetDots), 22)
        XCTAssertEqual(FleetBlockGeometry.blockHeight(activeHeight: 22, memberCount: 5, layout: .fleetDots), 22)
    }

    /// The reserved widths are constants in a Foundation-only model; this
    /// re-measures the widest strings with the fonts the renderer really uses
    /// so a font or notation change cannot silently clip the bar.
    func testReservedWidthsCoverTheRealFonts() {
        func width(_ s: String, _ font: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        let affix = FleetBlockFonts.affix
        // The row is drawn as segments with `candidateGap` between digits,
        // arrow + name, and the glyph (round 1, B2).
        let gaps = 2 * FleetBlockGeometry.candidateGap
        for (digits, name, glyph) in [("99", "WWW", "✓"), ("99", "WWW", "×"), ("99", "WWW", "")] {
            let total = width(digits, affix) + width("→" + name, affix) + width(glyph, affix) + gaps
            XCTAssertLessThanOrEqual(total, FleetBlockGeometry.affixWidth,
                                     "\(digits) →\(name) \(glyph) must fit the reserved candidate row")
        }
        for alone in ["→—", "⇄"] {
            XCTAssertLessThanOrEqual(width(alone, affix), FleetBlockGeometry.affixWidth)
        }
        XCTAssertLessThanOrEqual(width("●99 ◐99 ▲99 ×99", FleetBlockFonts.counts) + 3 * 2,
                                 FleetBlockGeometry.countsWidth)
        for mark in ["Cl", "Cx", "Gk", "19", "99"] {
            XCTAssertLessThanOrEqual(width(mark, FleetBlockFonts.mark) + 1, FleetBlockGeometry.markWidth,
                                     "\(mark) must fit the mark column (the count sits under the mark)")
        }
        XCTAssertLessThanOrEqual(width("+99", FleetBlockFonts.mark),
                                 CGFloat(FleetBlockGeometry.overflowColumns) * FleetBlockGeometry.dotPitch + FleetBlockGeometry.overflowGap,
                                 "+N must fit its two reserved columns and the gap")
    }

    // MARK: - Config compatibility

    func testBarLayoutDecodesRoundTripsAndDefaultsToEveryAccount() throws {
        let legacy = Data("""
        {"iconStyle":"progressBar","showWeek":true,"showProfileLabel":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(MultiProfileDisplayConfig.self, from: legacy)
        XCTAssertEqual(decoded.barLayout, .everyAccount)
        XCTAssertEqual(decoded.iconStyle, .progressBar)

        let future = Data("""
        {"iconStyle":"progressBar","showWeek":true,"showProfileLabel":true,"barLayout":"holographic"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MultiProfileDisplayConfig.self, from: future).barLayout, .everyAccount)

        // The redesigned default (owner decision 2026-09-04) is Active + dots
        // with the click following the layout (= the fleet dashboard); a
        // legacy config decodes unchanged and is moved over exactly once.
        XCTAssertEqual(MultiProfileDisplayConfig.default.barLayout, .fleetDots)
        XCTAssertEqual(MultiProfileDisplayConfig.default.effectiveClickSurface, .dashboard)
        XCTAssertEqual(MenuBarManager.migratedDefaultLayout(decoded)?.barLayout, .fleetDots, "an untouched legacy config moves")
        var touched = decoded
        touched.clickSurface = .classic
        XCTAssertNil(MenuBarManager.migratedDefaultLayout(touched), "a config the user has been in stays")
        XCTAssertNil(MenuBarManager.migratedDefaultLayout(MultiProfileDisplayConfig(iconStyle: .concentric, barLayout: .fleetCounts)),
                     "a fleet layout is already the redesign")
        let config = MultiProfileDisplayConfig(iconStyle: .concentric, barLayout: .fleetDots)
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(MultiProfileDisplayConfig.self, from: data), config)
        XCTAssertTrue(MenuBarLayout.fleetCounts.isFleetSummary)
        XCTAssertFalse(MenuBarLayout.everyAccount.isFleetSummary)
    }
}
