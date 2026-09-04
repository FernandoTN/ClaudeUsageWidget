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
        Self.testDefaults.removeObject(forKey: "autoSwitchProfileEnabled")
        Self.testDefaults.removeObject(forKey: "switchHistory_v1")
        Self.testDefaults.removeObject(forKey: "measuredSessionHistory_v1")
        Self.testDefaults.removeObject(forKey: "autoSwitchQueue")
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

    func testAutoSwitchQueueRoundTripAndDefault() {
        Self.testDefaults.removeObject(forKey: "autoSwitchQueue")
        // Default: empty queue = default switch behavior.
        XCTAssertEqual(sharedDataStore.loadAutoSwitchQueue(), [])

        let ids = [UUID(), UUID(), UUID()]
        sharedDataStore.saveAutoSwitchQueue(ids)
        XCTAssertEqual(sharedDataStore.loadAutoSwitchQueue(), ids)

        // Consuming the head persists the remainder in order.
        sharedDataStore.saveAutoSwitchQueue(Array(ids.dropFirst()))
        XCTAssertEqual(sharedDataStore.loadAutoSwitchQueue(), Array(ids.dropFirst()))

        Self.testDefaults.removeObject(forKey: "autoSwitchQueue")
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


    // MARK: - Preferences degradation (nil reads must not read as "empty")
    //
    // cfprefsd can refuse every read mid-run while the plist is intact on disk
    // (CLAUDE.md, "Preferences (cfprefsd) degradation"). Each loader below used
    // to map that onto its type default, which is a different WRONG answer in
    // each case: auto-switch off, no switch history, no projection basis, no
    // queued handoff. Removing the key from the shared test suite reproduces
    // exactly what the store sees during an episode — a nil read.
    //
    // Each test builds its OWN store so the shadow starts empty; the singleton
    // carries a process-lifetime shadow that other tests populate.

    func testAutoSwitchEnabledDefaultsFalseWithNoPriorGoodRead() {
        Self.testDefaults.removeObject(forKey: "autoSwitchProfileEnabled")
        // Given a store that has never seen a value, absence is still absence.
        XCTAssertFalse(SharedDataStore().loadAutoSwitchProfileEnabled())
    }

    func testAutoSwitchEnabledServesLastKnownGoodOnNilRead() {
        let store = SharedDataStore()
        store.saveAutoSwitchProfileEnabled(true)
        XCTAssertTrue(store.loadAutoSwitchProfileEnabled())

        // When the key becomes unreadable, the rotation must not silently
        // switch itself off (audit H8).
        Self.testDefaults.removeObject(forKey: "autoSwitchProfileEnabled")
        XCTAssertTrue(store.loadAutoSwitchProfileEnabled())

        // And a real user "off" still wins — the shadow tracks writes.
        Self.testDefaults.set(true, forKey: "autoSwitchProfileEnabled")
        store.saveAutoSwitchProfileEnabled(false)
        XCTAssertFalse(store.loadAutoSwitchProfileEnabled())
        Self.testDefaults.removeObject(forKey: "autoSwitchProfileEnabled")
        XCTAssertFalse(store.loadAutoSwitchProfileEnabled())
    }

    func testSwitchHistoryServesLastKnownGoodOnNilRead() {
        Self.testDefaults.removeObject(forKey: "switchHistory_v1")
        let store = SharedDataStore()
        XCTAssertEqual(store.loadSwitchHistory(), [])

        let event = SwitchEvent(at: Date(timeIntervalSince1970: 1_786_600_000),
                                from: "Harbor", to: "Fjord", trigger: .auto, reason: "session 96%")
        store.recordSwitchEvent(event)

        // A nil read here would make `attributeRateLimitEvent` stamp the
        // CURRENT owner instead of the account that hit the limit (audit M1).
        Self.testDefaults.removeObject(forKey: "switchHistory_v1")
        XCTAssertEqual(store.loadSwitchHistory(), [event])
    }

    func testMeasuredSessionHistoryServesLastKnownGoodOnNilRead() throws {
        Self.testDefaults.removeObject(forKey: "measuredSessionHistory_v1")
        let store = SharedDataStore()
        XCTAssertTrue(store.loadMeasuredSessionHistory().isEmpty)

        let id = UUID()
        let at = Date(timeIntervalSince1970: 1_786_600_000)
        store.saveMeasuredSessionHistory([id: [(at: at, pct: 74)]])

        // Losing this is losing the burn-rate projection basis — the frozen
        // 67%-at-a-real-100% failure of 2026-08-12 (audit M2).
        Self.testDefaults.removeObject(forKey: "measuredSessionHistory_v1")
        let served = store.loadMeasuredSessionHistory()
        let samples = try XCTUnwrap(served[id])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].pct, 74)
        XCTAssertEqual(samples[0].at.timeIntervalSince1970, at.timeIntervalSince1970, accuracy: 1)
    }

    func testAutoSwitchQueueServesLastKnownGoodOnNilRead() {
        Self.testDefaults.removeObject(forKey: "autoSwitchQueue")
        let store = SharedDataStore()
        XCTAssertEqual(store.loadAutoSwitchQueue(), [])

        let ids = [UUID(), UUID()]
        store.saveAutoSwitchQueue(ids)

        // The user's queued handoff plan must survive an unreadable key
        // (audit M3).
        Self.testDefaults.removeObject(forKey: "autoSwitchQueue")
        XCTAssertEqual(store.loadAutoSwitchQueue(), ids)
    }
}
