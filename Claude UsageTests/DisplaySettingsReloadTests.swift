//
//  DisplaySettingsReloadTests.swift
//  Claude UsageTests
//
//  `ProfileManager.loadProfiles()` is both the startup load and the RELOAD path
//  (CLI credential self-heal, CLI / Codex account screens). It used to re-read
//  the four store-backed settings that are not part of the profile array —
//  display mode, multi-profile display config, and the two per-provider
//  active-login pointers — on every call, so a `UserDefaults` read that came
//  back empty silently reverted them to their defaults.
//
//  That is the 2026-09-01 shape: a wedged `cfprefsd` made reads unreliable for
//  ~5.5 hours, ten runtime reloads landed inside that window, and every
//  menu-bar tile flipped from progress bars to circles (`.default`'s
//  `iconStyle` is `.concentric`) while the on-disk plist still held
//  `progressBar`. The reset posts no cosmetics notification and logs nothing,
//  so nothing in the app or the unified log records that it happened.
//
//  Isolation: same UserDefaults save/restore pattern as
//  ProfileStoreUsagePatchTests — every key this file writes is restored in
//  tearDown, and the manager is re-hydrated from the restored store.
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

        // Re-hydrate the singleton from the restored store so later tests and
        // the live session see the pre-test settings, not this file's fixtures.
        manager.hasHydratedDisplaySettings = false
        if savedProfilesData != nil {
            manager.loadProfiles()
        } else {
            manager.profiles = savedManagerProfiles
            manager.activeProfile = savedActiveProfile
        }
        super.tearDown()
    }

    /// Simulates the read side of a wedged preferences daemon for one key: the
    /// value is gone, so `ProfileStore`'s loader takes its `.default` branch.
    /// Makes the STORE genuinely report its type default for `key`.
    ///
    /// Clearing the UserDefaults key alone stopped being sufficient once
    /// `ProfileStore` gained its last-known-good shadow: the store now answers an
    /// absent read from the value it last saw, so the control assertions below
    /// ("the store itself must now report the default, or this test proves
    /// nothing") would fail against a store that is doing its job. Resetting the
    /// shadow is what actually reproduces the empty read these tests are about,
    /// and it keeps them non-vacuous — with both layers defeated, the surviving
    /// setting can only come from the manager's once-per-process hydration.
    private func makeStoreReadComeBackEmpty(forKey key: String) {
        defaults.removeObject(forKey: key)
        store.resetPreferencesResilienceStateForTesting()
        XCTAssertNil(defaults.object(forKey: key), "fixture must actually clear \(key)")
    }

    // MARK: - Tests

    func testFirstLoadHydratesDisplaySettingsFromTheStore() {
        // Given: a store holding non-default display settings, and a manager
        // that has not hydrated them yet (the startup shape).
        store.saveDisplayMode(.multi)
        store.saveMultiProfileConfig(MultiProfileDisplayConfig(iconStyle: .progressBar))
        manager.hasHydratedDisplaySettings = false
        manager.displayMode = .single
        manager.multiProfileConfig = .default

        // When
        manager.loadProfiles()

        // Then: the startup hydration still happens — the fix must not turn
        // `loadProfiles()` into a no-op for these settings, only stop it
        // repeating on RELOADS.
        XCTAssertEqual(manager.displayMode, .multi)
        XCTAssertEqual(manager.multiProfileConfig.iconStyle, .progressBar)
        XCTAssertTrue(manager.hasHydratedDisplaySettings)
    }

    func testReloadKeepsTheChosenIconStyleWhenTheStoreReadComesBackEmpty() {
        // Given: the user picked progress bars, and the manager is hydrated.
        manager.hasHydratedDisplaySettings = false
        manager.loadProfiles()
        manager.updateMultiProfileConfig(MultiProfileDisplayConfig(iconStyle: .progressBar))
        XCTAssertEqual(manager.multiProfileConfig.iconStyle, .progressBar)

        // And: the preferences read stops answering for that key.
        makeStoreReadComeBackEmpty(forKey: multiProfileConfigKey)
        XCTAssertEqual(
            store.loadMultiProfileConfig().iconStyle, .concentric,
            "control: the store itself must now report the default, or this test proves nothing"
        )

        // When: any reload path runs (credential self-heal, CLI account screen).
        manager.loadProfiles()

        // Then: the user's choice survives. Before the fix this read back
        // `.concentric` and every menu-bar tile repainted as a circle.
        XCTAssertEqual(manager.multiProfileConfig.iconStyle, .progressBar)
    }

    func testReloadKeepsMultiProfileDisplayModeWhenTheStoreReadComesBackEmpty() {
        // Given: multi-profile mode is on. Set directly rather than through
        // `updateDisplayMode`, whose structural notification would rebuild the
        // test host's real status-bar items.
        manager.hasHydratedDisplaySettings = false
        manager.loadProfiles()
        manager.displayMode = .multi

        makeStoreReadComeBackEmpty(forKey: displayModeKey)
        XCTAssertEqual(store.loadDisplayMode(), .single, "control: the store must now report the default")

        // When
        manager.loadProfiles()

        // Then: the whole multi-profile menu bar does not collapse to one icon.
        XCTAssertEqual(manager.displayMode, .multi)
    }

    func testReloadKeepsTheProviderActivePointerWhenTheStoreReadComesBackEmpty() {
        // Given: a profile owns the shared Claude Code CLI login. This pointer
        // is the one Keychain adoption and syncToSystem key off — losing it is
        // a credential-contamination hazard, not a cosmetic one.
        manager.hasHydratedDisplaySettings = false
        manager.loadProfiles()
        guard let owner = seededIDs.first else { return XCTFail("fixture profiles missing") }
        manager.claimActiveClaudeOwnership(owner)
        XCTAssertEqual(manager.activeClaudeProfileId, owner)

        makeStoreReadComeBackEmpty(forKey: activeClaudeKey)
        XCTAssertNil(store.loadActiveClaudeProfileId(), "control: the store must now report no owner")

        // When
        manager.loadProfiles()

        // Then
        XCTAssertEqual(manager.activeClaudeProfileId, owner)
    }
}
