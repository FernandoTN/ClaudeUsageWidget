//
//  DisplaySettingsReloadTests.swift
//  Claude UsageTests
//
//  `ProfileManager.loadProfiles()` is both the startup load and the RELOAD path
//  (CLI credential self-heal, CLI / Codex account screens). It re-read the
//  store-backed display settings on every call, so a preferences read that came
//  back wrong silently reverted them.
//
//  That is the 2026-09-01 shape: a wedged `cfprefsd` made reads unreliable for
//  ~5.5 hours, ten runtime reloads landed inside that window, and every
//  menu-bar tile flipped from progress bars to circles
//  (`MultiProfileDisplayConfig.default` has `iconStyle: .concentric`) while the
//  on-disk plist still held `progressBar`.
//
//  Three layers now stand between that wedge and the user, and these tests are
//  scoped to the one the manager owns:
//    - `ProfileStore`'s last-known-good shadow answers an ABSENT read from the
//      value it last saw;
//    - the on-disk plist fallback answers a COLD-LAUNCH read, when neither the
//      defaults domain nor the shadow has anything;
//    - and the manager does not re-read at all for a setting the user chose
//      during this run, which is the only layer that can survive a read that
//      comes back PRESENT BUT STALE — such a read satisfies the shadow,
//      overwrites it, and propagates. The same wedge produced exactly that
//      shape elsewhere: two reloads read back a 19-profile roster where 20 were
//      stored.
//
//  The complement matters just as much: a setting the user has NOT chosen keeps
//  re-reading, so a cold launch into an already-wedged daemon still recovers
//  once preferences come back. Pinning every setting on the first load would
//  hold type defaults for the life of the process.
//
//  Isolation: same UserDefaults save/restore pattern as
//  ProfileStoreUsagePatchTests. Every key written here is restored in tearDown,
//  the store's resilience shadow is reset, and the manager is re-hydrated.
//  `ProfileStore` deliberately leaves `preferencesPlistURL` nil under XCTest, so
//  the plist fallback never reads the real user domain and the empty-read
//  fixtures below stay genuinely empty.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class DisplaySettingsReloadTests: XCTestCase {

    private let profilesKey = "profiles_v3"
    private let displayModeKey = "profileDisplayMode"
    private let multiProfileConfigKey = "multiProfileDisplayConfig"
    private let activeClaudeKey = "activeClaudeProfileId"

    private let store = ProfileStore.shared
    private let manager = ProfileManager.shared
    private var defaults: UserDefaults { ProfileStoreUsagePatchTests.testDefaults }

    private var savedProfilesData: Data?
    private var savedDisplayMode: String?
    private var savedMultiProfileConfig: Data?
    private var savedActiveClaude: String?
    private var savedManagerProfiles: [Profile] = []
    private var savedActiveProfile: Profile?
    private var seededIDs: [UUID] = []

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        savedProfilesData = defaults.data(forKey: profilesKey)
        savedDisplayMode = defaults.string(forKey: displayModeKey)
        savedMultiProfileConfig = defaults.data(forKey: multiProfileConfigKey)
        savedActiveClaude = defaults.string(forKey: activeClaudeKey)
        savedManagerProfiles = manager.profiles
        savedActiveProfile = manager.activeProfile
        manager.flushPendingUsage()

        // Deterministic profile array: `loadProfiles()` mints default profiles
        // (and reaches for the Keychain) when the store has none.
        let seeded = [
            Profile(name: "Alpha", claudeSessionKey: "sk-ant-sid01-alpha", organizationId: "org"),
            Profile(name: "Beta", claudeSessionKey: "sk-ant-sid01-beta", organizationId: "org")
        ]
        seededIDs = seeded.map(\.id)
        store.saveProfiles(seeded)

        // A shadow left warm by an earlier test would answer reads this file
        // deliberately starves.
        store.resetPreferencesResilienceStateForTesting()
        manager.displaySettingsChosenThisRun = []
    }

    override func tearDown() {
        manager.flushPendingUsage()
        for id in seededIDs {
            store.deleteProfileCredentials(profileId: id)
        }
        seededIDs = []

        // Restored with concretely-typed values: routing an `Optional<Data>`
        // through an `Any?` parameter re-wraps a nil into a non-nil `Any`, and
        // the restore would then write a bogus object back into the key.
        if let savedProfilesData {
            defaults.set(savedProfilesData, forKey: profilesKey)
        } else {
            defaults.removeObject(forKey: profilesKey)
        }
        if let savedMultiProfileConfig {
            defaults.set(savedMultiProfileConfig, forKey: multiProfileConfigKey)
        } else {
            defaults.removeObject(forKey: multiProfileConfigKey)
        }
        if let savedDisplayMode {
            defaults.set(savedDisplayMode, forKey: displayModeKey)
        } else {
            defaults.removeObject(forKey: displayModeKey)
        }
        if let savedActiveClaude {
            defaults.set(savedActiveClaude, forKey: activeClaudeKey)
        } else {
            defaults.removeObject(forKey: activeClaudeKey)
        }

        store.resetPreferencesResilienceStateForTesting()
        manager.displaySettingsChosenThisRun = []
        if savedProfilesData != nil {
            manager.loadProfiles()
        } else {
            manager.profiles = savedManagerProfiles
            manager.activeProfile = savedActiveProfile
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Makes the STORE genuinely report its type default for `key`.
    ///
    /// Clearing the UserDefaults key alone stopped being sufficient once
    /// `ProfileStore` gained its last-known-good shadow: the store answers an
    /// absent read from the value it last saw, so a control asserting "the store
    /// reports the default" would fail against a store that is doing its job.
    /// Resetting the shadow too is what actually reproduces the empty read.
    private func makeStoreReadComeBackEmpty(forKey key: String) {
        defaults.removeObject(forKey: key)
        store.resetPreferencesResilienceStateForTesting()
        XCTAssertNil(defaults.object(forKey: key), "fixture must actually clear \(key)")
    }

    /// Writes a value straight into the defaults domain, bypassing `ProfileStore`
    /// so its shadow is NOT updated. That is the read shape neither the shadow
    /// nor the plist fallback can catch: present, decodable, and older than what
    /// the user just chose.
    private func plantStaleStoredConfig(_ style: MultiProfileIconStyle) {
        let data = try? JSONEncoder().encode(MultiProfileDisplayConfig(iconStyle: style))
        defaults.set(data, forKey: multiProfileConfigKey)
    }

    // MARK: - Startup

    func testFirstLoadHydratesDisplaySettingsFromTheStore() {
        // Given: a store holding non-default display settings and a manager that
        // has chosen nothing yet — the startup shape.
        store.saveDisplayMode(.multi)
        store.saveMultiProfileConfig(MultiProfileDisplayConfig(iconStyle: .progressBar))
        manager.displayMode = .single
        manager.multiProfileConfig = .default

        // When
        manager.loadProfiles()

        // Then: startup hydration still happens. The fix narrows what a reload
        // re-reads; it must not stop the first load from reading at all.
        XCTAssertEqual(manager.displayMode, .multi)
        XCTAssertEqual(manager.multiProfileConfig.iconStyle, .progressBar)
    }

    // MARK: - A chosen setting survives a bad read

    func testReloadKeepsTheChosenIconStyleWhenBothTheKeyAndTheShadowAreEmpty() {
        // Given: the user picked bars.
        manager.loadProfiles()
        manager.updateMultiProfileConfig(MultiProfileDisplayConfig(iconStyle: .progressBar))

        // And: both layers below the manager are starved.
        makeStoreReadComeBackEmpty(forKey: multiProfileConfigKey)
        XCTAssertEqual(
            store.loadMultiProfileConfig().iconStyle, .concentric,
            "control: with the key and the shadow both gone the store must report its default"
        )

        // When
        manager.loadProfiles()

        // Then: the choice survives on the manager's own guarantee, with no
        // help from the store.
        XCTAssertEqual(manager.multiProfileConfig.iconStyle, .progressBar)
    }

    func testReloadKeepsTheChosenIconStyleAgainstAStalePresentRead() {
        // Given: the store held circles, and the user has just picked bars.
        store.saveMultiProfileConfig(MultiProfileDisplayConfig(iconStyle: .concentric))
        manager.loadProfiles()
        manager.updateMultiProfileConfig(MultiProfileDisplayConfig(iconStyle: .progressBar))
        XCTAssertEqual(manager.multiProfileConfig.iconStyle, .progressBar)

        // And: the daemon serves a stale snapshot that predates the pick. The
        // shadow cannot catch this — the read succeeds and overwrites it.
        plantStaleStoredConfig(.concentric)
        XCTAssertEqual(
            store.loadMultiProfileConfig().iconStyle, .concentric,
            "control: the store must actually serve the stale value, or this test proves nothing"
        )

        // When: any reload path runs (credential self-heal, CLI account screen).
        manager.loadProfiles()

        // Then: the user's choice survives. Before the fix this read back
        // `.concentric` and every menu-bar tile repainted as a circle.
        XCTAssertEqual(manager.multiProfileConfig.iconStyle, .progressBar)
    }

    func testReloadKeepsTheChosenDisplayModeAgainstAStalePresentRead() {
        // Given: the user turned multi-profile mode on this run.
        store.saveDisplayMode(.single)
        manager.loadProfiles()
        manager.updateDisplayMode(.multi)
        XCTAssertEqual(manager.displayMode, .multi)

        // And: the daemon serves the pre-choice snapshot.
        defaults.set(ProfileDisplayMode.single.rawValue, forKey: displayModeKey)
        XCTAssertEqual(store.loadDisplayMode(), .single, "control: the store must serve the stale value")

        // When
        manager.loadProfiles()

        // Then: the whole multi-profile menu bar does not collapse to one icon.
        XCTAssertEqual(manager.displayMode, .multi)
    }

    // MARK: - An unchosen setting still heals

    func testAnUnchosenSettingStillHealsWhenPreferencesRecover() {
        // Given: a cold launch INTO an already-wedged daemon. Nothing stored,
        // no shadow, no plist under XCTest, and the user has not touched the
        // setting, so the first load can only see the type default.
        makeStoreReadComeBackEmpty(forKey: multiProfileConfigKey)
        manager.loadProfiles()
        XCTAssertEqual(
            manager.multiProfileConfig.iconStyle, .concentric,
            "control: the cold-launch load must really have fallen back to the default"
        )

        // When: preferences recover and any reload runs.
        plantStaleStoredConfig(.progressBar)
        manager.loadProfiles()

        // Then: the stored value is adopted. Pinning every setting on the first
        // load would hold the type default for the life of the process instead.
        XCTAssertEqual(manager.multiProfileConfig.iconStyle, .progressBar)
    }

    // MARK: - Provider-active pointers

    func testProviderActivePointerSurvivesAnEmptyReadOnTheStoreShadow() {
        // The pointers are deliberately NOT pinned by the manager: they have
        // their own re-derivation path (`resolveProviderActiveAccounts` and the
        // launch repair) whose job is to correct them, so a reload must keep
        // re-reading. What protects them from an empty read is the store's
        // pointer shadow, which `claimActiveClaudeOwnership` warms on save.
        manager.loadProfiles()
        guard let owner = seededIDs.first else { return XCTFail("fixture profiles missing") }
        manager.claimActiveClaudeOwnership(owner)
        XCTAssertEqual(manager.activeClaudeProfileId, owner)

        defaults.removeObject(forKey: activeClaudeKey)
        XCTAssertEqual(
            store.loadActiveClaudeProfileId(), owner,
            "control: the shadow, not the manager, is what answers this read"
        )

        // When
        manager.loadProfiles()

        // Then
        XCTAssertEqual(manager.activeClaudeProfileId, owner)
    }
}
