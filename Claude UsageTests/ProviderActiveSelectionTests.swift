//
//  ProviderActiveSelectionTests.swift
//  Claude UsageTests
//
//  The pure model behind the per-provider ACTIVE selector and the fleet
//  counts (docs/specs/ux-revamp.md §2.1, §3): the owner is the provider
//  pointer's account, never the viewed one; candidates are ordered eligible
//  first in the walk's rank order; duplicates of the owner and excluded
//  accounts are never eligible; counts partition the rows and dedupe
//  accounts; the "next account" hotkey views within the provider group.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class ProviderActiveSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    private func usage(session: Double = 0, weekly: Double = 0, fable: Double? = nil,
                       sessionWindow: Bool = true, age: TimeInterval = 10,
                       weeklyResetIn: TimeInterval = 3 * 86400,
                       provenance: MeasurementProvenance? = nil) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(3600)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = now.addingTimeInterval(weeklyResetIn)
        u.fableWeeklyPercentage = fable
        u.fableWeeklyResetTime = fable == nil ? nil : now.addingTimeInterval(weeklyResetIn)
        u.hasSessionWindow = sessionWindow ? nil : false
        u.lastUpdated = now.addingTimeInterval(-age)
        u.provenance = provenance
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?, account: String? = nil,
                        autoSwitch: Bool = true) -> Profile {
        Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org",
                claudeAccountUUID: account, claudeUsage: u, includeInAutoSwitch: autoSwitch)
    }

    private func codex(_ name: String, _ u: ClaudeUsage?, account: String? = nil) -> Profile {
        Profile(name: name, codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
                codexEmail: "\(name)@example.com", codexAccountId: account, claudeUsage: u)
    }

    private func context(dead: Set<UUID> = [], freePlan: Set<UUID> = [],
                         next: [Profile.ProviderKind: PredictedCandidate] = [:],
                         verdicts: [UUID: PreflightVerdict] = [:],
                         switching: Bool = false) -> FleetSummaryContext {
        FleetSummaryContext(
            thresholds: thresholds,
            isLoginDead: { dead.contains($0.id) },
            isExcluded: { !$0.isAutoSwitchEnabled || freePlan.contains($0.id) },
            nextCandidates: next,
            preflightVerdicts: verdicts,
            preferencesDegraded: false,
            isSwitching: switching,
            now: now
        )
    }

    private func inputs(_ profiles: [Profile], active: Set<UUID>, viewing: UUID? = nil,
                        context: FleetSummaryContext? = nil, queue: [UUID] = [],
                        duplicates: [[UUID]]? = nil, pinned: Set<UUID> = [],
                        needsRelogin: Set<UUID> = []) -> ProviderActiveSelection.Inputs {
        ProviderActiveSelection.Inputs(
            profiles: profiles, activeIds: active, focusedId: viewing,
            context: context ?? self.context(), queue: queue,
            duplicateGroups: duplicates ?? FleetCounts.duplicateGroups(in: profiles, published: []),
            manuallyPinned: pinned, needsRelogin: needsRelogin
        )
    }

    private func selection(_ built: [ProviderActiveSelection], _ provider: Profile.ProviderKind) -> ProviderActiveSelection {
        built.first { $0.provider == provider }!
    }

    // MARK: - Owner vs Viewing

    func testOwnerIsTheProviderActiveAccountNeverTheViewedOne() {
        let owner = claude("dRir", usage(session: 78, weekly: 16))
        let viewed = claude("dJormun", usage(session: 12, weekly: 70))
        let built = ProviderActiveSelection.build(inputs([owner, viewed], active: [owner.id], viewing: viewed.id,
                                                         pinned: [owner.id]))
        let claude = selection(built, .claude)
        XCTAssertEqual(claude.owner?.id, owner.id)
        XCTAssertEqual(claude.owner?.keyedPercentage, 78)
        XCTAssertTrue(claude.owner?.isManuallyPinned == true)
        XCTAssertEqual(claude.viewing, viewed.id)
        XCTAssertEqual(claude.candidates.map(\.id), [viewed.id], "the owner is never its own candidate")
    }

    func testNoOwnerAndNobodyToGoToRaisesTheNoCandidateAlert() {
        let a = claude("Commits", usage(session: 10, weekly: 99.5))
        let b = claude("BBR", usage(session: 99, weekly: 40))
        let built = ProviderActiveSelection.build(inputs([a, b], active: []))
        let claude = selection(built, .claude)
        XCTAssertNil(claude.owner)
        XCTAssertNil(claude.next)
        XCTAssertEqual(claude.alert, .noCandidate)
        XCTAssertTrue(claude.eligibleCandidates.isEmpty)
        XCTAssertEqual(claude.blockedCandidates.count, 2)
    }

    // MARK: - Candidates

    func testEligibleCandidatesComeFirstInRankOrderThenBlocked() {
        let owner = claude("dRir", usage(session: 78))
        let soon = claude("dJormun", usage(session: 12, weekly: 70, weeklyResetIn: 86400))
        let later = claude("Memori", usage(session: 40, weekly: 55, weeklyResetIn: 5 * 86400))
        let maxed = claude("Commits", usage(session: 10, weekly: 99.5, weeklyResetIn: 3600))
        let exhausted = claude("BBR", usage(session: 99, weekly: 40, weeklyResetIn: 7200))
        let built = ProviderActiveSelection.build(inputs([owner, later, maxed, soon, exhausted], active: [owner.id]))
        let rows = selection(built, .claude).candidates
        XCTAssertEqual(rows.map(\.name), ["dJormun", "Memori", "Commits", "BBR"],
                       "eligible in soonest-weekly-reset order, then the blocked rows in rank order")
        XCTAssertEqual(rows[0].status, .eligible)
        XCTAssertEqual(rows[2].status, .blocked(.weeklyHitSoon), "weekly maxed, reset within a day")
        XCTAssertEqual(rows[3].status, .blocked(.sessionHit), "session hit with more than half the week left")
    }

    func testQueuedCandidatesRankFirstAndCarryTheirPosition() {
        let owner = claude("dRir", usage(session: 78))
        let soon = claude("dJormun", usage(session: 12, weeklyResetIn: 86400))
        let queued1 = claude("Memori", usage(session: 40, weeklyResetIn: 5 * 86400))
        let queued2 = claude("2026", usage(session: 3, weeklyResetIn: 6 * 86400))
        let built = ProviderActiveSelection.build(inputs([owner, soon, queued1, queued2], active: [owner.id],
                                                         queue: [queued1.id, queued2.id]))
        let claude = selection(built, .claude)
        XCTAssertEqual(claude.candidates.map(\.name), ["Memori", "2026", "dJormun"])
        XCTAssertEqual(claude.candidates[0].queuePosition, 1)
        XCTAssertEqual(claude.candidates[1].queuePosition, 2)
        XCTAssertNil(claude.candidates[2].queuePosition)
        XCTAssertEqual(claude.queue.map(\.name), ["Memori", "2026"])
    }

    func testDuplicateOfTheOwnerIsNeverEligible() {
        let owner = claude("dRir", usage(session: 78), account: "acct-1")
        let twin = claude("Google", usage(session: 78), account: "acct-1")
        let other = claude("dJormun", usage(session: 12), account: "acct-2")
        let built = ProviderActiveSelection.build(inputs([owner, twin, other], active: [owner.id],
                                                         needsRelogin: [twin.id]))
        let claude = selection(built, .claude)
        let twinRow = claude.candidates.first { $0.id == twin.id }!
        XCTAssertEqual(twinRow.status, .duplicateOfOwner(ownerName: "dRir"))
        XCTAssertTrue(twinRow.needsRelogin)
        XCTAssertEqual(claude.eligibleCandidates.map(\.id), [other.id])
        XCTAssertEqual(claude.owner?.sameAccountAs, ["Google"])
    }

    func testExcludedSplitsTheUserToggleFromAFreePlanLogin() {
        let owner = claude("dRir", usage(session: 78))
        let off = claude("Ass", usage(session: 5), autoSwitch: false)
        let free = claude("Stanford", usage(session: 93))
        let ctx = context(freePlan: [free.id])
        let built = ProviderActiveSelection.build(inputs([owner, off, free], active: [owner.id], context: ctx))
        let claude = selection(built, .claude)
        XCTAssertEqual(claude.candidates.first { $0.id == off.id }?.status, .excluded(.autoSwitchOff))
        XCTAssertEqual(claude.candidates.first { $0.id == free.id }?.status, .excluded(.freePlan))
        XCTAssertEqual(claude.counts.excludedByToggle, 1)
        XCTAssertEqual(claude.counts.freePlan, 1)
    }

    func testNeverMeasuredAccountIsEligibleAndDeadOneCarriesARepair() {
        let owner = claude("dRir", usage(session: 78))
        let unknown = claude("Hotmail", nil)
        let dead = claude("Ai", usage(session: 20))
        let ctx = context(dead: [dead.id])
        let built = ProviderActiveSelection.build(inputs([owner, unknown, dead], active: [owner.id], context: ctx))
        let claude = selection(built, .claude)
        let unknownRow = claude.candidates.first { $0.id == unknown.id }!
        XCTAssertEqual(unknownRow.status, .eligible)
        XCTAssertEqual(unknownRow.readiness, .unknown)
        XCTAssertEqual(unknownRow.verdict, .unverified)
        let deadRow = claude.candidates.first { $0.id == dead.id }!
        XCTAssertEqual(deadRow.status, .blocked(.dead))
        XCTAssertEqual(deadRow.verdict, .dead)
        XCTAssertEqual(deadRow.repair, .claudeLogin)
    }

    func testNextCandidateCarriesItsVerdictKindAndAgeAsTwoAxes() {
        let owner = claude("dRir", usage(session: 78))
        let next = claude("dJormun", usage(session: 12, age: 180))
        let probedAt = now.addingTimeInterval(-720)
        let ctx = context(
            next: [.claude: PredictedCandidate(id: next.id, label: "dJo", queued: false, queueHeadBlocked: false)],
            verdicts: [next.id: PreflightVerdict(isLive: true, at: probedAt, kind: .probed)]
        )
        let built = ProviderActiveSelection.build(inputs([owner, next], active: [owner.id], context: ctx))
        let claude = selection(built, .claude)
        XCTAssertEqual(claude.next?.id, next.id)
        XCTAssertEqual(claude.next?.verdict, .verified)
        let row = claude.candidates[0]
        XCTAssertTrue(row.isNext)
        XCTAssertEqual(row.verdictKind, .probed)
        XCTAssertEqual(row.verdictAt, probedAt)
        XCTAssertEqual(row.measurement?.measuredAt, now.addingTimeInterval(-180), "quota age is its own axis")
    }

    // MARK: - Counts

    func testCountsPartitionTheRowsAndKeepDuplicatesOrthogonal() {
        let owner = claude("dRir", usage(session: 78, weekly: 16), account: "acct-1")
        let twin = claude("Google", usage(session: 78, weekly: 16), account: "acct-1")
        let low = claude("Stanford", usage(session: 85))
        let maxed = claude("Commits", usage(weekly: 99.5))
        let unknown = claude("Hotmail", nil)
        let dead = claude("Ai", usage(), account: "acct-3")
        let profiles = [owner, twin, low, maxed, unknown, dead]
        let ctx = context(dead: [dead.id])
        let built = ProviderActiveSelection.build(inputs(profiles, active: [owner.id], context: ctx))
        let counts = selection(built, .claude).counts

        XCTAssertEqual(counts.profiles, 6)
        XCTAssertEqual(counts.byReadiness.values.reduce(0, +), 6, "the seven states partition the rows")
        XCTAssertEqual(counts.count(.ready), 3, "session available with the week untouched is bright green, whatever the session reads")
        XCTAssertEqual(counts.count(.weeklyHit), 1)
        XCTAssertEqual(counts.count(.unknown), 1)
        XCTAssertEqual(counts.count(.dead), 1)
        XCTAssertEqual(counts.duplicateProfiles, 2, "orthogonal — the twins are also two ready rows")
        XCTAssertEqual(counts.strip, "6 · ●3 ▲1 ○1 ×1 · ⧉2")
    }

    func testDistinctAccountsLoginLiveAndCapacityCountEachAccountOnce() {
        let owner = claude("dRir", usage(weekly: 20, age: 5), account: "acct-1")
        let twin = claude("Google", usage(weekly: 60, age: 600), account: "acct-1")
        let other = claude("dJormun", usage(weekly: 70), account: "acct-2")
        let dead = claude("Ai", usage(weekly: 0), account: "acct-3")
        let ctx = context(dead: [dead.id])
        let built = ProviderActiveSelection.build(inputs([owner, twin, other, dead], active: [owner.id], context: ctx))
        let counts = selection(built, .claude).counts
        XCTAssertEqual(counts.profiles, 4)
        XCTAssertEqual(counts.distinctAccounts, 3)
        XCTAssertEqual(counts.loginLive, 2, "the dead account is not live; the twins are one account")
        XCTAssertEqual(counts.capacityRemaining, 80 + 30, accuracy: 0.001,
                       "one quota per account, read from the freshest live measurement (20 %, not the stale 60 %)")
    }

    func testEligibleIncludesUnknownWhileMeasuredHeadroomDoesNot() {
        let owner = claude("dRir", usage(session: 78))
        let ready = claude("dJormun", usage(session: 12))
        let low = claude("Stanford", usage(session: 85))
        let unknown = claude("Hotmail", nil)
        let built = ProviderActiveSelection.build(inputs([owner, ready, low, unknown], active: [owner.id]))
        let counts = selection(built, .claude).counts
        XCTAssertEqual(counts.measuredHeadroom, 3, "owner + ready + low")
        XCTAssertEqual(counts.autoSwitchEligible, 4, "the walk accepts a never-measured account")
    }

    func testCodexDuplicateGroupsAreDerivedFromTheAccountIdStamp() {
        let a = codex("xFernando", usage(weekly: 95, sessionWindow: false), account: "c-1")
        let b = codex("xFenrir", usage(weekly: 10, sessionWindow: false), account: "c-1")
        let c = codex("xFho", usage(weekly: 10, sessionWindow: false), account: "c-2")
        let claudeTwins = [UUID(), UUID()]
        let groups = FleetCounts.duplicateGroups(in: [a, b, c], published: [claudeTwins])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0], claudeTwins)
        XCTAssertEqual(Set(groups[1]), Set([a.id, b.id]))

        let built = ProviderActiveSelection.build(inputs([a, b, c], active: [a.id], duplicates: groups))
        let codex = selection(built, .codex)
        XCTAssertEqual(codex.counts.distinctAccounts, 2)
        XCTAssertEqual(codex.candidates.first { $0.id == b.id }?.status, .duplicateOfOwner(ownerName: "xFernando"))
        XCTAssertEqual(codex.eligibleCandidates.map(\.id), [c.id])
    }

    // MARK: - Viewing navigation (the hotkey)

    func testNextViewedAccountWrapsWithinTheOrderAndIsNilOutsideIt() {
        let a = UUID(), b = UUID(), c = UUID(), stranger = UUID()
        XCTAssertEqual(ViewingNavigation.next(after: a, in: [a, b, c]), b)
        XCTAssertEqual(ViewingNavigation.next(after: c, in: [a, b, c]), a, "wraps")
        XCTAssertNil(ViewingNavigation.next(after: stranger, in: [a, b, c]), "not in the group")
        XCTAssertNil(ViewingNavigation.next(after: a, in: [a]), "nothing else to view")
    }

    // MARK: - Vocabulary

    func testVocabularyNamesTheProviderAndNeverSaysActiveAlone() {
        XCTAssertEqual(ActiveVocabulary.viewing, "Viewing")
        XCTAssertEqual(ActiveVocabulary.activeFor(.claude), "Active for Claude")
        XCTAssertEqual(ActiveVocabulary.makeActive(.codex), "Make active for Codex…")
        XCTAssertEqual(ActiveVocabulary.viewingLine(viewing: "dJormun", provider: .claude, owner: "dRir"),
                       "Viewing dJormun · Active for Claude: dRir")
        XCTAssertEqual(ActiveVocabulary.viewingLine(viewing: "Grok", provider: .grok, owner: nil),
                       "Viewing Grok · no active Grok login")
        XCTAssertEqual(ActiveVocabulary.changedOutside(.claude, newOwner: "dLeo"),
                       "Active for Claude changed outside the app: now dLeo")
        let owner = claude("dRir", usage(session: 78), account: "a")
        let twin = claude("Google", usage(session: 78), account: "a")
        let unknown = claude("Hotmail", nil)
        let counts = selection(ProviderActiveSelection.build(inputs([owner, twin, unknown], active: [owner.id])), .claude).counts
        XCTAssertEqual(ActiveVocabulary.countsSentence(counts),
                       "3 Claude profiles, 2 accounts: 2 ready, 1 unmeasured · 2 duplicate rows · 3 eligible now")
    }
}
