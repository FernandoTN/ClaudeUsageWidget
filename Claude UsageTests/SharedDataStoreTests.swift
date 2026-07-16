import XCTest
@testable import Claude_Usage

final class SharedDataStoreTests: XCTestCase {

    var sharedDataStore: SharedDataStore!

    override func setUp() {
        super.setUp()
        sharedDataStore = SharedDataStore.shared
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "hasCompletedSetup")
        UserDefaults.standard.removeObject(forKey: "autoSwitchThreshold")
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
        UserDefaults.standard.removeObject(forKey: "autoSwitchThreshold")
        XCTAssertEqual(sharedDataStore.loadAutoSwitchThreshold(), SharedDataStore.defaultAutoSwitchThreshold)
    }

    func testAutoSwitchThresholdRoundTrip() {
        sharedDataStore.saveAutoSwitchThreshold(90)
        XCTAssertEqual(sharedDataStore.loadAutoSwitchThreshold(), 90)
        sharedDataStore.saveAutoSwitchThreshold(100)
        XCTAssertEqual(sharedDataStore.loadAutoSwitchThreshold(), 100)
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
