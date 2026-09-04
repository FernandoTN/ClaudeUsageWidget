//
//  AccountsRosterModelTests.swift
//  Claude UsageTests
//
//  The Accounts inspector's roster model and the typed Settings route
//  (docs/specs/ux-revamp.md §2.2, §5.4; design pass §12.2): rows carry one
//  badge, the keyed percentage and the filter words; the bar order is the
//  walk's rank with the owner first; the filter matches names, emails and
//  state words; routes decode both the legacy string and the typed payload.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class AccountsRosterModelTests: XCTestCase {
    typealias Model = AccountsRosterModel
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    private func usage(session: Double = 0, weekly: Double = 0, fable: Double? = nil,
                       sessionWindow: Bool = true, age: TimeInterval = 10,
                       weeklyResetIn: TimeInterval = 3 * 86400) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(3600)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = now.addingTimeInterval(weeklyResetIn)
        u.fableWeeklyPercentage = fable
        u.fableWeeklyResetTime = fable == nil ? nil : now.addingTimeInterval(weeklyResetIn)
        u.hasSessionWindow = sessionWindow ? nil : false
        u.lastUpdated = now.addingTimeInterval(-age)
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?, email: String? = nil, account: String? = nil,
                        autoSwitch: Bool = true) -> Profile {
        Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org",
                claudeAccountUUID: account, claudeAccountEmail: email, claudeUsage: u, includeInAutoSwitch: autoSwitch)
    }

    private func codex(_ name: String, _ u: ClaudeUsage?) -> Profile {
        Profile(name: name, codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
                codexEmail: "\(name)@example.com", claudeUsage: u)
    }

    private func selections(_ profiles: [Profile], active: Set<UUID>, dead: Set<UUID> = [],
                            next: Profile? = nil, queue: [UUID] = [],
                            verdicts: [UUID: PreflightVerdict] = [:]) -> [ProviderActiveSelection] {
        var predicted: [Profile.ProviderKind: PredictedCandidate] = [:]
        if let next {
            predicted[next.providerKind] = PredictedCandidate(id: next.id, label: String(next.name.prefix(3)), queued: false, queueHeadBlocked: false)
        }
        let context = FleetSummaryContext(
            thresholds: thresholds, isLoginDead: { dead.contains($0.id) }, isExcluded: { !$0.isAutoSwitchEnabled },
            nextCandidates: predicted, preflightVerdicts: verdicts, preferencesDegraded: false, isSwitching: false, now: now)
        return ProviderActiveSelection.build(ProviderActiveSelection.Inputs(
            profiles: profiles, activeIds: active, focusedId: nil, context: context, queue: queue,
            duplicateGroups: FleetCounts.duplicateGroups(in: profiles, published: [])))
    }

    private func rows(_ sections: [Model.Section], _ provider: Profile.ProviderKind) -> [Model.Row] {
        sections.first { $0.provider == provider }?.rows ?? []
    }

    // MARK: - Rows and badges

    func testOwnerFirstInBarOrderThenTheWalkRank() {
        let owner = claude("dRir", usage(session: 78, weeklyResetIn: 5 * 86400))
        let soon = claude("dJormun", usage(session: 12, weeklyResetIn: 86400))
        let later = claude("Memori", usage(session: 40, weeklyResetIn: 4 * 86400))
        let maxed = claude("Commits", usage(weekly: 99.5, weeklyResetIn: 2 * 86400))
        let profiles = [later, maxed, owner, soon]
        let sections = Model.sections(selections: selections(profiles, active: [owner.id]), profiles: profiles, sort: .bar, filter: "")
        XCTAssertEqual(rows(sections, .claude).map(\.name), ["dRir", "dJormun", "Commits", "Memori"],
                       "owner first, then soonest weekly reset first — blocked rows keep their rank, unlike the selector's eligible-first menu")
        XCTAssertEqual(rows(sections, .claude)[0].badge, .activeFor(.claude))
        XCTAssertEqual(rows(sections, .claude)[0].badge.mark, "Cl")
    }

    func testAlphabeticalSortAndSectionHeaderText() {
        let a = claude("Zed", usage(session: 1), account: "x")
        let b = claude("alpha", usage(session: 2), account: "x")
        let c = claude("Mid", usage(session: 3))
        let sections = Model.sections(selections: selections([a, b, c], active: [a.id]), profiles: [a, b, c], sort: .alphabetical, filter: "")
        XCTAssertEqual(rows(sections, .claude).map(\.name), ["alpha", "Mid", "Zed"])
        let section = sections[0]
        XCTAssertEqual(section.title, "CLAUDE")
        XCTAssertEqual(section.subtitle, "3 profiles · 2 accounts")
        XCTAssertEqual(section.strip, "3 · ●3 · ⧉2")
    }

    func testBadgesQueuedNextDuplicateExcludedByPrecedence() {
        let owner = claude("dRir", usage(session: 78), account: "a")
        let twin = claude("Google", usage(session: 78), account: "a")
        let next = claude("dJormun", usage(session: 12))
        let queued = claude("Memori", usage(session: 40))
        let off = claude("Ass", usage(session: 5), autoSwitch: false)
        let profiles = [owner, twin, next, queued, off]
        let sel = selections(profiles, active: [owner.id], next: next, queue: [queued.id],
                             verdicts: [next.id: PreflightVerdict(isLive: true, at: now, kind: .probed)])
        let byName = Dictionary(uniqueKeysWithValues: rows(Model.sections(selections: sel, profiles: profiles, sort: .bar, filter: ""), .claude).map { ($0.name, $0) })
        XCTAssertEqual(byName["Memori"]?.badge, .queued(position: 1))
        XCTAssertEqual(byName["Memori"]?.badge.mark, "Q1")
        XCTAssertEqual(byName["dJormun"]?.badge, .next(.verified))
        XCTAssertEqual(byName["dJormun"]?.badge.mark, "✓")
        XCTAssertEqual(byName["Google"]?.badge, .duplicate(of: "dRir"))
        XCTAssertEqual(byName["Ass"]?.badge, .excluded(.autoSwitchOff))
        XCTAssertEqual(byName["Ass"]?.badge.mark, "off")
    }

    func testPercentageTextIsKeyedPerProviderAndMarksTheMaxedWindow() {
        let claudeOwner = claude("dRir", usage(session: 78, weekly: 20))
        let sessionMaxed = claude("BBR", usage(session: 99, weekly: 40))
        let fableMaxed = claude("Commits", usage(session: 10, weekly: 50, fable: 99.5))
        let never = claude("Hotmail", nil)
        let codexOwner = codex("xFernando", usage(weekly: 95, sessionWindow: false))
        let codexMaxed = codex("xFme", usage(weekly: 99.5, sessionWindow: false))
        let profiles = [claudeOwner, sessionMaxed, fableMaxed, never, codexOwner, codexMaxed]
        let sections = Model.sections(selections: selections(profiles, active: [claudeOwner.id, codexOwner.id]), profiles: profiles, sort: .alphabetical, filter: "")
        let all = Dictionary(uniqueKeysWithValues: sections.flatMap(\.rows).map { ($0.name, $0.percentageText) })
        XCTAssertEqual(all["dRir"], "78")
        XCTAssertEqual(all["BBR"], "S!")
        XCTAssertEqual(all["Commits"], "F!")
        XCTAssertEqual(all["Hotmail"], "—")
        XCTAssertEqual(all["xFernando"], "95", "weekly for a weekly-only provider")
        XCTAssertEqual(all["xFme"], "W!")
    }

    func testDeadRowAndReloginCaption() {
        let owner = claude("dRir", usage(session: 78))
        let dead = claude("Ai", usage(session: 20), email: "ai@example.com")
        let profiles = [owner, dead]
        var inputs = ProviderActiveSelection.Inputs(
            profiles: profiles, activeIds: [owner.id], focusedId: nil,
            context: FleetSummaryContext(thresholds: thresholds, isLoginDead: { $0.id == dead.id }, isExcluded: { _ in false },
                                         nextCandidates: [:], preflightVerdicts: [:], preferencesDegraded: false, isSwitching: false, now: now),
            queue: [])
        inputs.needsRelogin = [dead.id]
        let sel = ProviderActiveSelection.build(inputs)
        let row = rows(Model.sections(selections: sel, profiles: profiles, sort: .bar, filter: ""), .claude).first { $0.name == "Ai" }!
        XCTAssertTrue(row.isDead)
        XCTAssertTrue(row.needsRelogin)
        XCTAssertEqual(row.email, "ai@example.com")
        XCTAssertTrue(row.stateWords.contains("dead") && row.stateWords.contains("relogin"))
    }

    // MARK: - Filter

    func testFilterMatchesNameEmailAndStateWords() {
        let owner = claude("dRir", usage(session: 78), email: "fer@gmail.com")
        let maxed = claude("Commits", usage(weekly: 99.5))
        let dead = claude("Ai", usage(session: 20))
        let queued = claude("Memori", usage(session: 40), email: "fernando@mymemori.app")
        let profiles = [owner, maxed, dead, queued]
        let sel = selections(profiles, active: [owner.id], dead: [dead.id], queue: [queued.id])
        func names(_ filter: String) -> [String] {
            rows(Model.sections(selections: sel, profiles: profiles, sort: .bar, filter: filter), .claude).map(\.name)
        }
        XCTAssertEqual(names("mem"), ["Memori"])
        XCTAssertEqual(names("gmail"), ["dRir"], "emails match")
        XCTAssertEqual(names("dead"), ["Ai"])
        XCTAssertEqual(names("maxed"), ["Commits"])
        XCTAssertEqual(names("queued"), ["Memori"])
        XCTAssertEqual(names("active"), ["dRir"])
        XCTAssertTrue(Model.sections(selections: sel, profiles: profiles, sort: .bar, filter: "zzz").isEmpty,
                      "a provider with no matching row disappears while a filter is typed")
    }

    // MARK: - Routes

    func testRouteDecodesTheLegacyStringAndTheTypedPayload() {
        XCTAssertEqual(SettingsRoute(deepLink: "manageProfiles"), SettingsRoute(section: .manageProfiles))
        XCTAssertEqual(SettingsRoute(deepLink: "cliAccount")?.section, .cliAccount)
        XCTAssertNil(SettingsRoute(deepLink: "nope"))
        XCTAssertNil(SettingsRoute(deepLink: 42))
        let id = UUID()
        let typed = SettingsRoute(section: .accounts, profileId: id, tab: .login)
        XCTAssertEqual(SettingsRoute(deepLink: typed), typed)
        XCTAssertEqual(SettingsRoute(deepLink: typed)?.profileId, id)
        XCTAssertEqual(SettingsRoute(deepLink: typed)?.tab, .login)
    }

    func testAccountsSectionIsListedAndTitled() {
        XCTAssertTrue(SettingsSection.allCases.contains(.accounts))
        XCTAssertEqual(SettingsSection.accounts.title, "Accounts")
        XCTAssertFalse(SettingsSection.accounts.isProfileSetting)
        XCTAssertFalse(SettingsSection.accounts.isCredential)
        XCTAssertEqual(SettingsSection(rawValue: "accounts"), .accounts)
    }

    func testWindowSizesGrewAndKeepAMinimum() {
        XCTAssertEqual(Constants.WindowSizes.settingsWindow.width, 820)
        XCTAssertGreaterThanOrEqual(Constants.WindowSizes.settingsWindow.width, Constants.WindowSizes.settingsMinimum.width)
        XCTAssertGreaterThanOrEqual(Constants.WindowSizes.settingsMinimum.width, 720, "every legacy page's 520 pt content still fits")
    }
}
