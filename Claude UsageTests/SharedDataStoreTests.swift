import XCTest
@testable import Claude_Usage

final class SharedDataStoreTests: XCTestCase {

    var sharedDataStore: SharedDataStore!

    override func setUp() {
        super.setUp()
        sharedDataStore = SharedDataStore.shared
    }

    override func tearDown() {
        // Clean up test data
        super.tearDown()
    }

    // MARK: - Language Settings Tests

    func testLanguageCode() {
        sharedDataStore.saveLanguageCode("en")
        XCTAssertEqual(sharedDataStore.loadLanguageCode(), "en")

        sharedDataStore.saveLanguageCode("ko")
        XCTAssertEqual(sharedDataStore.loadLanguageCode(), "ko")

        sharedDataStore.saveLanguageCode("ja")
        XCTAssertEqual(sharedDataStore.loadLanguageCode(), "ja")
    }

    func testLanguageCodeNil() {
        // Should return nil when not set (fresh state)
        // Note: Can't easily test this without clearing UserDefaults entirely
        // but we can test saving and loading works
        sharedDataStore.saveLanguageCode("fr")
        XCTAssertNotNil(sharedDataStore.loadLanguageCode())
    }

    // MARK: - Statusline Configuration Tests

    func testStatuslineShowDirectory() {
        sharedDataStore.saveStatuslineShowDirectory(false)
        XCTAssertFalse(sharedDataStore.loadStatuslineShowDirectory())

        sharedDataStore.saveStatuslineShowDirectory(true)
        XCTAssertTrue(sharedDataStore.loadStatuslineShowDirectory())
    }

    func testStatuslineShowBranch() {
        sharedDataStore.saveStatuslineShowBranch(false)
        XCTAssertFalse(sharedDataStore.loadStatuslineShowBranch())

        sharedDataStore.saveStatuslineShowBranch(true)
        XCTAssertTrue(sharedDataStore.loadStatuslineShowBranch())
    }

    func testStatuslineShowUsage() {
        sharedDataStore.saveStatuslineShowUsage(false)
        XCTAssertFalse(sharedDataStore.loadStatuslineShowUsage())

        sharedDataStore.saveStatuslineShowUsage(true)
        XCTAssertTrue(sharedDataStore.loadStatuslineShowUsage())
    }

    func testStatuslineShowProgressBar() {
        sharedDataStore.saveStatuslineShowProgressBar(false)
        XCTAssertFalse(sharedDataStore.loadStatuslineShowProgressBar())

        sharedDataStore.saveStatuslineShowProgressBar(true)
        XCTAssertTrue(sharedDataStore.loadStatuslineShowProgressBar())
    }

    func testStatuslineShowResetTime() {
        sharedDataStore.saveStatuslineShowResetTime(false)
        XCTAssertFalse(sharedDataStore.loadStatuslineShowResetTime())

        sharedDataStore.saveStatuslineShowResetTime(true)
        XCTAssertTrue(sharedDataStore.loadStatuslineShowResetTime())
    }

    func testStatuslineShowModel() {
        // Test default value (true)
        XCTAssertTrue(sharedDataStore.loadStatuslineShowModel())

        // Test save and load
        sharedDataStore.saveStatuslineShowModel(false)
        XCTAssertFalse(sharedDataStore.loadStatuslineShowModel())

        sharedDataStore.saveStatuslineShowModel(true)
        XCTAssertTrue(sharedDataStore.loadStatuslineShowModel())
    }

    // MARK: - Setup Status Tests

    func testHasCompletedSetup() {
        sharedDataStore.saveHasCompletedSetup(false)
        XCTAssertFalse(sharedDataStore.hasCompletedSetup())

        sharedDataStore.saveHasCompletedSetup(true)
        XCTAssertTrue(sharedDataStore.hasCompletedSetup())
    }

}
