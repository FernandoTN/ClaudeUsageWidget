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
    private var testProfileIDs: [UUID] = []

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        savedProfilesData = defaults.data(forKey: profilesKey)
        savedActiveProfileId = defaults.string(forKey: activeProfileKey)
        savedManagerProfiles = manager.profiles
        savedActiveProfile = manager.activeProfile
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
}
