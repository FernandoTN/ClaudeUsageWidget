//
//  ProviderOwnerClaimedTests.swift
//  Claude UsageTests
//
//  `.providerOwnerClaimed` is the one signal for "which account is this
//  provider's CLI signed into now". It exists because the answer used to be
//  readable only by polling three `@Published` pointers: an observer that wants
//  to attribute work to an account had no way to learn WHEN ownership moved, or
//  WHY, and `.providerOwnerChangedExternally` covers only the two CLI-side
//  adoption passes — silence from it means "no external login", never "no
//  change".
//
//  What these tests pin is the contract a consumer codes against:
//
//  1. one post per real change, carrying the new owner, the outgoing owner and
//     the new owner's non-secret account stamp;
//  2. SILENCE when the standing owner re-claims — the pointer is written on
//     every Sync and every activation of an already-active account, and a
//     consumer that counted those would see handovers that never happened;
//  3. a clear is a post, not an absence: object nil, previous owner named;
//  4. `cause` names the PATH, so a user's own switch is distinguishable from
//     the app restoring its own bookkeeping.
//
//  Isolation: the same UserDefaults save/restore pattern as
//  FocusAuthorityTests. The manager and store are singletons that outlive a
//  case, so the roster, the focus pointer and all three provider pointers are
//  snapshotted in setUp and put back in tearDown. No profile here carries a
//  credential, so nothing reaches the Keychain, ~/.codex/auth.json,
//  ~/.grok/auth.json or the network.
//

import XCTest
@testable import Claude_Usage

/// Collects `.providerOwnerClaimed` posts. The seam posts synchronously from
/// the main actor, so a `nil` queue keeps every observation inside the same
/// turn as the call that caused it — no expectation, no waiting, and a test
/// that asserts SILENCE is measuring silence rather than a race.
private final class OwnerClaimRecorder: @unchecked Sendable {
    private(set) var posts: [Notification] = []
    func record(_ note: Notification) { posts.append(note) }
    func clear() { posts.removeAll() }
}

@MainActor
final class ProviderOwnerClaimedTests: XCTestCase {

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

    private var recorder = OwnerClaimRecorder()
    private var observer: NSObjectProtocol?

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

        recorder = OwnerClaimRecorder()
        observer = NotificationCenter.default.addObserver(
            forName: .providerOwnerClaimed, object: nil, queue: nil
        ) { [recorder] note in recorder.record(note) }
    }

    override func tearDown() {
        // Unhook FIRST: putting the singleton's pointers back is itself a set of
        // pointer moves, and they are not this suite's measurements.
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil

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

    @discardableResult
    private func seed(_ profiles: [Profile], focused: UUID) -> [Profile] {
        testProfileIDs = profiles.map(\.id)
        store.saveProfiles(profiles)
        manager.profiles = store.loadProfiles()
        manager.activeProfile = manager.profiles.first(where: { $0.id == focused })
        store.saveActiveProfileId(focused)
        return manager.profiles
    }

    /// The posts for ONE provider. A single call can move more than one pointer
    /// (`loadProfiles()` hydrates all three), so every assertion about a count
    /// has to say which provider it is counting.
    private func posts(for provider: String) -> [Notification] {
        recorder.posts.filter { $0.userInfo?["provider"] as? String == provider }
    }

    // MARK: - A claim announces itself

    /// The whole payload in one pass: a consumer reads the new owner off
    /// `object`, learns who it took the login from, and gets the account stamp
    /// that lets it attribute work to an ACCOUNT rather than to a profile row
    /// the user may rename or delete.
    func testAClaimPostsOnceAndNamesBothOwnersAndTheAccount() throws {
        var outgoing = Profile(id: UUID(), name: "Outgoing")
        outgoing.claudeAccountUUID = "acct-outgoing"
        var incoming = Profile(id: UUID(), name: "Incoming")
        incoming.claudeAccountUUID = "acct-incoming"
        seed([outgoing, incoming], focused: outgoing.id)
        manager.claimActiveClaudeOwnership(outgoing.id)
        recorder.clear()

        manager.claimActiveClaudeOwnership(incoming.id)

        XCTAssertEqual(recorder.posts.count, 1,
                       "claiming one provider's login says nothing about the other two")
        let note = try XCTUnwrap(posts(for: "claude").first)
        XCTAssertEqual(note.object as? UUID, incoming.id, "object IS the new owner")
        XCTAssertEqual(note.userInfo?["previousOwnerId"] as? String, outgoing.id.uuidString,
                       "the outgoing owner is what makes the post a HANDOVER rather than a reading")
        XCTAssertEqual(note.userInfo?["cause"] as? String, "sync",
                       "the claim entry points are the Sync paths — every caller today is one")
        XCTAssertEqual(note.userInfo?["accountStamp"] as? String, "acct-incoming",
                       "the stamp is the new owner's account, never the outgoing one's")
    }

    /// The pointer is written on every Sync and on every activation, including
    /// the ones that land on the account already holding the login. Posting
    /// there would report handovers that never happened — and a consumer
    /// counting switches would bill them.
    func testReClaimingTheStandingOwnerPostsNothing() {
        let owner = Profile(id: UUID(), name: "Owner")
        let other = Profile(id: UUID(), name: "Other")
        seed([owner, other], focused: other.id)
        manager.claimActiveCodexOwnership(owner.id)
        recorder.clear()

        manager.claimActiveCodexOwnership(owner.id)
        manager.claimActiveCodexOwnership(owner.id)

        XCTAssertTrue(recorder.posts.isEmpty,
                      "the value did not change, so nothing was announced")
        XCTAssertEqual(manager.activeCodexProfileId, owner.id,
                       "…and the pointer itself is exactly where it was")
    }

    /// Losing an owner is a change like any other. Reporting it by silence would
    /// leave a consumer attributing work to a profile the user has deleted, so
    /// the post still fires — with nothing in `object`, and the profile that is
    /// going away named as the previous owner.
    func testClearingThePointerPostsWithNoOwnerAndNamesThePreviousOne() throws {
        var owner = Profile(id: UUID(), name: "Owner")
        owner.claudeAccountUUID = "acct-owner"
        let survivor = Profile(id: UUID(), name: "Survivor")
        seed([survivor, owner], focused: survivor.id)
        manager.claimActiveClaudeOwnership(owner.id)
        recorder.clear()

        try manager.deleteProfile(owner.id)

        let claude = posts(for: "claude")
        XCTAssertEqual(claude.count, 1, "one release, one post")
        let note = try XCTUnwrap(claude.first)
        XCTAssertNil(note.object, "the pointer was cleared — there is no new owner to name")
        XCTAssertEqual(note.userInfo?["previousOwnerId"] as? String, owner.id.uuidString,
                       "who LOST the login is the only identity a clear can carry")
        XCTAssertEqual(note.userInfo?["cause"] as? String, "delete")
        XCTAssertNil(note.userInfo?["accountStamp"], "no owner, no account to stamp")
    }

    /// `cause` is what separates "the user switched accounts" from "the app read
    /// its own persisted pointer back into memory". Both move the pointer; only
    /// the first is a handover anyone should act on.
    ///
    /// The `activate` half asserts the value the three activation branches pass,
    /// not the branch itself: reaching that code applies real credentials to the
    /// shared Claude Keychain login / `~/.codex/auth.json` / `~/.grok/auth.json`,
    /// which no test in this suite may do. The `launchRepair` half runs its real
    /// path end to end — the store hydration inside `loadProfiles()`.
    func testTheCauseNamesThePathThatMovedThePointer() throws {
        let first = Profile(id: UUID(), name: "First")
        let second = Profile(id: UUID(), name: "Second")
        seed([first, second], focused: first.id)

        manager.claimActiveCodexOwnership(first.id, cause: .activate)
        XCTAssertEqual(posts(for: "codex").last?.userInfo?["cause"] as? String, "activate",
                       "an activation claims the login it has just written to the CLI")

        // Memory says `first`, the store says `second` — the shape a reload
        // finds after a pointer was persisted outside this process's copy.
        manager.claimActiveGrokOwnership(first.id)
        store.saveActiveGrokProfileId(second.id)
        recorder.clear()

        manager.loadProfiles()

        let grok = posts(for: "grok")
        XCTAssertEqual(grok.count, 1, "one hydration, one post")
        let note = try XCTUnwrap(grok.first)
        XCTAssertEqual(note.object as? UUID, second.id, "the restored pointer is the new owner")
        XCTAssertEqual(note.userInfo?["cause"] as? String, "launchRepair",
                       "nobody switched anything — the app restored what it had already persisted")
    }

    // MARK: - A pointer change repaints the fleet item

    /// The signal's newest consumer, and the reason the fleet item can now
    /// change owner without a focus change: the item paints from the LIVE
    /// pointers, and a switch onto the already-focused profile publishes no
    /// focus change at all — so this post is the ONLY thing that can repaint it
    /// (2026-09-04 16:38: the tile kept the previous Codex owner for ~30 s).
    func testAPointerChangeRequestsOneFleetRepaintOnTheNextTurn() {
        let first = Profile(id: UUID(), name: "First")
        let second = Profile(id: UUID(), name: "Second")
        seed([first, second], focused: first.id)
        manager.claimActiveCodexOwnership(first.id)

        let painted = expectation(description: "one fleet paint after the pointer moved")
        var reasons: [FleetRepaintScheduler.Reason] = []
        let scheduler = FleetRepaintScheduler(
            isBlocked: { false },
            paint: { reason in
                reasons.append(reason)
                painted.fulfill()
            }
        )
        scheduler.observeOwnerChanges()
        defer { scheduler.stopObserving() }

        manager.claimActiveCodexOwnership(second.id)

        XCTAssertEqual(scheduler.paintCount, 0,
                       "the paint waits for the next run-loop turn — never inline with the pointer write")
        wait(for: [painted], timeout: 2)
        XCTAssertEqual(reasons, [.ownerChanged])
    }

    /// N posts inside one turn are ONE paint. `loadProfiles()` can move all
    /// three pointers in a single call, and painting the bar three times for
    /// one fact is the flicker class the redesign removed.
    func testPointerChangesInsideOneTurnCoalesceIntoOnePaint() {
        var queued: [() -> Void] = []
        var paints = 0
        let scheduler = FleetRepaintScheduler(
            isBlocked: { false },
            paint: { _ in paints += 1 },
            enqueue: { queued.append($0) }
        )
        let center = NotificationCenter()
        scheduler.observeOwnerChanges(on: center)
        defer { scheduler.stopObserving(on: center) }

        for provider in ["claude", "codex", "grok"] {
            center.post(name: .providerOwnerClaimed, object: UUID(),
                        userInfo: ["provider": provider, "cause": "launchRepair"])
        }

        XCTAssertEqual(queued.count, 1, "the second and third posts were absorbed into the first request")
        XCTAssertEqual(paints, 0)
        queued.removeFirst()()
        XCTAssertEqual(paints, 1)
    }

    /// The sweep's final paint used to land between the credential write and
    /// the pointer save (16:38:39.984 — 1 ms before the Codex claim) and then be
    /// the LAST paint. A request that finds a switch in flight is held, and
    /// the switch completing paints once, whether or not anything was held.
    func testAPaintRequestedDuringASwitchIsHeldUntilTheSwitchCompletes() {
        var queued: [() -> Void] = []
        var switching = true
        var reasons: [FleetRepaintScheduler.Reason] = []
        let scheduler = FleetRepaintScheduler(
            isBlocked: { switching },
            paint: { reasons.append($0) },
            enqueue: { queued.append($0) }
        )

        scheduler.request(.sweepEnd)
        queued.removeFirst()()
        XCTAssertEqual(reasons, [], "no fleet paint lands while the switch is in flight")
        XCTAssertEqual(scheduler.heldReason, .sweepEnd)

        switching = false
        scheduler.switchCompleted()
        XCTAssertEqual(queued.count, 1)
        queued.removeFirst()()
        XCTAssertEqual(reasons, [.switchCompleted], "one paint, attributed to the switch that released it")
        XCTAssertNil(scheduler.heldReason)
    }
}
