//
//  DashboardModelTests.swift
//  Claude UsageTests
//
//  The dashboard snapshot (docs/specs/menubar-redesign.md §3): stacked
//  provider sections with the provider-active account, the next executable
//  target with its verdict age, the queue slice, roster rows with provenance
//  and repair actions, banners and recent switches — and the two config
//  fields stage B reads (`clickSurface`, `ClaudeUsage.provenance`).
//

import XCTest
@testable import Claude_Usage

@MainActor
final class DashboardModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    private func usage(session: Double = 0, weekly: Double = 0, fable: Double? = nil,
                       sessionWindow: Bool = true, age: TimeInterval = 10,
                       provenance: MeasurementProvenance? = nil, sessionElapsed: TimeInterval = 3600) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(Constants.sessionWindow - sessionElapsed)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = now.addingTimeInterval(3 * 86400)
        u.fableWeeklyPercentage = fable
        u.fableWeeklyResetTime = fable == nil ? nil : now.addingTimeInterval(3 * 86400)
        u.hasSessionWindow = sessionWindow ? nil : false
        u.lastUpdated = now.addingTimeInterval(-age)
        u.provenance = provenance
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?, autoSwitch: Bool = true, selected: Bool = true) -> Profile {
        Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org",
                claudeUsage: u, isSelectedForDisplay: selected, includeInAutoSwitch: autoSwitch)
    }

    private func codex(_ name: String, _ u: ClaudeUsage?) -> Profile {
        Profile(name: name, codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
                codexEmail: "\(name)@example.com", claudeUsage: u)
    }

    private func inputs(_ profiles: [Profile], active: Set<UUID>, focused: UUID? = nil,
                        dead: Set<UUID> = [], next: [Profile.ProviderKind: PredictedCandidate] = [:],
                        verdicts: [UUID: PreflightVerdict] = [:], queue: [UUID] = [],
                        history: [SwitchEvent] = [], degraded: Bool = false,
                        hidden: Set<Profile.ProviderKind> = []) -> DashboardSnapshot.Inputs {
        DashboardSnapshot.Inputs(
            profiles: profiles, activeIds: active, focusedId: focused,
            context: FleetSummaryContext(
                thresholds: thresholds,
                isLoginDead: { dead.contains($0.id) },
                isExcluded: { !$0.isAutoSwitchEnabled },
                nextCandidates: next, preflightVerdicts: verdicts,
                preferencesDegraded: degraded, isSwitching: false, now: now
            ),
            queue: queue, history: history, hiddenProviders: hidden
        )
    }

    // MARK: - Sections

    func testSectionsFollowReadingOrderAndOnlyProvidersWithAccounts() {
        let a = claude("A", usage()), x = codex("X", usage(weekly: 10, sessionWindow: false))
        let snap = DashboardSnapshot.build(inputs([x, a], active: [a.id, x.id]))
        XCTAssertEqual(snap.sections.map(\.provider), [.claude, .codex])
        XCTAssertEqual(snap.sections[0].active?.name, "A")
        XCTAssertEqual(snap.sections[1].active?.name, "X")
        XCTAssertNil(snap.sections[1].sessionThreshold, "weekly-only provider fires on weekly only")
        XCTAssertEqual(snap.sections[0].sessionThreshold, 95)
    }

    func testActiveIsTheProviderOwnerNotTheFocusedProfileAndShownEvenWhenDeselected() {
        let owner = claude("Owner", usage(session: 40), selected: false)
        let focused = claude("Focused", usage(session: 10))
        let snap = DashboardSnapshot.build(inputs([owner, focused], active: [owner.id], focused: focused.id))
        let claude = snap.sections[0]
        XCTAssertEqual(claude.active?.name, "Owner")
        XCTAssertFalse(claude.active?.isFocused ?? true)
        XCTAssertEqual(claude.roster.map(\.name), ["Focused"], "the roster is the OTHER accounts")

        let a = self.claude("A", usage()), b = self.claude("B", usage())
        let none = DashboardSnapshot.build(inputs([a, b], active: []))
        XCTAssertNil(none.sections[0].active, "no active login leaves the card empty")
        XCTAssertEqual(Set(none.sections[0].roster.map(\.name)), ["A", "B"])
    }

    // MARK: - Active card

    func testActiveCardGaugesMarkTheFiringThresholdsAndSkipSessionForWeeklyOnly() {
        let a = claude("A", usage(session: 50, weekly: 20, fable: 30))
        let x = codex("X", usage(weekly: 60, sessionWindow: false))
        let snap = DashboardSnapshot.build(inputs([a, x], active: [a.id, x.id]))
        let claudeGauges = snap.sections[0].active!.gauges
        XCTAssertEqual(claudeGauges.map(\.kind), [.session, .weekly, .fable])
        XCTAssertEqual(claudeGauges.map(\.threshold), [95, 99, 99])
        XCTAssertEqual(snap.sections[1].active!.gauges.map(\.kind), [.weekly])
    }

    func testSuspectedActiveCardCarriesTheLastMeasuredValueAndProjectionNeverAStampedHundred() {
        var u = usage(session: 74, weekly: 30, age: 600)
        u.rateLimitedUntil = now.addingTimeInterval(300)
        u.rateLimitedInferred = true
        u.projectedSessionPercentage = 81
        let a = claude("A", u)
        let card = DashboardSnapshot.build(inputs([a], active: [a.id])).sections[0].active!
        XCTAssertEqual(card.suspected?.lastMeasured, 74)
        XCTAssertEqual(card.suspected?.projected, 81)
        XCTAssertEqual(card.gauges.first { $0.kind == .session }?.percentage, 81, "display seam")
        XCTAssertEqual(card.readiness, .suspected)
    }

    func testEtaToThresholdIsLinearFromTheWindowStart() {
        // 50 % after 1 h of a 5 h window → 95 % at 1.9 h → 54 min away.
        let g = WindowGauge(kind: .session, percentage: 50, resetAt: now.addingTimeInterval(4 * 3600),
                            duration: Constants.sessionWindow, threshold: 95)
        XCTAssertEqual(DashboardSnapshot.etaToThreshold(g, now: now)!, 0.9 * 3600, accuracy: 1)
        var slow = g; slow.percentage = 5
        XCTAssertNil(DashboardSnapshot.etaToThreshold(slow, now: now), "will not reach 95 % before the reset")
        var past = g; past.percentage = 96
        XCTAssertEqual(DashboardSnapshot.etaToThreshold(past, now: now), 0)
        var fresh = g; fresh.resetAt = now.addingTimeInterval(Constants.sessionWindow - 30)
        XCTAssertNil(DashboardSnapshot.etaToThreshold(fresh, now: now), "no pace 30 s into the window")
        let a = claude("A", usage(session: 50, sessionElapsed: 3600))
        XCTAssertEqual(DashboardSnapshot.build(inputs([a], active: [a.id])).sections[0].active!.etaToThreshold!, 0.9 * 3600, accuracy: 1)
    }

    // MARK: - Provenance

    func testProvenanceAndAgeTravelWithEveryNumberAndCliCacheIsNotAnOwnMeasurement() {
        let own = claude("Own", usage(age: 28))
        let header = claude("Hdr", usage(age: 120, provenance: .headerRescue))
        let cache = claude("Cache", usage(age: 300, provenance: .cliCache))
        let snap = DashboardSnapshot.build(inputs([own, header, cache], active: [own.id]))
        let card = snap.sections[0].active!
        XCTAssertEqual(card.measurement?.provenance, .ownEndpoint, "nil provenance is the legacy own-endpoint reading")
        XCTAssertEqual(card.measurement?.measuredAt, now.addingTimeInterval(-28))
        let rows = Dictionary(uniqueKeysWithValues: snap.sections[0].roster.map { ($0.name, $0) })
        XCTAssertEqual(rows["Hdr"]?.measurement?.provenance, .headerRescue)
        XCTAssertTrue(rows["Hdr"]!.measurement!.isOwn)
        XCTAssertEqual(rows["Cache"]?.measurement?.provenance, .cliCache)
        XCTAssertFalse(rows["Cache"]!.measurement!.isOwn)
    }

    // MARK: - Next + queue

    func testNextCardCarriesSourceVerdictAgeAndQuotaAge() {
        let a = claude("A", usage(session: 80)), b = claude("B", usage(session: 10, age: 200))
        let verdict = PreflightVerdict(isLive: true, at: now.addingTimeInterval(-700), kind: .probed)
        let snap = DashboardSnapshot.build(inputs(
            [a, b], active: [a.id],
            next: [.claude: PredictedCandidate(id: b.id, label: "B", queued: false, queueHeadBlocked: true)],
            verdicts: [b.id: verdict]
        ))
        let next = snap.sections[0].next!
        XCTAssertEqual(next.name, "B")
        XCTAssertEqual(next.source, .rankedBehindBlockedQueueHead)
        XCTAssertEqual(next.verdict, .verified)
        XCTAssertEqual(next.verdictAt, now.addingTimeInterval(-700))
        XCTAssertEqual(next.quotaMeasuredAt, now.addingTimeInterval(-200))
    }

    func testQueueIsSlicedPerProviderWithPositionsAndBlockedFlags() {
        let a = claude("A", usage()), b = claude("B", usage(session: 99)), c = claude("C", usage())
        let x = codex("X", usage(weekly: 10, sessionWindow: false))
        let snap = DashboardSnapshot.build(inputs([a, b, c, x], active: [a.id, x.id], queue: [x.id, b.id, c.id]))
        let claudeQueue = snap.sections[0].queue
        XCTAssertEqual(claudeQueue.map(\.name), ["B", "C"])
        XCTAssertEqual(claudeQueue.map(\.position), [2, 3], "positions are in the shared queue")
        XCTAssertEqual(claudeQueue.map(\.blocked), [true, false], "B is exhausted")
        XCTAssertEqual(snap.sections[1].queue.map(\.name), ["X"])
        XCTAssertEqual(snap.sections[0].roster.first { $0.name == "C" }?.queuePosition, 3)
    }

    // MARK: - Roster chips and repairs

    func testRosterChipsNameTheBlockerAndDeadLoginsGetARepairAction() {
        var affirmed = usage(session: 10)
        affirmed.rateLimitedUntil = now.addingTimeInterval(1800)
        let rows = [
            claude("Active", usage()),
            claude("Off", usage(), autoSwitch: false),
            claude("Session", usage(session: 96)),
            claude("Weekly", usage(weekly: 99)),
            claude("Fable", usage(fable: 100)),
            claude("Limited", affirmed),
            claude("Dead", usage()),
            claude("Never", nil),
            claude("Near", usage(session: 85)),
        ]
        let x = codex("DeadX", usage(weekly: 1, sessionWindow: false))
        let snap = DashboardSnapshot.build(inputs(rows + [x], active: [rows[0].id], dead: [rows[6].id, x.id]))
        let chips = Dictionary(uniqueKeysWithValues: snap.sections[0].roster.map { ($0.name, $0.chip) })
        XCTAssertEqual(chips["Off"], .autoSwitchOff)
        XCTAssertEqual(chips["Session"], .sessionExhausted(resetAt: usage(session: 96).sessionResetTime))
        XCTAssertEqual(chips["Weekly"], .weeklyMaxed)
        XCTAssertEqual(chips["Fable"], .fableMaxed)
        XCTAssertEqual(chips["Limited"], .rateLimited(until: now.addingTimeInterval(1800)))
        XCTAssertEqual(chips["Dead"], .deadLogin)
        XCTAssertEqual(chips["Never"], .unmeasured)
        XCTAssertEqual(chips["Near"], .nearLimit)
        XCTAssertEqual(snap.sections[0].roster.first { $0.name == "Dead" }?.repair, .claudeLogin)
        XCTAssertEqual(snap.sections[1].roster.first { $0.name == "DeadX" }?.repair, .codexLogin)
        XCTAssertEqual(RepairAction.codexLogin.settingsSectionRawValue, "codexAccount")
        XCTAssertNil(RepairAction.grokLogin.settingsSectionRawValue)
    }

    func testRosterFollowsThePaintedOrderAndAppendsUnpaintedAccountsFirst() {
        let a = claude("A", usage()), b = claude("B", usage()), c = claude("C", usage())
        var inp = inputs([a, b, c], active: [])
        inp.paintedOrder = [.claude: [c.id, a.id]]
        let snap = DashboardSnapshot.build(inp)
        XCTAssertEqual(snap.sections[0].roster.map(\.name), ["B", "C", "A"])
    }

    // MARK: - Banners and history

    func testBannersOrderDegradedThenDeadThenNoCandidateThenOverflow() {
        let a = claude("A", usage(session: 80)), dead = claude("D", usage())
        let snap = DashboardSnapshot.build(inputs([a, dead], active: [a.id], dead: [dead.id], degraded: true, hidden: [.claude]))
        let expected: [DashboardBanner] = [
            .preferencesDegraded, .deadLogins(count: 1), .noCandidate(.claude), .hiddenByOverflow(.claude),
        ]
        XCTAssertEqual(snap.banners, expected)
        XCTAssertTrue(snap.sections[0].hiddenByOverflow)
    }

    func testRecentSwitchesAreNewestFirstCappedAndProviderTagged() {
        let a = claude("A", usage()), x = codex("X", usage(weekly: 1, sessionWindow: false))
        var history: [SwitchEvent] = []
        for i in 0..<8 {
            let at = now.addingTimeInterval(Double(-3600 * (8 - i)))
            let to = i % 2 == 0 ? "A" : "X"
            history.append(SwitchEvent(at: at, from: "B", to: to, trigger: .auto, reason: "r\(i)"))
        }
        let snap = DashboardSnapshot.build(inputs([a, x], active: [a.id, x.id], history: history))
        XCTAssertEqual(snap.recentSwitches.count, 5)
        XCTAssertEqual(snap.recentSwitches.first?.reason, "r7", "newest first")
        XCTAssertEqual(snap.recentSwitches.first?.provider, Profile.ProviderKind.codex)
        XCTAssertEqual(snap.recentSwitches[1].provider, Profile.ProviderKind.claude)
    }

    func testDuplicateAccountGroupsNameEachOthersProfiles() {
        let google = claude("Google", usage()), rir = claude("dRir", usage()), other = claude("Other", usage())
        var inp = inputs([google, rir, other], active: [rir.id])
        inp.duplicateGroups = [[google.id, rir.id]]
        let section = DashboardSnapshot.build(inp).sections[0]
        XCTAssertEqual(section.active?.sameAccountAs, ["Google"])
        XCTAssertEqual(section.roster.first { $0.name == "Google" }?.sameAccountAs, ["dRir"])
        XCTAssertEqual(section.roster.first { $0.name == "Other" }?.sameAccountAs, [])
    }

    // MARK: - Config

    func testClickSurfaceFollowsTheLayoutUnlessChosenAndDecodesCompatibly() throws {
        XCTAssertEqual(MultiProfileDisplayConfig(barLayout: .everyAccount).effectiveClickSurface, .classic)
        XCTAssertEqual(MultiProfileDisplayConfig(barLayout: .fleetDots).effectiveClickSurface, .dashboard)
        XCTAssertEqual(MultiProfileDisplayConfig(barLayout: .fleetDots, clickSurface: .classic).effectiveClickSurface, .classic)
        let legacy = Data("{\"iconStyle\":\"progressBar\",\"showWeek\":true,\"showProfileLabel\":true,\"barLayout\":\"fleetCounts\",\"clickSurface\":\"hologram\"}".utf8)
        let decoded = try JSONDecoder().decode(MultiProfileDisplayConfig.self, from: legacy)
        XCTAssertNil(decoded.clickSurface)
        XCTAssertEqual(decoded.effectiveClickSurface, .dashboard)
        let chosen = MultiProfileDisplayConfig(barLayout: .fleetDots, clickSurface: .classic)
        XCTAssertEqual(try JSONDecoder().decode(MultiProfileDisplayConfig.self, from: JSONEncoder().encode(chosen)), chosen)
    }

    func testProvenanceDecodesAsNilFromLegacyUsageJSON() throws {
        let data = try JSONEncoder().encode(ClaudeUsage.empty)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("provenance"), "nil is omitted, matching pre-redesign blobs")
        XCTAssertNil(try JSONDecoder().decode(ClaudeUsage.self, from: data).provenance)
        XCTAssertTrue(MeasurementProvenance.headerRescue.isOwnMeasurement)
        XCTAssertFalse(MeasurementProvenance.cliCache.isOwnMeasurement)
    }
}
