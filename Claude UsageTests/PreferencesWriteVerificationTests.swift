//
//  PreferencesWriteVerificationTests.swift
//  Claude UsageTests
//
//  The WRITE half of the cfprefsd degradation defence (audit C3).
//
//  Live incident, 2026-09-03: cfprefsd rejected this app's writes for two
//  minutes ("rejecting write of key(s) … because Path not accessible"). Keys
//  rewritten every sweep healed themselves when it ended; keys written ONCE did
//  not — both provider-owner pointers, the focus pointer and the switch-history
//  ring buffer were still stale on disk an hour later, with a relaunch about to
//  re-flag a working account dead. Nothing noticed, because the existing
//  detector watches nil READS and reads were fine throughout.
//
//  Measured the same day (see PlistPreferenceStoreSnapshot's table): every
//  in-process read-back reports success for a write the daemon threw away, and
//  the disk — the only source that disagrees — lags a HEALTHY write by up to
//  ten seconds. So the check is deferred past a flush grace and run once per
//  sweep, and these tests drive it directly with an injected store snapshot,
//  never the real preferences file.
//
//  Isolation: both stores run against the "com.claudeusagewidget.tests" suite
//  under XCTest, and the journal has NO snapshot source there unless a test
//  injects one. setUp/tearDown snapshot every key they touch and reset the
//  singletons' in-process state.
//

import XCTest
@testable import Claude_Usage

/// Stands in for the preferences store. `rejecting` names the keys cfprefsd is
/// refusing: a write to one of those never reaches `values`.
private final class FakePreferenceStore: PreferenceStoreSnapshotting {
    var rejecting: Set<String> = []
    private(set) var values: [String: Any] = [:]
    private(set) var snapshotCount = 0

    /// The app's UserDefaults write and this store's acceptance are separate
    /// events — the test calls this to model the daemon's side of a write.
    func accept(_ value: Any?, forKey key: String) {
        guard !rejecting.contains(key) else { return }
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }

    func snapshotAuthoritativeValues() -> [String: Any]? {
        snapshotCount += 1
        return values
    }
}

@MainActor
final class PreferencesWriteVerificationTests: XCTestCase {

    private let focusKey = "activeProfileId"
    private let claudeOwnerKey = "activeClaudeProfileId"
    private let codexOwnerKey = "activeCodexProfileId"
    private let displayModeKey = "profileDisplayMode"
    private let switchHistoryKey = "switchHistory_v1"
    private let autoSwitchQueueKey = "autoSwitchQueue"
    private let profilesKey = "profiles_v3"

    private let store = ProfileStore.shared
    private let sharedStore = SharedDataStore.shared
    private let journal = PreferenceWriteJournal.shared
    private var preferenceStore = FakePreferenceStore()

    private var defaults: UserDefaults { ProfileStoreUsagePatchTests.testDefaults }
    private var touchedKeys: [String] {
        [focusKey, claudeOwnerKey, codexOwnerKey, displayModeKey,
         switchHistoryKey, autoSwitchQueueKey, profilesKey]
    }
    private var savedValues: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        savedValues = [:]
        for key in touchedKeys where defaults.object(forKey: key) != nil {
            savedValues[key] = defaults.object(forKey: key)
        }
        store.resetPreferencesResilienceStateForTesting()
        sharedStore.resetPreferencesResilienceStateForTesting()
        store.setPreferencesPlistURLForTesting(nil)
        for key in touchedKeys { defaults.removeObject(forKey: key) }
        preferenceStore = FakePreferenceStore()
        journal.setSnapshotSourceForTesting(preferenceStore)
        // Judge writes immediately; the real grace exists only to outlast
        // cfprefsd's flush timer, which the fake does not have.
        journal.setFlushGraceForTesting(0)
    }

    override func tearDown() {
        journal.resetForTesting()
        for key in touchedKeys {
            if let value = savedValues[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        store.setPreferencesPlistURLForTesting(nil)
        store.resetPreferencesResilienceStateForTesting()
        sharedStore.resetPreferencesResilienceStateForTesting()
        super.tearDown()
    }

    /// Mirrors an app write into the fake store, the way the daemon would when
    /// it accepts one.
    private func daemonAccepts(_ value: Any?, forKey key: String) {
        preferenceStore.accept(value, forKey: key)
    }

    // MARK: - Detection

    /// Given cfprefsd is refusing a key, When the sweep check runs twice,
    /// Then the key is rewritten each time and the second miss raises the
    /// user-visible episode — even though the in-process read-back agrees with
    /// what was written, which is what makes this failure invisible.
    func testRejectedWriteIsRewrittenAndEscalatesOnTheSecondMiss() {
        preferenceStore.rejecting = [claudeOwnerKey]
        let id = UUID()

        store.saveActiveClaudeProfileId(id)
        XCTAssertEqual(
            defaults.string(forKey: claudeOwnerKey), id.uuidString,
            "the in-process read-back must still agree — that is the whole failure mode"
        )

        XCTAssertEqual(store.reassertPendingWrites(), 1, "first miss must rewrite immediately")
        XCTAssertEqual(journal.pendingKeys(for: .profileStore), [claudeOwnerKey])
        XCTAssertFalse(journal.isWriteDegraded, "one miss can be a slow flush — not yet user-visible")

        XCTAssertEqual(store.reassertPendingWrites(), 1, "second miss must rewrite again")
        XCTAssertTrue(journal.isWriteDegraded)
        XCTAssertTrue(store.preferencesDegraded, "a stranded write must raise the same banner a wedged read does")
    }

    /// A write the daemon accepted is found on the next check, rewrites nothing
    /// and leaves no episode behind.
    func testAcceptedWriteIsNotRewrittenAndNeverDegrades() {
        let id = UUID()
        store.saveActiveClaudeProfileId(id)
        daemonAccepts(id.uuidString, forKey: claudeOwnerKey)
        store.saveDisplayMode(.multi)
        daemonAccepts(ProfileDisplayMode.multi.rawValue, forKey: displayModeKey)

        XCTAssertEqual(store.reassertPendingWrites(), 0)
        XCTAssertTrue(journal.pendingKeys(for: .profileStore).isEmpty)
        XCTAssertFalse(journal.isWriteDegraded)
        XCTAssertFalse(store.preferencesDegraded)
    }

    /// A write is never judged inside the flush grace: a healthy write took up
    /// to 10 s to reach disk, so an immediate check reports every write as
    /// rejected (measured: 39 of 41).
    func testWriteIsNotJudgedInsideTheFlushGrace() {
        journal.setFlushGraceForTesting(nil)   // the real 20 s grace
        preferenceStore.rejecting = [codexOwnerKey]

        store.saveActiveCodexProfileId(UUID())

        XCTAssertEqual(store.reassertPendingWrites(), 0, "a just-written key must not be judged")
        XCTAssertTrue(journal.pendingKeys(for: .profileStore).isEmpty)
        XCTAssertFalse(journal.isWriteDegraded)
    }

    // MARK: - Recovery

    /// Given a stranded key and an open episode, When the daemon starts
    /// accepting again, Then the rewrite lands and the episode closes.
    func testEpisodeClosesOnceTheRewriteLands() {
        preferenceStore.rejecting = [codexOwnerKey]
        let id = UUID()
        store.saveActiveCodexProfileId(id)
        _ = store.reassertPendingWrites()
        _ = store.reassertPendingWrites()
        XCTAssertTrue(store.preferencesDegraded, "precondition: an episode is open")

        preferenceStore.rejecting = []
        _ = store.reassertPendingWrites()          // the rewrite the daemon now takes
        daemonAccepts(id.uuidString, forKey: codexOwnerKey)

        XCTAssertEqual(store.reassertPendingWrites(), 0)
        XCTAssertEqual(preferenceStore.values[codexOwnerKey] as? String, id.uuidString)
        XCTAssertTrue(journal.pendingKeys(for: .profileStore).isEmpty)
        XCTAssertFalse(journal.isWriteDegraded)
        XCTAssertFalse(store.preferencesDegraded)
    }

    /// Every remembered single-shot key is checked, not only ones already known
    /// bad: a rejection is invisible from inside the process, so a key that
    /// looked fine is no evidence that it landed. This is the live incident's
    /// shape — five stranded keys, none carrying a failure signal.
    func testASilentlyDroppedKeyIsCaughtWithNoPriorFailureSignal() {
        let focus = UUID()
        store.saveActiveProfileId(focus)
        daemonAccepts(focus.uuidString, forKey: focusKey)
        XCTAssertEqual(store.reassertPendingWrites(), 0, "precondition: nothing looks wrong")

        // The value disappears from the store with nothing in-process to notice.
        preferenceStore.accept(nil, forKey: focusKey)

        XCTAssertEqual(store.reassertPendingWrites(), 1, "the sweep must find it and rewrite it")
        daemonAccepts(focus.uuidString, forKey: focusKey)
        XCTAssertEqual(store.reassertPendingWrites(), 0)
        XCTAssertEqual(preferenceStore.values[focusKey] as? String, focus.uuidString)
    }

    /// Each store checks only its own keys, so a SharedDataStore key is not
    /// stranded by a ProfileStore sweep that found nothing to do.
    func testChecksAreScopedToTheOwningStore() {
        preferenceStore.rejecting = [switchHistoryKey]
        sharedStore.recordSwitchEvent(
            SwitchEvent(at: Date(), from: "Dex", to: "Cod", trigger: .manual, reason: nil)
        )

        XCTAssertEqual(store.reassertPendingWrites(), 0, "the ProfileStore sweep must not touch another store's key")
        XCTAssertEqual(sharedStore.reassertPendingWrites(), 1)
        XCTAssertEqual(journal.pendingKeys(for: .sharedDataStore), [switchHistoryKey])
        XCTAssertTrue(journal.pendingKeys(for: .profileStore).isEmpty)
    }

    // MARK: - Composition with the read-side detector

    /// The two halves are independent: reads were healthy throughout the
    /// 2026-09-03 episode, so a good read must not clear a banner that a
    /// stranded write raised.
    func testHealthyReadDoesNotClearAWriteDegradedEpisode() {
        let profiles = [Profile(id: UUID(), name: "Alpha")]
        store.saveProfiles(profiles)
        defer { profiles.forEach { store.deleteProfileCredentials(profileId: $0.id) } }

        preferenceStore.rejecting = [claudeOwnerKey]
        store.saveActiveClaudeProfileId(UUID())
        _ = store.reassertPendingWrites()
        _ = store.reassertPendingWrites()
        XCTAssertTrue(store.preferencesDegraded, "precondition: write-degraded")

        XCTAssertEqual(store.loadProfiles().count, 1, "reads stay healthy during a write-rejection episode")

        XCTAssertTrue(
            store.preferencesDegraded,
            "a healthy read must not retire a banner raised by a write that is still not in the store"
        )
    }
}
