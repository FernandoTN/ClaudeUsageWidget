//
//  MenuBarVisibilityTests.swift
//  Claude UsageTests
//
//  The per-account "Show in the menu bar" toggle (`Profile.hideFromMenuBar`):
//  profiles saved before it existed decode as shown; hiding is VISIBILITY
//  ONLY (the sweep, alerts and the auto-switch never read it); the census
//  and the roster say what is hidden; the ProfileManager seam saves once and
//  posts a structural change that asks for no fetch. The bar-layout half
//  lives in MenuBarOrderingTests and FleetSummaryTests.
//

import XCTest
@testable import Claude_Usage

private final class StructureChangeRecorder: @unchecked Sendable {
    private(set) var posts: [Notification] = []
    func record(_ note: Notification) { posts.append(note) }
}

@MainActor
final class MenuBarVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    private func usage(weekly: Double = 10) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionResetTime = now.addingTimeInterval(3600)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = now.addingTimeInterval(3 * 86400)
        u.lastUpdated = now.addingTimeInterval(-10)
        return u
    }

    private func claude(_ name: String, hidden: Bool = false, autoSwitch: Bool = true) -> Profile {
        var p = Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org",
                        claudeUsage: usage(), includeInAutoSwitch: autoSwitch)
        p.isShownOnMenuBar = !hidden
        return p
    }

    private func selections(_ profiles: [Profile], active: Set<UUID>) -> [ProviderActiveSelection] {
        ProviderActiveSelection.build(ProviderActiveSelection.Inputs(
            profiles: profiles, activeIds: active, focusedId: nil,
            context: FleetSummaryContext(
                thresholds: thresholds, isLoginDead: { _ in false }, isExcluded: { !$0.isAutoSwitchEnabled },
                nextCandidates: [:], preflightVerdicts: [:], preferencesDegraded: false, isSwitching: false, now: now),
            queue: []))
    }

    // MARK: - Decoding

    func testAProfileSavedBeforeTheFieldDecodesAsShown() throws {
        let data = try JSONEncoder().encode(Profile(name: "Old"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["hideFromMenuBar"], "nil encodes as absent")
        json["hideFromMenuBar"] = nil
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.hideFromMenuBar)
        XCTAssertTrue(decoded.isShownOnMenuBar, "absent key ⇒ shown, no migration")
    }

    func testTheToggleRoundTripsAndIsReversible() throws {
        var profile = Profile(name: "Held")
        profile.isShownOnMenuBar = false
        let hidden = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(hidden.hideFromMenuBar, true)
        XCTAssertFalse(hidden.isShownOnMenuBar)

        var back = hidden
        back.isShownOnMenuBar = true
        let shown = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(back))
        XCTAssertTrue(shown.isShownOnMenuBar)
        XCTAssertTrue(shown.isSelectedForDisplay, "the monitoring flag is a different field and untouched")
    }

    // MARK: - Visibility only (regression)

    /// Hiding must not change what is fetched (and therefore alerted on and
    /// rotated) nor who the auto-switch may pick: the old
    /// `isSelectedForDisplay` gated the sweep, and its deselected accounts
    /// decayed to stale, blind auto-switch picks.
    func testAHiddenAccountIsStillFetchedAndStillAnAutoSwitchCandidate() {
        let owner = claude("Owner")
        let held = claude("Held", hidden: true)
        let heldOff = claude("Held-Off", hidden: true, autoSwitch: false)
        let profiles = [owner, held, heldOff]

        XCTAssertEqual(MenuBarManager.sweepPopulation(profiles).map(\.id), [owner.id, held.id, heldOff.id])
        XCTAssertNil(MenuBarManager.candidateRejection(held, provider: .claude, excluding: [owner.id]),
                     "a hidden account is a legal auto-switch target")
        XCTAssertEqual(MenuBarManager.candidateRejection(heldOff, provider: .claude, excluding: [owner.id]), .autoSwitchOff,
                       "only the eligibility toggle excludes it")
        XCTAssertEqual(MenuBarManager.candidateRejection(owner, provider: .claude, excluding: [owner.id]), .excludedByCaller)
        XCTAssertEqual(
            Set(MenuBarManager.rankAutoSwitchCandidates([held, heldOff], customOrder: nil, now: now).map(\.id)),
            [held.id, heldOff.id])

        let selection = selections(profiles, active: [owner.id])[0]
        XCTAssertEqual(selection.eligibleCandidates.map(\.id), [held.id],
                       "the ⇄ selector still offers the hidden account")
    }

    // MARK: - Census and roster

    func testTheCensusCountsHiddenAccountsTheBarIsNotDrawing() {
        let owner = claude("Owner", hidden: true)
        let profiles = [owner, claude("A"), claude("B", hidden: true), claude("C", hidden: true)]
        let counts = selections(profiles, active: [owner.id])[0].counts
        XCTAssertEqual(counts.hiddenFromBar, 2, "the hidden owner is drawn, so it is not counted")
        XCTAssertTrue(ActiveVocabulary.countsWords(counts).hasSuffix("2\u{00A0}hidden"),
                      ActiveVocabulary.countsWords(counts))
        XCTAssertTrue(ActiveVocabulary.countsSentence(counts).hasSuffix("2 hidden from the menu bar"),
                      ActiveVocabulary.countsSentence(counts))

        let none = selections([claude("A")], active: []).first!.counts
        XCTAssertEqual(none.hiddenFromBar, 0)
        XCTAssertFalse(ActiveVocabulary.countsWords(none).contains("hidden"))
    }

    func testTheRosterDimsHiddenRowsButNeverTheOwner() {
        let owner = claude("Owner", hidden: true)
        let held = claude("Held", hidden: true)
        let shown = claude("Shown")
        let profiles = [owner, held, shown]
        let sections = AccountsRosterModel.sections(
            selections: selections(profiles, active: [owner.id]), profiles: profiles, sort: .bar, filter: "")
        let rows = Dictionary(uniqueKeysWithValues: sections[0].rows.map { ($0.id, $0) })
        XCTAssertEqual(rows[held.id]?.hiddenFromBar, true)
        XCTAssertEqual(rows[shown.id]?.hiddenFromBar, false)
        XCTAssertEqual(rows[owner.id]?.hiddenFromBar, false, "the bar draws its owner regardless")

        let filtered = AccountsRosterModel.sections(
            selections: selections(profiles, active: [owner.id]), profiles: profiles, sort: .bar, filter: "hidden")
        XCTAssertEqual(filtered.first?.rows.map(\.id), [held.id])
    }

    // MARK: - ProfileManager seam

    func testTheSeamSavesOnceAndPostsAStructureChangeWithoutAFetch() throws {
        let manager = ProfileManager.shared
        let defaults = ProfileStoreUsagePatchTests.testDefaults
        let savedData = defaults.data(forKey: "profiles_v3")
        let savedProfiles = manager.profiles
        let savedActive = manager.activeProfile
        // No credentials are stored for these; the teardown only drops the
        // (empty) cache entries a save creates, as the other seam suites do.
        let a = Profile(name: "Visibility-A")
        let b = Profile(name: "Visibility-B")
        defer {
            ProfileStore.shared.deleteProfileCredentials(profileId: a.id)
            ProfileStore.shared.deleteProfileCredentials(profileId: b.id)
            if let savedData {
                defaults.set(savedData, forKey: "profiles_v3")
                manager.loadProfiles()
            } else {
                defaults.removeObject(forKey: "profiles_v3")
                manager.profiles = savedProfiles
                manager.activeProfile = savedActive
            }
        }

        manager.profiles = [a, b]
        manager.activeProfile = a

        let recorder = StructureChangeRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: .profileDisplayStructureChanged, object: nil, queue: nil) { [recorder] in recorder.record($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        var posted: [Notification] { recorder.posts }

        manager.setShownOnMenuBar(false, for: [a.id, b.id])
        XCTAssertEqual(posted.count, 1, "one save, one structural repaint for a bulk change")
        XCTAssertNil(posted.first?.userInfo?["addedProfileIds"], "hiding asks for no fetch")
        XCTAssertEqual(manager.profiles.map(\.isShownOnMenuBar), [false, false])
        XCTAssertEqual(manager.activeProfile?.isShownOnMenuBar, false, "the focused copy follows")
        let stored = try JSONDecoder().decode([Profile].self, from: XCTUnwrap(defaults.data(forKey: "profiles_v3")))
        XCTAssertEqual(stored.map(\.hideFromMenuBar), [true, true])

        manager.setShownOnMenuBar(false, for: a.id)
        XCTAssertEqual(posted.count, 1, "no change, no notification")

        manager.setShownOnMenuBar(true, for: a.id)
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(manager.profiles.map(\.isShownOnMenuBar), [true, false])
    }
}
