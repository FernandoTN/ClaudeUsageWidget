//
//  ProfileActivationTests.swift
//  Claude UsageTests
//
//  The dead-login activation gate and the FOCUS.
//
//  The gate itself is correct and stays: a login that is expired and
//  unrefreshable must never be written over the CLI's working login. What was
//  wrong is that it also refused to move the FOCUS, and the in-app repair
//  screens (Settings → Codex Account / CLI Account) operate on the focused
//  profile — so the one profile that needed re-logging in was the one profile
//  the user could not open (reported live 2026-09-03: three clicks, three
//  refusals, no way to reach the login screen).
//
//  A USER-initiated switch now moves the focus and leaves every provider-active
//  pointer with its current owner; the AUTOMATIC path is unchanged.
//
//  The other half of the same defect lives here too: once the focus has moved
//  that way, the profile is FOCUSED BUT NOT THE OWNER of its login, and the
//  click that should finish the switch after an in-app repair used to be
//  answered "already active" with nothing applied. `alreadyActive` now requires
//  ownership as well as focus (`ProfileManager.needsProviderApply`).
//
//  Isolation: same UserDefaults save/restore pattern as
//  ProfileStoreUsagePatchTests — `profiles_v3` and the three active-profile
//  pointers are restored in tearDown, synthetic Keychain credentials are
//  deleted, and the Claude dead-login flag the gate sets (which lives in
//  UserDefaults.standard, not the test suite) is cleared per test profile.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class ProfileActivationTests: XCTestCase {

    private let profilesKey = "profiles_v3"
    private let activeProfileKey = "activeProfileId"
    private let store = ProfileStore.shared
    private let manager = ProfileManager.shared
    private var defaults: UserDefaults { ProfileStoreUsagePatchTests.testDefaults }

    private var savedProfilesData: Data?
    private var savedActiveProfileId: String?
    private var savedManagerProfiles: [Profile] = []
    private var savedActiveProfile: Profile?
    /// The provider-active pointers are singleton state that outlives a test —
    /// and the ownership tests below move them — so they are restored through
    /// the store's own setters, which also reset its last-known-good shadow
    /// (restoring the raw defaults key alone would leave the shadow serving the
    /// test's value on the next absent read).
    private var savedActiveClaudeProfileId: UUID?
    private var savedActiveCodexProfileId: UUID?
    private var testProfileIDs: [UUID] = []

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        savedProfilesData = defaults.data(forKey: profilesKey)
        savedActiveProfileId = defaults.string(forKey: activeProfileKey)
        savedManagerProfiles = manager.profiles
        savedActiveProfile = manager.activeProfile
        savedActiveClaudeProfileId = manager.activeClaudeProfileId
        savedActiveCodexProfileId = manager.activeCodexProfileId
        manager.flushPendingUsage()
        testProfileIDs = []
    }

    override func tearDown() {
        manager.flushPendingUsage()
        for id in testProfileIDs {
            // The gate flags the refused login dead in UserDefaults.standard —
            // clear it so a synthetic UUID never accumulates in the live domain.
            ClaudeCodeSyncService.shared.markLoginRevived(id)
            store.deleteProfileCredentials(profileId: id)
        }
        if let savedProfilesData {
            defaults.set(savedProfilesData, forKey: profilesKey)
        } else {
            defaults.removeObject(forKey: profilesKey)
        }
        if let savedActiveProfileId {
            defaults.set(savedActiveProfileId, forKey: activeProfileKey)
        } else {
            defaults.removeObject(forKey: activeProfileKey)
        }
        store.saveActiveClaudeProfileId(savedActiveClaudeProfileId)
        store.saveActiveCodexProfileId(savedActiveCodexProfileId)
        if savedProfilesData != nil {
            manager.loadProfiles()
        } else {
            manager.profiles = savedManagerProfiles
            manager.activeProfile = savedActiveProfile
        }
        testProfileIDs = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// An expired Claude Code login with NO refresh token: the pre-apply
    /// `ensureFreshCredentials` finds nothing to redeem (so the test makes no
    /// network call) and the gate sees a still-expired token.
    private func deadCredentialsJSON() -> String {
        let expiredMillis = (Date().timeIntervalSince1970 - 86_400) * 1000
        return #"{"claudeAiOauth":{"accessToken":"expired-access","expiresAt":\#(expiredMillis)}}"#
    }

    /// Seeds a healthy focused profile plus a profile whose Claude login is dead.
    /// The focused one deliberately carries no credentials, so no `security`
    /// subprocess runs for the outgoing re-adoption.
    private func seedFocusedPlusDeadLoginProfile() -> (focused: UUID, dead: UUID) {
        let focusedId = UUID()
        let deadId = UUID()
        let focused = Profile(id: focusedId, name: "Focused")
        var dead = Profile(id: deadId, name: "DeadLogin")
        dead.cliCredentialsJSON = deadCredentialsJSON()

        testProfileIDs = [focusedId, deadId]
        store.saveProfiles([focused, dead])
        manager.profiles = store.loadProfiles()
        manager.activeProfile = manager.profiles.first(where: { $0.id == focusedId })
        store.saveActiveProfileId(focusedId)
        return (focusedId, deadId)
    }

    // MARK: - User-initiated switch onto a dead login

    /// The fix. Clicking a profile whose provider login is dead must SHOW that
    /// profile — otherwise its login screen is unreachable — while leaving the
    /// dead login unapplied and the provider-active pointer where it was.
    func testUserSwitchToDeadLoginProfileMovesFocusButNotTheProviderPointer() async {
        let ids = seedFocusedPlusDeadLoginProfile()
        let pointerBefore = manager.activeClaudeProfileId

        let outcome = await manager.activateProfileDetailed(ids.dead, userInitiated: true)

        XCTAssertEqual(outcome, .focusedWithoutApplying)
        XCTAssertEqual(manager.activeProfile?.id, ids.dead,
                       "the focus must follow a user switch so the profile can be repaired in Settings")
        XCTAssertEqual(store.loadActiveProfileId(), ids.dead, "the moved focus must be persisted")
        XCTAssertEqual(manager.activeClaudeProfileId, pointerBefore,
                       "the dead login was not applied, so the Claude CLI pointer must not move")
        XCTAssertNotEqual(manager.activeClaudeProfileId, ids.dead,
                          "a refused login must never claim the provider-active pointer")
    }

    /// The Bool-returning wrapper is what every UI caller uses. A focus-only
    /// switch is NOT a landed switch, so it must still report false.
    func testBoolWrapperReportsFalseForAFocusOnlySwitch() async {
        let ids = seedFocusedPlusDeadLoginProfile()

        let landed = await manager.activateProfile(ids.dead, userInitiated: true)

        XCTAssertFalse(landed, "no login changed hands — the Bool contract is 'did the switch land'")
        XCTAssertEqual(manager.activeProfile?.id, ids.dead, "…but the focus still moved")
    }

    // MARK: - Automatic switch onto a dead login (unchanged)

    /// The auto-switch walk and the retry sweeps treat a refusal as "nothing
    /// happened". Moving the focus there would point the UI at an account the
    /// CLI was never switched to, once per retry — so the automatic path keeps
    /// refusing outright.
    func testAutomaticSwitchToDeadLoginProfileLeavesTheFocusPut() async {
        let ids = seedFocusedPlusDeadLoginProfile()
        let pointerBefore = manager.activeClaudeProfileId

        let outcome = await manager.activateProfileDetailed(ids.dead, userInitiated: false)

        XCTAssertEqual(outcome, .credentialsRefused)
        XCTAssertEqual(manager.activeProfile?.id, ids.focused, "an automatic refusal must not move the focus")
        XCTAssertEqual(manager.activeClaudeProfileId, pointerBefore)
    }

    // MARK: - Auto-switch walk reaction

    /// The walk never sets `userInitiated`, so it cannot see this outcome today
    /// — but if it ever does, it must behave exactly as it does for a refused
    /// login: candidate excluded, queued handoff NOT consumed, walk continues.
    func testWalkReactionForAFocusOnlySwitchMatchesARefusedLogin() {
        XCTAssertEqual(
            MenuBarManager.walkReaction(to: .focusedWithoutApplying),
            MenuBarManager.walkReaction(to: .credentialsRefused)
        )
        XCTAssertEqual(MenuBarManager.walkReaction(to: .focusedWithoutApplying), .excludeCandidate)
        XCTAssertNotEqual(MenuBarManager.walkReaction(to: .focusedWithoutApplying), .switched,
                          "a focus move is not a landed switch — consuming the queue entry here would eat a handoff")
    }

    /// Same rule at the enum level, which is what the Bool wrapper reads.
    func testFocusOnlyOutcomeIsNotALandedActivation() {
        XCTAssertFalse(ProfileManager.ActivationOutcome.focusedWithoutApplying.didActivate)
    }

    // MARK: - Switch history enrichment (the insights switch log)

    /// The outgoing account's headroom can only be read HERE: by the time the
    /// dashboard renders the row, that profile's cached usage has moved on.
    /// `providerRaw` files the row under a provider even after both names stop
    /// resolving to profiles.
    func testSwitchHistoryRecordsOutgoingHeadroomAndProvider() async {
        let focusedId = UUID()
        let deadId = UUID()
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 88
        usage.sessionResetTime = Date().addingTimeInterval(3600)
        var focused = Profile(id: focusedId, name: "FocusedWithUsage")
        focused.claudeUsage = usage
        var dead = Profile(id: deadId, name: "DeadLogin")
        dead.cliCredentialsJSON = deadCredentialsJSON()

        testProfileIDs = [focusedId, deadId]
        store.saveProfiles([focused, dead])
        manager.profiles = [focused, dead]
        manager.activeProfile = focused
        store.saveActiveProfileId(focusedId)

        _ = await manager.activateProfileDetailed(deadId, userInitiated: true)

        let recorded = SharedDataStore.shared.loadSwitchHistory().last
        XCTAssertEqual(recorded?.from, "FocusedWithUsage")
        XCTAssertEqual(recorded?.to, "DeadLogin")
        XCTAssertEqual(recorded?.fromHeadroom ?? -1, 12, accuracy: 0.001,
                       "100 − the outgoing account's effective session percentage")
        XCTAssertEqual(recorded?.providerRaw, "claude")
    }

    /// An outgoing account nothing has ever measured records no headroom —
    /// a zero there would read as "left at 100 % used" in the switch log.
    func testSwitchHistoryLeavesHeadroomNilWhenTheOutgoingAccountWasNeverMeasured() async {
        let ids = seedFocusedPlusDeadLoginProfile()

        _ = await manager.activateProfileDetailed(ids.dead, userInitiated: true)

        let recorded = SharedDataStore.shared.loadSwitchHistory().last
        XCTAssertEqual(recorded?.from, "Focused")
        XCTAssertNil(recorded?.fromHeadroom)
        XCTAssertEqual(recorded?.providerRaw, "claude")
    }

    // MARK: - Focused, but not the owner of its login

    /// The second half of the same defect. A focus-only switch leaves the
    /// profile FOCUSED while somebody else still owns the CLI login; the user
    /// then repairs the login in Settings and clicks the profile again. That
    /// click used to hit `alreadyActive` and apply nothing — the repaired
    /// profile could never become the CLI's account.
    ///
    /// Here the repaired login is still dead, which is the outcome a test can
    /// assert end to end: the activation must run the gate again (not
    /// short-circuit) and report the refusal, leaving the pointer put. A LIVE
    /// login is deliberately NOT exercised end to end — the apply path writes
    /// the developer's real `~/.claude/.credentials.json` and system Keychain
    /// item (and the Codex path probes the network), which no test may do; the
    /// decision that governs it is covered as a pure function below.
    func testClickingAFocusedProfileThatDoesNotOwnItsLoginIsNotAlreadyActive() async {
        let ids = seedFocusedPlusDeadLoginProfile()
        // Put the focus on the dead profile, exactly as the focus-only switch
        // leaves it, while the Claude pointer stays with the other profile.
        manager.activeProfile = manager.profiles.first(where: { $0.id == ids.dead })
        store.saveActiveProfileId(ids.dead)
        manager.claimActiveClaudeOwnership(ids.focused)

        let outcome = await manager.activateProfileDetailed(ids.dead, userInitiated: true)

        XCTAssertEqual(outcome, .focusedWithoutApplying,
                       "a focused profile that does not own its login must run the apply path, not short-circuit")
        XCTAssertNotEqual(outcome, .alreadyActive)
        XCTAssertEqual(manager.activeClaudeProfileId, ids.focused,
                       "the login is still dead, so the provider pointer must not move")
    }

    /// The true no-op still is one: focused AND the owner of the login it
    /// carries. Nothing is applied and no pointer moves.
    func testClickingAFocusedProfileThatOwnsItsLoginIsAlreadyActive() async {
        let ids = seedFocusedPlusDeadLoginProfile()
        manager.activeProfile = manager.profiles.first(where: { $0.id == ids.dead })
        store.saveActiveProfileId(ids.dead)
        manager.claimActiveClaudeOwnership(ids.dead)
        let lastUsedBefore = manager.profiles.first(where: { $0.id == ids.dead })?.lastUsedAt

        let outcome = await manager.activateProfileDetailed(ids.dead, userInitiated: true)

        XCTAssertEqual(outcome, .alreadyActive)
        XCTAssertEqual(manager.activeClaudeProfileId, ids.dead)
        XCTAssertEqual(manager.profiles.first(where: { $0.id == ids.dead })?.lastUsedAt, lastUsedBefore,
                       "a genuine no-op must not write the profile back")
    }

    // MARK: - The decision itself

    /// The pure helper the early return now consults. A carried login counts as
    /// work whenever the provider pointer is somebody else's — or nobody's,
    /// since applying is what claims it.
    func testNeedsProviderApplyNamesTheSharedLoginsTheProfileDoesNotOwn() {
        let id = UUID()
        let other = UUID()
        var profile = Profile(id: id, name: "Mixed")
        profile.cliCredentialsJSON = deadCredentialsJSON()
        profile.codexCredentialsJSON = #"{"tokens":{"access_token":"x"}}"#

        XCTAssertEqual(
            ProfileManager.needsProviderApply(profile: profile, pointers: .init(claude: other, codex: other)),
            [.claude, .codex]
        )
        XCTAssertEqual(
            ProfileManager.needsProviderApply(profile: profile, pointers: .init(claude: id, codex: other)),
            [.codex],
            "a provider it already owns is not work"
        )
        XCTAssertTrue(
            ProfileManager.needsProviderApply(profile: profile, pointers: .init(claude: id, codex: id)).isEmpty,
            "owning every login it carries is the only genuine already-active case"
        )
        XCTAssertEqual(
            ProfileManager.needsProviderApply(profile: profile, pointers: .init()),
            [.claude, .codex],
            "an unset pointer is nobody's — the apply is what claims it"
        )
        XCTAssertTrue(
            ProfileManager.needsProviderApply(profile: Profile(id: id, name: "Empty"), pointers: .init()).isEmpty,
            "a profile carrying no provider login has nothing to apply"
        )
    }

    /// Grok is the third provider but has no shared CLI login: nothing writes
    /// ~/.grok/auth.json, so a focused Grok profile is fully active and must
    /// never be dragged through the apply path on every click. The pointer
    /// field exists for the day that changes, and is honoured when set.
    func testNeedsProviderApplyTreatsGrokAsHavingNoSharedLogin() {
        let id = UUID()
        let other = UUID()
        var profile = Profile(id: id, name: "GROK")
        profile.grokCredentialsJSON = #"{"https://x.ai::cli":{"key":"x"}}"#

        XCTAssertTrue(
            ProfileManager.needsProviderApply(profile: profile, pointers: .init()).isEmpty,
            "no Grok pointer exists, so a Grok login can never be owned by somebody else"
        )
        XCTAssertEqual(
            ProfileManager.needsProviderApply(profile: profile, pointers: .init(grok: other)),
            [.grok],
            "once a Grok pointer exists the same ownership rule applies"
        )
        XCTAssertTrue(
            ProfileManager.needsProviderApply(profile: profile, pointers: .init(grok: id)).isEmpty
        )
    }
}
