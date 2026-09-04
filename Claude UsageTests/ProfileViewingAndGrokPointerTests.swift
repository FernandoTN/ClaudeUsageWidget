//
//  ProfileViewingAndGrokPointerTests.swift
//  Claude UsageTests
//
//  Two seams that belong to the same distinction: BEING FOCUSED IS NOT BEING
//  ACTIVE.
//
//  `viewProfile` is the focus half on its own — a caller that wants to LOOK at
//  a profile should not pay for an activation, and must not leave the traces one
//  leaves (a provider pointer moved, a SwitchEvent recorded, `lastUsedAt`
//  bumped, the auto-switch told the user deliberately chose this account).
//
//  `activeGrokProfileId` is the ownership half for the third provider. Until it
//  existed nothing in the app ever wrote ~/.grok/auth.json, so "who owns the
//  Grok login" had no answer and the UI inferred one from the focus. Now the
//  pointer is real, journaled like the other two — which is what the write half
//  of the cfprefsd defence needs, since a pointer is written ONCE when ownership
//  changes and is exactly the key class a write rejection strands.
//
//  Isolation: the same UserDefaults save/restore pattern as
//  ProfileActivationTests. The singletons outlive every test case, so all three
//  provider pointers, the focus pointer, the roster and the switch-history ring
//  are snapshotted in setUp and put back in tearDown — the published pointers
//  through `loadProfiles()`, which is the only public path that re-reads them.
//  The journal gets an injected snapshot source; the real preferences file is
//  never read or written.
//

import XCTest
@testable import Claude_Usage

/// Stands in for the authoritative preferences store. Whatever is in `values`
/// is what the daemon is deemed to have accepted.
private final class StubPreferenceStore: PreferenceStoreSnapshotting {
    var values: [String: Any] = [:]
    func snapshotAuthoritativeValues() -> [String: Any]? { values }
}

@MainActor
final class ProfileViewingAndGrokPointerTests: XCTestCase {

    private let profilesKey = "profiles_v3"
    private let activeProfileKey = "activeProfileId"
    private let activeGrokKey = "activeGrokProfileId"
    private let switchHistoryKey = "switchHistory_v1"

    private let store = ProfileStore.shared
    private let manager = ProfileManager.shared
    private let journal = PreferenceWriteJournal.shared
    private var defaults: UserDefaults { ProfileStoreUsagePatchTests.testDefaults }

    private var savedProfilesData: Data?
    private var savedActiveProfileId: String?
    private var savedSwitchHistory: Any?
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
        savedSwitchHistory = defaults.object(forKey: switchHistoryKey)
        savedManagerProfiles = manager.profiles
        savedActiveProfile = manager.activeProfile
        savedActiveClaudeProfileId = manager.activeClaudeProfileId
        savedActiveCodexProfileId = manager.activeCodexProfileId
        savedActiveGrokProfileId = manager.activeGrokProfileId
        manager.flushPendingUsage()
        store.resetPreferencesResilienceStateForTesting()
        store.setPreferencesPlistURLForTesting(nil)
        testProfileIDs = []
    }

    override func tearDown() {
        manager.flushPendingUsage()
        journal.resetForTesting()
        for id in testProfileIDs {
            store.deleteProfileCredentials(profileId: id)
        }

        // The three provider pointers are singleton state these tests move. Put
        // the durable half back first, then re-read it into the manager's
        // published properties — `loadProfiles()` is the only public path that
        // does that, and it is safe here because the test's own roster is still
        // in the store (an empty store is what makes it mint default profiles).
        store.saveActiveClaudeProfileId(savedActiveClaudeProfileId)
        store.saveActiveCodexProfileId(savedActiveCodexProfileId)
        store.saveActiveGrokProfileId(savedActiveGrokProfileId)
        if !store.loadProfiles().isEmpty {
            manager.loadProfiles()
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
        if let savedSwitchHistory {
            defaults.set(savedSwitchHistory, forKey: switchHistoryKey)
        } else {
            defaults.removeObject(forKey: switchHistoryKey)
        }
        if savedProfilesData != nil {
            manager.loadProfiles()
        } else {
            manager.profiles = savedManagerProfiles
            manager.activeProfile = savedActiveProfile
        }
        store.resetPreferencesResilienceStateForTesting()
        testProfileIDs = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// A Grok login that is still valid for hours — enough for the ownership
    /// questions here, which never reach the activation gate.
    private func liveGrokCredentialsJSON(userId: String = "user-1") -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.string(from: Date().addingTimeInterval(6 * 3600))
        return #"{"https://x.ai::grok-cli":{"key":"live-access","refresh_token":"r","expires_at":"\#(expiry)","user_id":"\#(userId)","oidc_client_id":"grok-cli"}}"#
    }

    /// Seeds a focused Claude profile plus a second profile, both in the store
    /// and in the manager. Neither carries credentials unless the test adds them,
    /// so nothing here can reach the Keychain or the network.
    @discardableResult
    private func seed(_ profiles: [Profile], focused: UUID) -> [Profile] {
        testProfileIDs = profiles.map(\.id)
        store.saveProfiles(profiles)
        manager.profiles = store.loadProfiles()
        manager.activeProfile = manager.profiles.first(where: { $0.id == focused })
        store.saveActiveProfileId(focused)
        return manager.profiles
    }

    // MARK: - viewProfile: the focus, and only the focus

    /// The seam itself. Viewing moves `activeProfile` and persists the focus
    /// pointer, which is what makes the popover, the menu bar and Settings show
    /// the profile — they all follow the `@Published` publish.
    func testViewProfileMovesTheFocusAndPersistsIt() {
        let first = Profile(id: UUID(), name: "First")
        let second = Profile(id: UUID(), name: "Second")
        seed([first, second], focused: first.id)

        XCTAssertTrue(manager.viewProfile(second.id))

        XCTAssertEqual(manager.activeProfile?.id, second.id, "viewing must move the focus")
        XCTAssertEqual(store.loadActiveProfileId(), second.id, "the moved focus must be persisted")
    }

    /// What viewing must NOT do. Every one of these is a trace an ACTIVATION
    /// leaves: a provider pointer changes hands, the switch is recorded for
    /// forensics, `lastUsedAt` is bumped, and the auto-switch is told the user
    /// deliberately chose this account (`.profileManuallyActivated`). Viewing is
    /// not choosing, so none of them may happen.
    func testViewProfileLeavesOwnershipHistoryAndTheManualMarkAlone() {
        let owner = Profile(id: UUID(), name: "Owner")
        var viewed = Profile(id: UUID(), name: "Viewed")
        viewed.grokCredentialsJSON = liveGrokCredentialsJSON()
        seed([owner, viewed], focused: owner.id)
        manager.claimActiveClaudeOwnership(owner.id)
        manager.claimActiveCodexOwnership(owner.id)
        manager.claimActiveGrokOwnership(owner.id)

        let historyBefore = SharedDataStore.shared.loadSwitchHistory().count
        let lastUsedBefore = manager.profiles.first(where: { $0.id == viewed.id })?.lastUsedAt
        let storedCredentialsBefore = store.loadProfiles().first(where: { $0.id == viewed.id })?.grokCredentialsJSON

        var manualMarks = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .profileManuallyActivated, object: nil, queue: nil
        ) { _ in manualMarks += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(manager.viewProfile(viewed.id))

        XCTAssertEqual(manager.activeClaudeProfileId, owner.id, "viewing must not move the Claude pointer")
        XCTAssertEqual(manager.activeCodexProfileId, owner.id, "viewing must not move the Codex pointer")
        XCTAssertEqual(manager.activeGrokProfileId, owner.id, "viewing must not move the Grok pointer")
        XCTAssertEqual(SharedDataStore.shared.loadSwitchHistory().count, historyBefore,
                       "no login changed hands, so there is no switch to record")
        XCTAssertEqual(manager.profiles.first(where: { $0.id == viewed.id })?.lastUsedAt, lastUsedBefore,
                       "viewing is not using — lastUsedAt must not be bumped")
        XCTAssertEqual(store.loadProfiles().first(where: { $0.id == viewed.id })?.grokCredentialsJSON,
                       storedCredentialsBefore,
                       "viewing must never touch stored credentials")
        XCTAssertEqual(manualMarks, 0,
                       ".profileManuallyActivated suppresses auto-switch-away — viewing must not claim that")
    }

    /// A deleted profile's id (the popover can hold one across a sweep) must
    /// change nothing rather than blanking the focus.
    func testViewProfileRefusesAnUnknownIdAndChangesNothing() {
        let first = Profile(id: UUID(), name: "First")
        seed([first], focused: first.id)

        XCTAssertFalse(manager.viewProfile(UUID()))

        XCTAssertEqual(manager.activeProfile?.id, first.id, "an unknown id must leave the focus put")
        XCTAssertEqual(store.loadActiveProfileId(), first.id)
    }

    // MARK: - The Grok pointer: persistence

    /// The pointer must go through `PreferenceWriteJournal`, not a bare
    /// `defaults.set`. It is written ONCE when ownership changes — precisely the
    /// key class the 2026-09-03 cfprefsd episode stranded on disk while every
    /// in-process read reported success. A bare write is invisible to the sweep
    /// check, so this test's real subject is that the key shows up as PENDING
    /// while the store refuses it, and clears when the store accepts it.
    func testGrokPointerIsJournaledAndReassertedWhenTheStoreRefusesIt() {
        let id = UUID()
        let refusing = StubPreferenceStore()
        journal.resetForTesting()
        journal.setSnapshotSourceForTesting(refusing)
        journal.setFlushGraceForTesting(0)

        store.saveActiveGrokProfileId(id)
        store.reassertPendingWrites()

        XCTAssertTrue(journal.pendingKeys(for: .profileStore).contains(activeGrokKey),
                      "a bare defaults.set would never appear here — the pointer must be journaled")

        refusing.values[activeGrokKey] = id.uuidString
        store.reassertPendingWrites()

        XCTAssertFalse(journal.pendingKeys(for: .profileStore).contains(activeGrokKey),
                       "once the store holds the value the key is no longer pending")
    }

    /// The read half: the same last-known-good shadow the other two pointers
    /// have. A wedged read is repaired from the shadow; a deliberate clear is
    /// respected rather than re-filled.
    func testGrokPointerRoundTripsAndSurvivesAWedgedRead() {
        let id = UUID()
        store.saveActiveGrokProfileId(id)
        XCTAssertEqual(store.loadActiveGrokProfileId(), id, "precondition: healthy round trip")

        defaults.removeObject(forKey: activeGrokKey)  // the wedge: the key is unreadable
        XCTAssertEqual(store.loadActiveGrokProfileId(), id, "a silent read must serve the known owner")
        XCTAssertTrue(store.preferencesDegraded)

        store.saveActiveGrokProfileId(nil)
        XCTAssertNil(store.loadActiveGrokProfileId(), "an explicit clear must not be re-filled from the shadow")
    }

    // MARK: - The Grok pointer: what reads it

    /// `activeAccountIds` is the ONE definition the menu-bar tint and the
    /// popover's Active badge share. A real pointer is evidence — a login this
    /// app wrote to auth.json — so it outranks the focused-or-sole inference
    /// that was the whole answer before; with no pointer, that inference is
    /// unchanged.
    func testActiveAccountIdsPrefersTheGrokPointerOverTheFocusedOrSoleRule() {
        var owner = Profile(id: UUID(), name: "GROK owner")
        owner.grokCredentialsJSON = liveGrokCredentialsJSON(userId: "user-1")
        var other = Profile(id: UUID(), name: "GROK other")
        other.grokCredentialsJSON = liveGrokCredentialsJSON(userId: "user-2")
        let profiles = seed([owner, other], focused: other.id)

        manager.claimActiveGrokOwnership(owner.id)
        XCTAssertTrue(manager.activeAccountIds(among: profiles).contains(owner.id),
                      "the pointer names the account that owns ~/.grok/auth.json")
        XCTAssertFalse(manager.activeAccountIds(among: profiles).contains(other.id),
                       "merely being focused does not make a Grok account active once a pointer exists")

        store.saveActiveGrokProfileId(nil)
        manager.loadProfiles()
        manager.profiles = profiles
        manager.activeProfile = profiles.first(where: { $0.id == other.id })
        XCTAssertTrue(manager.activeAccountIds(among: profiles).contains(other.id),
                      "with no pointer the focused Grok profile is still the active one")
    }

    /// The wiring this seam exists for: a focused profile that carries a Grok
    /// login somebody else owns still has work to do, so the activation must run
    /// the apply path instead of short-circuiting on `alreadyActive`. The
    /// decision is a pure function of the pointers, and `currentProviderOwnership`
    /// is what feeds it the live ones.
    func testNeedsProviderApplyReportsWorkForAGrokCarryingFocusedNonOwner() {
        var focused = Profile(id: UUID(), name: "GROK focused")
        focused.grokCredentialsJSON = liveGrokCredentialsJSON()
        let owner = Profile(id: UUID(), name: "GROK owner")
        seed([owner, focused], focused: focused.id)

        manager.claimActiveGrokOwnership(owner.id)

        XCTAssertEqual(manager.currentProviderOwnership.grok, owner.id,
                       "the live pointer must reach the decision — an unwired field reads nil and refuses every apply")
        XCTAssertEqual(
            ProfileManager.needsProviderApply(profile: focused, pointers: manager.currentProviderOwnership),
            [.grok],
            "focused but not the owner: the Grok login still has to be handed to the CLI"
        )

        manager.claimActiveGrokOwnership(focused.id)
        XCTAssertTrue(
            ProfileManager.needsProviderApply(profile: focused, pointers: manager.currentProviderOwnership).isEmpty,
            "owning the login it carries is the genuine no-op"
        )
    }
}
