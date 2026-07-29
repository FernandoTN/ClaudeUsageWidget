import XCTest
@testable import Claude_Usage

final class SharedDataStoreTests: XCTestCase {

    var sharedDataStore: SharedDataStore!

    /// The store runs against the isolated test suite under XCTest (see
    /// SharedDataStore.init) — cleanup must target the same domain.
    static let testDefaults = UserDefaults(suiteName: "com.claudeusagewidget.tests")!

    override func setUp() {
        super.setUp()
        sharedDataStore = SharedDataStore.shared
    }

    override func tearDown() {
        Self.testDefaults.removeObject(forKey: "hasCompletedSetup")
        Self.testDefaults.removeObject(forKey: "autoSwitchThreshold")
        Self.testDefaults.removeObject(forKey: "autoSwitchWeeklyThreshold")
        super.tearDown()
    }

    // MARK: - Setup Status Tests

    func testHasCompletedSetup() {
        sharedDataStore.saveHasCompletedSetup(false)
        XCTAssertFalse(sharedDataStore.hasCompletedSetup())

        sharedDataStore.saveHasCompletedSetup(true)
        XCTAssertTrue(sharedDataStore.hasCompletedSetup())
    }

    // MARK: - Auto-Switch Threshold

    func testAutoSwitchThresholdDefaultsWhenNeverWritten() {
        Self.testDefaults.removeObject(forKey: "autoSwitchThreshold")
        XCTAssertEqual(sharedDataStore.loadAutoSwitchThreshold(), SharedDataStore.defaultAutoSwitchThreshold)
    }

    func testAutoSwitchThresholdRoundTrip() {
        sharedDataStore.saveAutoSwitchThreshold(90)
        XCTAssertEqual(sharedDataStore.loadAutoSwitchThreshold(), 90)
        sharedDataStore.saveAutoSwitchThreshold(100)
        XCTAssertEqual(sharedDataStore.loadAutoSwitchThreshold(), 100)
    }

    func testAutoSwitchCustomOrderRoundTripAndDefaults() {
        Self.testDefaults.removeObject(forKey: "autoSwitchCustomOrderEnabled")
        Self.testDefaults.removeObject(forKey: "autoSwitchCustomOrder")
        // Defaults: disabled, empty queue (= current behavior).
        XCTAssertFalse(sharedDataStore.loadAutoSwitchCustomOrderEnabled())
        XCTAssertEqual(sharedDataStore.loadAutoSwitchCustomOrder(), [])

        let ids = [UUID(), UUID(), UUID()]
        sharedDataStore.saveAutoSwitchCustomOrderEnabled(true)
        sharedDataStore.saveAutoSwitchCustomOrder(ids)
        XCTAssertTrue(sharedDataStore.loadAutoSwitchCustomOrderEnabled())
        XCTAssertEqual(sharedDataStore.loadAutoSwitchCustomOrder(), ids)

        sharedDataStore.saveAutoSwitchCustomOrderEnabled(false)
        Self.testDefaults.removeObject(forKey: "autoSwitchCustomOrder")
    }

    func testAutoSwitchWeeklyThresholdDefaultsAndRoundTrips() {
        Self.testDefaults.removeObject(forKey: "autoSwitchWeeklyThreshold")
        XCTAssertEqual(sharedDataStore.loadAutoSwitchWeeklyThreshold(), SharedDataStore.defaultAutoSwitchWeeklyThreshold)
        sharedDataStore.saveAutoSwitchWeeklyThreshold(97)
        XCTAssertEqual(sharedDataStore.loadAutoSwitchWeeklyThreshold(), 97)
        // Clamped like the session threshold.
        sharedDataStore.saveAutoSwitchWeeklyThreshold(150)
        XCTAssertEqual(sharedDataStore.loadAutoSwitchWeeklyThreshold(), SharedDataStore.autoSwitchThresholdRange.upperBound)
    }

    func testAutoSwitchThresholdClampsOutOfRangeValues() {
        // A hand-edited plist must not produce a threshold that switches
        // constantly (too low) or never proactively (above 100).
        sharedDataStore.saveAutoSwitchThreshold(10)
        XCTAssertEqual(sharedDataStore.loadAutoSwitchThreshold(), SharedDataStore.autoSwitchThresholdRange.lowerBound)
        sharedDataStore.saveAutoSwitchThreshold(150)
        XCTAssertEqual(sharedDataStore.loadAutoSwitchThreshold(), SharedDataStore.autoSwitchThresholdRange.upperBound)
    }

}
