//
//  SettingsKeyRegistryTests.swift
//  Claude UsageTests
//
//  The "no key lost" check the owner asked for (docs/specs/ux-revamp.md §5.2):
//  every key in the migration map is registered by its owner, the registry has
//  no duplicates, live keys say where they are edited, and the legacy Settings
//  sections route onto the pages that replace them.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class SettingsKeyRegistryTests: XCTestCase {
    /// The key column of the migration map, verbatim.
    private let migrationMap: [String] = [
        "profiles_v3", "activeProfileId", "activeClaudeProfileId", "activeCodexProfileId", "activeGrokProfileId",
        "profileDisplayMode", "multiProfileDisplayConfig",
        "credentialsMigratedToKeychain", "credentialsRepairedToKeychain_v2", "keychainItemsRebuiltViaSecurityTool_v3",
        "hasCompletedSetup", "hasShownWizardOnce", "debugAPILoggingEnabled",
        "shortcutTogglePopover", "shortcutRefresh", "shortcutOpenSettings", "shortcutNextProfile",
        "autoSwitchProfileEnabled", "autoSwitchThreshold", "autoSwitchWeeklyThreshold", "autoSwitchQueue",
        "popoverShowRemainingTime", "popoverTimeDisplay", "timeFormatPreference",
        "switchHistory_v1", "measuredSessionHistory_v1",
        "claudeDeadLogins_v1", "codexDeadLogins_v1", "grokDeadLogins_v1", "claudeContaminatedLogins_v1",
        "sentNotifications", "codexAutoImported_v1", "grokAutoImported_v1", "grokDisplayBackfill_v1",
        "legacyBundleDefaultsMigrated_v1",
        "menuBarIconConfiguration", "menuBarIconStyle", "monochromeMode",
        "claudeUsageData", "notificationsEnabled", "refreshInterval", "apiUsageData", "apiTrackingEnabled",
        "apiSessionKey", "apiOrganizationId", "showIconNames", "showNextSessionTime",
        "sessionIconEnabled", "sessionIconStyle", "sessionIconOrder",
        "weekIconEnabled", "weekIconStyle", "weekIconOrder", "weekDisplayMode",
        "apiIconEnabled", "apiIconStyle", "apiIconOrder", "apiDisplayMode",
        "menuBarLayoutDefault_v1", "debugTileLayout", "debugGroupExposure", "NSQuitAlwaysKeepsWindows",
        "autoSwitchCustomOrder", "autoSwitchCustomOrderEnabled", "cuwSlotPinsVersion",
        "fleetAlertDefaults_v1", "activeSelectorItem_v1", "codexDaemonRestartOnSwitch_v1",
    ]

    func testEveryKeyInTheMigrationMapIsRegistered() {
        let missing = migrationMap.filter { SettingsKeyRegistry.lookup($0) == nil }
        XCTAssertEqual(missing, [], "keys in the map with no registration")
    }

    func testRegistryHasNoDuplicatesAndNothingUnknownToTheMap() {
        let keys = SettingsKeyRegistry.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "a key registered twice")
        let extra = Set(keys).subtracting(migrationMap)
        XCTAssertEqual(extra, [], "registered keys the migration map does not know — add them to the spec table")
    }

    func testLiveKeysSayWhereTheyAreEdited() {
        let anonymous = SettingsKeyRegistry.live.filter { $0.ui == nil }.map(\.key)
        XCTAssertEqual(anonymous, [])
    }

    func testEachStoreRegistersItsOwnKeys() {
        XCTAssertTrue(SharedDataStore.registeredKeys.allSatisfy { $0.owner == .sharedDataStore })
        XCTAssertTrue(ProfileStore.registeredKeys.allSatisfy { $0.owner == .profileStore })
        XCTAssertTrue(SharedDataStore.registeredKeys.contains { $0.key == "fleetAlertDefaults_v1" && $0.status == .live })
        XCTAssertTrue(ProfileStore.registeredKeys.contains { $0.key == "activeGrokProfileId" && $0.status == .live })
        XCTAssertEqual(SettingsKeyRegistry.lookup("credentialsMigratedToKeychain")?.status, .migrationFlag)
        XCTAssertEqual(SettingsKeyRegistry.lookup("claudeUsageData")?.status, .legacyUnread)
    }

    func testUnregisteredAlarmIgnoresSystemKeysAndNamesOurs() {
        let onDisk = ["NSWindow Frame settings", "AppleLanguages", "profiles_v3", "NSQuitAlwaysKeepsWindows", "somethingNew_v9", "_apple_internal"]
        XCTAssertEqual(SettingsKeyRegistry.unregistered(in: onDisk), ["somethingNew_v9"])
        XCTAssertEqual(SettingsKeyRegistry.present(in: UserDefaults(suiteName: "com.claudeusagewidget.tests")!, bundleIdentifier: nil), [])
    }

    // MARK: Route aliases (spec §5.5, stage 3c)

    func testDeletedSectionsStillDecodeOntoTheirReplacements() {
        XCTAssertEqual(SettingsRoute(deepLink: "manageProfiles")?.section, .accounts)
        XCTAssertEqual(SettingsRoute(deepLink: "general")?.section, .accounts)
        XCTAssertEqual(SettingsRoute(deepLink: "cliAccount"), SettingsRoute(section: .accounts, tab: .login))
        XCTAssertEqual(SettingsRoute(deepLink: "codexAccount"), SettingsRoute(section: .accounts, tab: .login))
        XCTAssertEqual(SettingsRoute(deepLink: "appearance")?.section, .display)
        XCTAssertEqual(SettingsRoute(deepLink: "popover")?.section, .display)
        XCTAssertEqual(SettingsRoute(deepLink: "appSettings")?.section, .advanced)
        XCTAssertEqual(SettingsRoute(deepLink: "shortcuts")?.section, .advanced)
        XCTAssertNil(SettingsRoute(deepLink: "nope"))
        XCTAssertEqual(Set(SettingsRoute.legacyAliases.keys).intersection(SettingsSection.allCases.map(\.rawValue)), [],
                       "an alias never shadows a live section")
    }

    func testDisplayAndAdvancedSectionsAreRegistered() {
        XCTAssertEqual(SettingsSection.display.title, "Display")
        XCTAssertEqual(SettingsSection.advanced.title, "Advanced")
        XCTAssertEqual(SettingsRoute(deepLink: "display")?.section, .display)
        XCTAssertEqual(SettingsRoute(deepLink: "advanced")?.section, .advanced)
    }
}
