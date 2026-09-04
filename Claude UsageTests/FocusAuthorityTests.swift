//
//  FocusAuthorityTests.swift
//  Claude UsageTests
//
//  FOCUS IS NEVER AUTHORITY.
//
//  `activeProfile` is the account the user is LOOKING at. The three provider
//  pointers say which account each CLI is actually signed into. The two are
//  different questions, and until this sweep a dozen places answered the second
//  one with the first — `activeClaudeProfileId ?? activeProfile?.id`, or a bare
//  `profile.id == activeProfile?.id` standing in for "is this account active".
//
//  That conflation was survivable only while every viewing path also activated.
//  With viewing free to land on any account, the sharp failure is concrete: the
//  user opens a non-owner that was burned to 96 % session days ago, the sweep
//  reads its cached number, and the auto-switch rotates the shared CLI login off
//  the account that is actually signed in and still has headroom — costing every
//  running session a full context re-read to solve a problem nobody had.
//
//  The rule these tests pin: OWNER = the provider pointer; with no pointer, a
//  SOLE credentialed profile (the CLI is signed into it or into nobody); and
//  otherwise nobody at all. The focus never breaks the tie.
//
//  Isolation: the same UserDefaults save/restore pattern as
//  ProfileActivationTests and ProfileViewingAndGrokPointerTests. The manager and
//  store are singletons that outlive a case, so the roster, the focus pointer
//  and all three provider pointers are snapshotted in setUp and put back in
//  tearDown. No test here carries a live credential, so nothing reaches the
//  Keychain, ~/.codex/auth.json, ~/.grok/auth.json or the network.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class FocusAuthorityTests: XCTestCase {

    private let profilesKey = "profiles_v3"
    private let activeProfileKey = "activeProfileId"

    private let store = ProfileStore.shared
    private let manager = ProfileManager.shared
    private var defaults: UserDefaults { ProfileStoreUsagePatchTests.testDefaults }

    private var savedProfilesData: Data?
    private var savedActiveProfileId: String?
    private var savedManagerProfiles: [Profile] = []
    private var savedActiveProfile: Profile?
    private var savedActiveClaudeProfileId: UUID?
    private var savedActiveCodexProfileId: UUID?
    private var savedActiveGrokProfileId: UUID?
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
        savedActiveGrokProfileId = manager.activeGrokProfileId
        manager.flushPendingUsage()
        testProfileIDs = []
    }

    override func tearDown() {
        manager.flushPendingUsage()
        for id in testProfileIDs {
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
        store.saveActiveGrokProfileId(savedActiveGrokProfileId)
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

    /// A Claude Code login that is expired with no refresh token. Nothing here
    /// ever applies it — the tests below only ask WHO OWNS it — but an expired
    /// one guarantees no path could redeem it over the network if they did.
    private func claudeLoginJSON() -> String {
        let expiredMillis = (Date().timeIntervalSince1970 - 86_400) * 1000
        return #"{"claudeAiOauth":{"accessToken":"expired-access","expiresAt":\#(expiredMillis)}}"#
    }

    @discardableResult
    private func seed(_ profiles: [Profile], focused: UUID) -> [Profile] {
        testProfileIDs = profiles.map(\.id)
        store.saveProfiles(profiles)
        manager.profiles = store.loadProfiles()
        manager.activeProfile = manager.profiles.first(where: { $0.id == focused })
        store.saveActiveProfileId(focused)
        return manager.profiles
    }

    /// Clears all three pointers without going through `loadProfiles()`, which
    /// would re-run the inference this suite is measuring.
    private func clearProviderPointers() {
        store.saveActiveClaudeProfileId(nil)
        store.saveActiveCodexProfileId(nil)
        store.saveActiveGrokProfileId(nil)
        let profiles = manager.profiles
        let focused = manager.activeProfile
        manager.loadProfiles()
        manager.profiles = profiles
        manager.activeProfile = focused
    }

    // MARK: - Owner resolution

    /// The pointer is the only positive evidence in the system — it records a
    /// login this app actually wrote, or verified against the identity
    /// endpoint — so it outranks everything, the focus included.
    func testTheProviderPointerOutranksTheFocus() {
        var owner = Profile(id: UUID(), name: "Owner")
        owner.cliCredentialsJSON = claudeLoginJSON()
        var viewed = Profile(id: UUID(), name: "Viewed")
        viewed.cliCredentialsJSON = claudeLoginJSON()
        seed([owner, viewed], focused: viewed.id)

        manager.claimActiveClaudeOwnership(owner.id)

        XCTAssertEqual(manager.providerOwnerId(for: .claude), owner.id,
                       "the pointer names the profile that owns the shared Keychain login")
        XCTAssertTrue(manager.isProviderOwner(owner.id, of: .claude))
        XCTAssertFalse(manager.isProviderOwner(viewed.id, of: .claude),
                       "the profile on screen owns nothing merely by being on screen")
    }

    /// With no pointer, ONE credentialed profile is still a sound answer: the
    /// CLI is signed in as that account or as nobody at all, so naming it can
    /// wrong no one. It holds whether or not that profile is the one on screen —
    /// the answer comes from the roster, never from the view.
    func testASoleCredentialedProfileOwnsItsProviderWithNoPointer() {
        var sole = Profile(id: UUID(), name: "Sole Claude")
        sole.cliCredentialsJSON = claudeLoginJSON()
        let other = Profile(id: UUID(), name: "No credentials")
        seed([sole, other], focused: other.id)
        clearProviderPointers()

        XCTAssertNil(manager.activeClaudeProfileId, "precondition: no pointer to lean on")
        XCTAssertEqual(manager.providerOwnerId(for: .claude), sole.id,
                       "one Claude login on the roster is the only account the CLI could be signed into")
        XCTAssertFalse(manager.isProviderOwner(other.id),
                       "the focused profile carries no login at all — it can own nothing")
    }

    /// Several candidates and no pointer means the app DOES NOT KNOW, and "does
    /// not know" must not be answered with "whatever is on screen". This is the
    /// exact tie the old `?? activeProfile?.id` fallbacks broke the wrong way.
    func testNoPointerAndSeveralCredentialedProfilesResolvesToNobody() {
        var first = Profile(id: UUID(), name: "Claude A")
        first.cliCredentialsJSON = claudeLoginJSON()
        var second = Profile(id: UUID(), name: "Claude B")
        second.cliCredentialsJSON = claudeLoginJSON()
        seed([first, second], focused: second.id)
        clearProviderPointers()

        XCTAssertNil(manager.providerOwnerId(for: .claude),
                     "two logins and no pointer: the owner is genuinely unknown")
        XCTAssertFalse(manager.isProviderOwner(second.id, of: .claude),
                       "being viewed must not break the tie")
        XCTAssertTrue(manager.activeAccountIds(among: manager.profiles).isEmpty,
                      "and the UI's one definition of ACTIVE must agree with the resolver")
    }

    // MARK: - The auto-switch trigger

    /// The hazard in one assertion. A switch rewrites a shared CLI login, so an
    /// account no CLI is signed into has no session to rescue — however high its
    /// cached percentage is. Both the sweep's call sites and the trigger's own
    /// guard read this predicate.
    func testOnlyAProviderOwnerMayTriggerAnAutoSwitch() {
        var owner = Profile(id: UUID(), name: "Owner")
        owner.cliCredentialsJSON = claudeLoginJSON()
        var viewed = Profile(id: UUID(), name: "Viewed, exhausted")
        viewed.cliCredentialsJSON = claudeLoginJSON()
        var exhausted = ClaudeUsage.empty
        exhausted.sessionPercentage = 96
        viewed.claudeUsage = exhausted
        seed([owner, viewed], focused: viewed.id)
        manager.claimActiveClaudeOwnership(owner.id)

        XCTAssertFalse(MenuBarManager.mayTriggerAutoSwitch(viewed.id, in: manager),
                       "a VIEWED non-owner at 96% must not rotate the CLI off the owner that still has headroom")
        XCTAssertTrue(MenuBarManager.mayTriggerAutoSwitch(owner.id, in: manager),
                      "the owner at the same reading must still trigger — that is the feature")
    }

    // MARK: - Where the view lands after a switch

    /// The decision table. A user-initiated switch always takes the view; an
    /// automatic one takes it only out of the outgoing owner, so an inspector
    /// open on a repair is never yanked away mid-repair.
    func testFocusFollowsAUserSwitchAlwaysAndAnAutomaticOneOnlyOutOfTheOwner() {
        func follows(
            userInitiated: Bool = false,
            focusIsTarget: Bool = false,
            focusWasOutgoingOwner: Bool = false,
            hasFocus: Bool = true
        ) -> Bool {
            ProfileManager.focusFollowsSwitch(
                userInitiated: userInitiated,
                focusIsTarget: focusIsTarget,
                focusWasOutgoingOwner: focusWasOutgoingOwner,
                hasFocus: hasFocus
            )
        }

        XCTAssertTrue(follows(userInitiated: true),
                      "user-initiated: you switched in order to look at it")
        XCTAssertTrue(follows(focusWasOutgoingOwner: true),
                      "automatic, out of the outgoing owner: keep watching the active account")
        XCTAssertFalse(follows(),
                       "automatic, from anywhere else: the user went there deliberately")
        XCTAssertTrue(follows(focusIsTarget: true),
                      "an ownership repair on the profile already on screen has nowhere else to go")
        XCTAssertTrue(follows(hasFocus: false),
                      "nothing is focused yet — the switch target is the only candidate")
    }

    /// The same rule through the real activation. The target carries no
    /// credentials, so nothing is applied and no shared login is touched; what
    /// is being measured is purely where the view ends up.
    func testAutomaticSwitchLeavesTheViewOnAProfileThatDidNotOwnTheLogin() async {
        var owner = Profile(id: UUID(), name: "Owner")
        owner.cliCredentialsJSON = claudeLoginJSON()
        let viewed = Profile(id: UUID(), name: "Viewed non-owner")
        let target = Profile(id: UUID(), name: "Switch target")
        seed([owner, viewed, target], focused: viewed.id)
        manager.claimActiveClaudeOwnership(owner.id)

        _ = await manager.activateProfileDetailed(target.id, userInitiated: false)

        XCTAssertEqual(manager.activeProfile?.id, viewed.id,
                       "an automatic switch must not drag the view off an account the user chose to open")
        XCTAssertEqual(store.loadActiveProfileId(), viewed.id, "and must not persist a move it did not make")
    }

    /// The other half: a deliberate "Make active" still moves the view onto the
    /// account it just activated, from exactly the same starting state.
    func testUserInitiatedSwitchAlwaysMovesTheView() async {
        var owner = Profile(id: UUID(), name: "Owner")
        owner.cliCredentialsJSON = claudeLoginJSON()
        let viewed = Profile(id: UUID(), name: "Viewed non-owner")
        let target = Profile(id: UUID(), name: "Switch target")
        seed([owner, viewed, target], focused: viewed.id)
        manager.claimActiveClaudeOwnership(owner.id)

        _ = await manager.activateProfileDetailed(target.id, userInitiated: true)

        XCTAssertEqual(manager.activeProfile?.id, target.id,
                       "the user asked for this switch — the view follows it")
        XCTAssertEqual(store.loadActiveProfileId(), target.id)
    }

    /// CLI-side adoption. A `/login` in the terminal moves a provider pointer
    /// without the user touching the app, and both adoption passes end by
    /// re-reading the focused profile through this seam. It must refresh the
    /// COPY and never change WHICH profile is focused.
    func testAdoptionRefreshesTheViewedProfileWithoutMovingTheView() {
        let viewed = Profile(id: UUID(), name: "Viewed")
        var newOwner = Profile(id: UUID(), name: "Adopted owner")
        newOwner.cliCredentialsJSON = claudeLoginJSON()
        seed([viewed, newOwner], focused: viewed.id)

        // What an adoption pass does: the pointer changes hands, and the roster
        // is re-read from disk with fresher data for some profile.
        manager.claimActiveClaudeOwnership(newOwner.id)
        if let index = manager.profiles.firstIndex(where: { $0.id == viewed.id }) {
            manager.profiles[index].name = "Viewed (refreshed)"
        }

        manager.refreshFocusedProfileCopy()

        XCTAssertEqual(manager.activeProfile?.id, viewed.id,
                       "adopting somebody else's CLI login is not a decision about what to look at")
        XCTAssertEqual(manager.activeProfile?.name, "Viewed (refreshed)",
                       "…but the published copy must still be re-read, or the UI shows stale data")
        XCTAssertEqual(manager.activeClaudeProfileId, newOwner.id,
                       "precondition: the pointer really did move")
    }

    // MARK: - Delete

    /// A delete must never rewrite a CLI login. The viewed profile is gone, so
    /// the view needs somewhere to land — and that is the whole of it.
    /// `activateProfile` would have applied the survivor's credentials to the
    /// shared Keychain item, signing the CLI into an account the user never
    /// asked to switch to.
    func testDeletingTheViewedProfileOnlyMovesTheView() throws {
        let viewed = Profile(id: UUID(), name: "Viewed")
        let survivor = Profile(id: UUID(), name: "Survivor")
        seed([survivor, viewed], focused: viewed.id)
        manager.claimActiveClaudeOwnership(viewed.id)
        manager.claimActiveGrokOwnership(viewed.id)

        let historyBefore = SharedDataStore.shared.loadSwitchHistory().count
        let lastUsedBefore = manager.profiles.first(where: { $0.id == survivor.id })?.lastUsedAt

        try manager.deleteProfile(viewed.id)

        XCTAssertEqual(manager.activeProfile?.id, survivor.id, "the view lands on the surviving profile")
        XCTAssertEqual(store.loadActiveProfileId(), survivor.id, "and the moved view is persisted")
        XCTAssertNil(manager.activeClaudeProfileId,
                     "the deleted profile's Claude pointer is released, not handed to the survivor")
        XCTAssertNil(manager.activeGrokProfileId,
                     "the Grok pointer too — a dangling one would go on naming a deleted profile as owner")
        XCTAssertEqual(SharedDataStore.shared.loadSwitchHistory().count, historyBefore,
                       "no login changed hands, so there is no switch to record")
        XCTAssertEqual(manager.profiles.first(where: { $0.id == survivor.id })?.lastUsedAt, lastUsedBefore,
                       "being shown after a delete is not being activated — lastUsedAt must not be bumped")
    }
}
