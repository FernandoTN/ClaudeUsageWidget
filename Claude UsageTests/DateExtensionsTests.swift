import XCTest
@testable import Claude_Usage

final class DateExtensionsTests: XCTestCase {

    // MARK: - Time Remaining String Tests

    func testTimeRemainingHoursAndMinutes() {
        let now = Date()
        let future = now.addingTimeInterval(3 * 3600 + 45 * 60) // 3h 45m

        let result = future.timeRemainingString(from: now)
        XCTAssertEqual(result, "3h 45m")
    }

    func testTimeRemainingHoursOnly() {
        let now = Date()
        let future = now.addingTimeInterval(2 * 3600) // 2h exactly

        let result = future.timeRemainingString(from: now)
        XCTAssertEqual(result, "2h")
    }

    func testTimeRemainingMinutesOnly() {
        let now = Date()
        let future = now.addingTimeInterval(30 * 60) // 30m

        let result = future.timeRemainingString(from: now)
        XCTAssertEqual(result, "30m")
    }

    func testTimeRemainingDays() {
        let now = Date()
        let future = now.addingTimeInterval(3 * 24 * 3600) // 3 days

        let result = future.timeRemainingString(from: now)
        XCTAssertEqual(result, "3 days")
    }

    func testTimeRemainingOneDay() {
        let now = Date()
        let future = now.addingTimeInterval(24 * 3600) // 24 hours = 1 day exactly

        let result = future.timeRemainingString(from: now)
        XCTAssertEqual(result, "1 day")
    }

    func testTimeRemainingPast() {
        let now = Date()
        let past = now.addingTimeInterval(-3600) // 1 hour ago

        let result = past.timeRemainingString(from: now)
        XCTAssertEqual(result, "Reset now")
    }

    func testTimeRemainingLessThanMinute() {
        let now = Date()
        let future = now.addingTimeInterval(30) // 30 seconds

        let result = future.timeRemainingString(from: now)
        XCTAssertEqual(result, "< 1m")
    }

    // MARK: - Helpers

    private func createDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone.current

        return Calendar.current.date(from: components)!
    }
}
