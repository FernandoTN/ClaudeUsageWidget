//
//  PreferencesDegradationTests.swift
//  Claude UsageTests
//
//  Resilience against a wedged macOS preferences daemon (cfprefsd).
//
//  Live incident, 2026-09-01: cfprefsd lost access to plist files system-wide
//  ("rejecting write of key(s) … because Path not accessible"). Every in-process
//  `UserDefaults` read returned nil while `~/Library/Preferences/
//  com.claudeusagewidget.app.plist` sat intact on disk at 39 KB. Because
//  `loadProfiles()` re-reads many times per 30s sweep, one nil read emptied the UI —
//  and persisting that empty state after the daemon recovered would have destroyed a
//  20-profile roster.
//
//  Isolation: ProfileStore runs against the "com.claudeusagewidget.tests" suite under
//  XCTest (ProfileStore.init), and the plist fallback is DISABLED there unless a test
//  injects a path — these tests inject a temp file and never read or write the real
//  user domain (2026-07-28 tearDown incident). setUp/tearDown snapshot and restore
//  every defaults key they touch and reset the store's in-process shadow, which
//  outlives individual test cases.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class PreferencesDegradationTests: XCTestCase {

    private let profilesKey = "profiles_v3"
    private let displayModeKey = "profileDisplayMode"
    private let multiConfigKey = "multiProfileDisplayConfig"
    private let activeClaudeKey = "activeClaudeProfileId"
    private let store = ProfileStore.shared

    private var savedValues: [String: Any] = [:]
    private var testProfileIDs: [UUID] = []
    private var tempDirectory: URL?

    private var defaults: UserDefaults { ProfileStoreUsagePatchTests.testDefaults }
    private var touchedKeys: [String] { [profilesKey, displayModeKey, multiConfigKey, activeClaudeKey] }

    override func setUp() {
        super.setUp()
        savedValues = [:]
        for key in touchedKeys where defaults.object(forKey: key) != nil {
            savedValues[key] = defaults.object(forKey: key)
        }
        testProfileIDs = []
        store.resetPreferencesResilienceStateForTesting()
        store.setPreferencesPlistURLForTesting(nil)
        for key in touchedKeys { defaults.removeObject(forKey: key) }
    }

    override func tearDown() {
        for id in testProfileIDs {
            store.deleteProfileCredentials(profileId: id)
        }
        for key in touchedKeys {
            if let value = savedValues[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        store.setPreferencesPlistURLForTesting(nil)
        store.resetPreferencesResilienceStateForTesting()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        testProfileIDs = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func seed(_ names: [String]) -> [Profile] {
        let profiles = names.map { Profile(id: UUID(), name: $0) }
        testProfileIDs.append(contentsOf: profiles.map(\.id))
        store.saveProfiles(profiles)
        return profiles
    }

    /// Simulates the wedge: the key is unreadable while the store's shadow still
    /// holds what this process last observed.
    private func simulateWedgedRead(of key: String) {
        defaults.removeObject(forKey: key)
    }

    private func writeTemporaryPreferencesPlist(
        profiles: [Profile],
        displayMode: ProfileDisplayMode = .multi,
        config: MultiProfileDisplayConfig = MultiProfileDisplayConfig(iconStyle: .progressBar)
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefs-degradation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory

        let root: [String: Any] = [
            profilesKey: try JSONEncoder().encode(profiles),
            displayModeKey: displayMode.rawValue,
            multiConfigKey: try JSONEncoder().encode(config)
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let url = directory.appendingPathComponent("com.claudeusagewidget.app.plist")
        try plist.write(to: url)
        return url
    }

    // MARK: - Last-known-good profiles

    /// Given a good read has happened, When the next read comes back empty,
    /// Then the cached roster is served and the store reports degradation.
    func testEmptyReadAfterGoodReadServesCachedProfiles() {
        let seeded = seed(["Alpha", "Bravo"])
        XCTAssertEqual(store.loadProfiles().count, 2, "precondition: healthy read")
        XCTAssertFalse(store.preferencesDegraded)

        simulateWedgedRead(of: profilesKey)

        let served = store.loadProfiles()
        XCTAssertEqual(served.map(\.id), seeded.map(\.id), "empty read must serve the last-known-good roster")
        XCTAssertTrue(store.preferencesDegraded, "an empty read against a known roster is a degraded episode")
    }

    /// Given a degraded episode, When a later read succeeds, Then the flag clears.
    func testSuccessfulReadClearsDegradedFlag() throws {
        let seeded = seed(["Alpha", "Bravo"])
        let persisted = try XCTUnwrap(defaults.data(forKey: profilesKey))
        _ = store.loadProfiles()

        simulateWedgedRead(of: profilesKey)
        _ = store.loadProfiles()
        XCTAssertTrue(store.preferencesDegraded, "precondition: degraded")

        defaults.set(persisted, forKey: profilesKey)

        XCTAssertEqual(store.loadProfiles().map(\.id), seeded.map(\.id))
        XCTAssertFalse(store.preferencesDegraded, "a read that agrees with the shadow ends the episode")
    }

    // MARK: - Empty-overwrite guard

    /// A `[]` save is refused while a non-empty roster is known — the wedge's
    /// data-loss path (empty in memory, persisted once the daemon recovers).
    func testSaveProfilesRefusesEmptyWhenProfilesAreKnown() {
        let seeded = seed(["Alpha", "Bravo"])

        store.saveProfiles([])

        XCTAssertEqual(store.loadProfiles().map(\.id), seeded.map(\.id), "the empty write must not have landed")
        XCTAssertNotNil(defaults.data(forKey: profilesKey))
    }

    /// The guard is an accident filter, not a lock: an explicit delete-all persists,
    /// and neither fallback resurrects the deleted profiles afterwards.
    func testSaveProfilesAllowsEmptyWithExplicitFlag() throws {
        _ = seed(["Alpha", "Bravo"])

        store.saveProfiles([], allowEmpty: true)

        let persisted = try XCTUnwrap(defaults.data(forKey: profilesKey))
        XCTAssertEqual(try JSONDecoder().decode([Profile].self, from: persisted).count, 0)
        XCTAssertTrue(store.loadProfiles().isEmpty, "a deliberate delete-all must not be undone by the cache")
        XCTAssertFalse(store.preferencesDegraded, "an intentionally empty roster is not a degraded read")
    }

    // MARK: - Cold-launch plist fallback

    /// Given nothing loaded yet this process and no readable preferences,
    /// When the on-disk plist holds them, Then profiles AND both display settings are
    /// decoded from disk.
    ///
    /// The display half matters because the shadow is empty at launch, so a wedge that
    /// is already present when the app starts would otherwise hand back `.single` and
    /// `.default` (concentric) with no way to tell that from a fresh install. It also
    /// stops being self-healing the moment a caller hydrates these settings only once
    /// per process, which is why the repair lives in the store.
    func testColdLaunchFallsBackToOnDiskPreferencesPlist() throws {
        let onDisk = [Profile(id: UUID(), name: "From Disk A"), Profile(id: UUID(), name: "From Disk B")]
        let url = try writeTemporaryPreferencesPlist(
            profiles: onDisk,
            displayMode: .multi,
            config: MultiProfileDisplayConfig(iconStyle: .progressBar)
        )

        for key in touchedKeys { defaults.removeObject(forKey: key) }
        store.resetPreferencesResilienceStateForTesting()
        store.setPreferencesPlistURLForTesting(url)

        let loaded = store.loadProfiles()

        XCTAssertEqual(loaded.map(\.name), ["From Disk A", "From Disk B"])
        XCTAssertTrue(store.preferencesDegraded, "reading around UserDefaults is a degraded episode")

        // Same pass, back to back — the plist parse is throttled but must still answer
        // these two rather than throttling them out into type defaults.
        XCTAssertEqual(store.loadDisplayMode(), .multi, "cold-launch display mode must come from disk")
        XCTAssertEqual(
            store.loadMultiProfileConfig().iconStyle,
            .progressBar,
            "cold-launch icon style must come from disk, not .default's concentric"
        )

        XCTAssertEqual(
            ProfileStore.decodeProfilesFromPreferencesPlist(at: url)?.map(\.id),
            onDisk.map(\.id),
            "the decoder is read-only and reproducible"
        )
    }

    // MARK: - Display mode and multi-profile config

    /// A wedged read must not demote a multi-profile menu bar back to `.single`.
    func testDisplayModeFallsBackToLastKnownGood() {
        store.saveDisplayMode(.multi)
        XCTAssertEqual(store.loadDisplayMode(), .multi, "precondition: healthy read")

        simulateWedgedRead(of: displayModeKey)

        XCTAssertEqual(store.loadDisplayMode(), .multi, "nil read must not fall through to .single")
        XCTAssertTrue(store.preferencesDegraded)
    }

    /// The visible half of the incident: saved `.progressBar` tiles repainted as
    /// `.concentric` circles because the config read fell through to `.default`.
    func testMultiProfileConfigFallsBackToLastKnownGood() {
        let saved = MultiProfileDisplayConfig(iconStyle: .progressBar, showWeek: false)
        store.saveMultiProfileConfig(saved)
        XCTAssertEqual(store.loadMultiProfileConfig(), saved, "precondition: healthy read")

        simulateWedgedRead(of: multiConfigKey)

        let served = store.loadMultiProfileConfig()
        XCTAssertEqual(served, saved, "nil read must not fall through to .default")
        XCTAssertNotEqual(served, .default)
    }

    /// The active-pointer shadow distinguishes "cfprefsd is silent" from "the user
    /// cleared it": a wedged read is repaired, a deliberate `nil` save is respected.
    func testActiveClaudePointerRepairsWedgeButRespectsExplicitClear() {
        let id = UUID()
        store.saveActiveClaudeProfileId(id)
        XCTAssertEqual(store.loadActiveClaudeProfileId(), id, "precondition: healthy read")

        simulateWedgedRead(of: activeClaudeKey)
        XCTAssertEqual(store.loadActiveClaudeProfileId(), id, "a silent read must serve the known owner")
        XCTAssertTrue(store.preferencesDegraded)

        store.saveActiveClaudeProfileId(nil)
        XCTAssertNil(store.loadActiveClaudeProfileId(), "an explicit clear must not be re-filled from the shadow")
    }
}
