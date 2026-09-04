//
//  FleetAlertsTests.swift
//  Claude UsageTests
//
//  Fleet alert defaults with a per-account override (docs/specs/ux-revamp.md
//  §5.2 `fleetAlertDefaults_v1`, D11): the migration rule for profiles saved
//  before the flag existed, the one resolution seam, the seed, the overrides
//  list, the summary line, and the journaled + shadowed store key.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class FleetAlertsTests: XCTestCase {
    private static let testDefaults = UserDefaults(suiteName: "com.claudeusagewidget.tests")!
    private let custom = NotificationSettings(enabled: true, threshold75Enabled: false, threshold90Enabled: true,
                                              threshold95Enabled: true, soundName: "none", customThresholds: [50])

    private func legacy(_ name: String, _ settings: NotificationSettings) -> Profile {
        var p = Profile(name: name)
        p.usesFleetAlertDefaults = nil   // saved before the flag existed
        p.notificationSettings = settings
        return p
    }

    override func tearDown() {
        Self.testDefaults.removeObject(forKey: "fleetAlertDefaults_v1")
        super.tearDown()
    }

    // MARK: Migration rule

    func testUntouchedDefaultsFollowTheFleetWhenTheFlagIsAbsent() {
        XCTAssertTrue(legacy("A", NotificationSettings()).followsFleetAlertDefaults)
    }

    func testCustomizedSettingsKeepTheirOverrideWhenTheFlagIsAbsent() {
        XCTAssertFalse(legacy("A", custom).followsFleetAlertDefaults)
    }

    func testAnExplicitFlagWinsOverTheRule() {
        var own = legacy("A", NotificationSettings()); own.usesFleetAlertDefaults = false
        var follows = legacy("B", custom); follows.usesFleetAlertDefaults = true
        XCTAssertFalse(own.followsFleetAlertDefaults)
        XCTAssertTrue(follows.followsFleetAlertDefaults)
    }

    func testNewProfilesFollowTheFleet() {
        XCTAssertEqual(Profile(name: "New").usesFleetAlertDefaults, true)
    }

    func testDecodingAProfileSavedBeforeTheFlagLeavesItNil() throws {
        let data = try JSONEncoder().encode(legacy("Old", custom))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["usesFleetAlertDefaults"], "nil encodes as absent")
        json["usesFleetAlertDefaults"] = nil
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.usesFleetAlertDefaults)
        XCTAssertFalse(decoded.followsFleetAlertDefaults, "customized → keeps its override")
    }

    // MARK: Resolution

    func testEffectiveSettingsResolveThroughTheFlag() {
        let fleet = NotificationSettings(enabled: false)
        XCTAssertEqual(legacy("A", NotificationSettings()).effectiveNotificationSettings(fleet: fleet), fleet)
        XCTAssertEqual(legacy("B", custom).effectiveNotificationSettings(fleet: fleet), custom)
    }

    // MARK: Seed

    func testSeedPromotesIdenticalSettingsAndOtherwiseUsesTheDefaults() {
        XCTAssertEqual(FleetAlerts.seed(from: []), NotificationSettings())
        XCTAssertEqual(FleetAlerts.seed(from: [legacy("A", custom), legacy("B", custom)]), custom, "every profile identical → promoted")
        XCTAssertEqual(FleetAlerts.seed(from: [legacy("A", custom), legacy("B", NotificationSettings())]), NotificationSettings())
    }

    // MARK: Overrides + summary

    func testOverridesListNamesOnlyTheProfilesWithTheirOwnSettings() {
        let rows = FleetAlerts.overrides(in: [legacy("Follows", NotificationSettings()), legacy("Own", custom), legacy("Same", NotificationSettings(enabled: false))],
                                         fleet: NotificationSettings(enabled: false))
        XCTAssertEqual(rows.map(\.name), ["Own", "Same"])
        XCTAssertEqual(rows.map(\.differsFromFleet), [true, false], "an override equal to the fleet is flagged as such")
        XCTAssertEqual(FleetAlerts.followerCount(in: [legacy("Follows", NotificationSettings()), legacy("Own", custom)]), 1)
    }

    func testSummaryLine() {
        XCTAssertEqual(FleetAlerts.summary(NotificationSettings()), "75 · 90 · 95 % · default sound")
        XCTAssertEqual(FleetAlerts.summary(custom), "50 · 90 · 95 % · no sound")
        XCTAssertEqual(FleetAlerts.summary(NotificationSettings(enabled: false)), "off")
        XCTAssertEqual(FleetAlerts.summary(NotificationSettings(threshold75Enabled: false, threshold90Enabled: false, threshold95Enabled: false, soundName: "Glass")),
                       "no thresholds · Glass")
    }

    // MARK: Store

    func testStoreRoundTripsAndServesTheShadowOnANilRead() {
        let store = SharedDataStore()
        store.resetPreferencesResilienceStateForTesting()
        Self.testDefaults.removeObject(forKey: "fleetAlertDefaults_v1")
        XCTAssertFalse(store.hasFleetAlertDefaults())
        XCTAssertEqual(store.loadFleetAlertDefaults(), NotificationSettings(), "absent with no prior good read → the type defaults")

        store.saveFleetAlertDefaults(custom)
        XCTAssertTrue(store.hasFleetAlertDefaults())
        XCTAssertEqual(store.loadFleetAlertDefaults(), custom)

        Self.testDefaults.removeObject(forKey: "fleetAlertDefaults_v1")
        XCTAssertEqual(store.loadFleetAlertDefaults(), custom, "a nil read after a good one is served from the shadow")
        store.resetPreferencesResilienceStateForTesting()
        XCTAssertEqual(store.loadFleetAlertDefaults(), NotificationSettings())
    }

    func testAlertsSectionIsRegistered() {
        XCTAssertTrue(SettingsSection.allCases.contains(.alerts))
        XCTAssertEqual(SettingsSection.alerts.title, "Alerts")
        XCTAssertEqual(SettingsRoute(deepLink: "alerts")?.section, .alerts)
    }
}
