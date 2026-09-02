//
//  RetryAfterTests.swift
//  Claude UsageTests
//
//  `Retry-After` is the only server-supplied number that decides whether an
//  account is stamped exhausted or merely burst-limited, and every one of its
//  three parsing defects (audit 2026-09-01 H2/H3/H5) had a silent, distinct
//  consequence: a date-form header never stamped exhaustion at all, "1e400"
//  became +infinity and trapped in `Int(_:)`, and an unclamped value parked a
//  profile's usage fetch until the process died.
//

import XCTest
@testable import Claude_Usage

final class RetryAfterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_600_000)

    // MARK: - delta-seconds

    func testParsesDeltaSeconds() {
        // Given/When/Then: the shape the endpoint actually sends, including
        // the 2918s account-level refusal measured on 2026-07-16 and the
        // `retry-after: 0` of the 2026-08-11 incident (0 is data, not nil).
        XCTAssertEqual(parseRetryAfter("30", now: now), 30)
        XCTAssertEqual(parseRetryAfter("2918", now: now), 2918)
        XCTAssertEqual(parseRetryAfter("0", now: now), 0)
        XCTAssertEqual(parseRetryAfter("  45  ", now: now), 45)
        // Decimals are not RFC-legal but are emitted in the wild.
        XCTAssertEqual(parseRetryAfter("1.5", now: now), 1.5)
    }

    // MARK: - HTTP-date (the form that never stamped exhaustion)

    func testParsesHTTPDateForms() {
        // All three forms RFC 9110 requires a recipient to accept, each two
        // hours past `now` — well over the 60s account-throttle floor, which
        // is the whole point: this used to parse to nil and the account went
        // unstamped.
        let target = now.addingTimeInterval(7200)
        let imf = DateFormatter()
        imf.locale = Locale(identifier: "en_US_POSIX")
        imf.timeZone = TimeZone(identifier: "GMT")
        imf.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        let parsed = parseRetryAfter(imf.string(from: target), now: now)
        XCTAssertEqual(try XCTUnwrap(parsed), 7200, accuracy: 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(parsed), MenuBarManager.accountThrottleRetryAfterFloor)

        // asctime form.
        let asctime = DateFormatter()
        asctime.locale = Locale(identifier: "en_US_POSIX")
        asctime.timeZone = TimeZone(identifier: "GMT")
        asctime.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        XCTAssertEqual(try XCTUnwrap(parseRetryAfter(asctime.string(from: target), now: now)),
                       7200, accuracy: 1)

        // A date already in the past clamps to zero rather than going negative.
        XCTAssertEqual(parseRetryAfter(imf.string(from: now.addingTimeInterval(-600)), now: now), 0)
    }

    // MARK: - Hostile and malformed values

    func testRejectsNonFiniteNegativeAndGarbage() {
        // `Double("1e400")` is +infinity: it passed every `> 0` test and then
        // trapped in `Int(_:)`.
        XCTAssertNil(parseRetryAfter("1e400", now: now))
        XCTAssertNil(parseRetryAfter("inf", now: now))
        XCTAssertNil(parseRetryAfter("nan", now: now))
        XCTAssertNil(parseRetryAfter("-1", now: now))
        XCTAssertNil(parseRetryAfter("later", now: now))
        XCTAssertNil(parseRetryAfter("", now: now))
        XCTAssertNil(parseRetryAfter("   ", now: now))
        XCTAssertNil(parseRetryAfter(nil, now: now))
    }

    func testClampsToDocumentedMaximum() {
        XCTAssertEqual(parseRetryAfter("999999999", now: now), retryAfterMaximum)
        XCTAssertEqual(retryAfterMaximum, 86_400)
        // A far-future HTTP-date is clamped by the same ceiling.
        let imf = DateFormatter()
        imf.locale = Locale(identifier: "en_US_POSIX")
        imf.timeZone = TimeZone(identifier: "GMT")
        imf.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let farFuture = imf.string(from: now.addingTimeInterval(365 * 24 * 3600))
        XCTAssertEqual(parseRetryAfter(farFuture, now: now), retryAfterMaximum)
        // A value at the ceiling is honored exactly, not rejected.
        XCTAssertEqual(parseRetryAfter("86400", now: now), 86_400)
    }

    // MARK: - Int conversion

    func testClampedIntSaturatesInsteadOfTrapping() {
        // Each of these traps in `Int(_:)`; the whole point is that they no
        // longer reach one.
        XCTAssertEqual(clampedInt(.infinity), Int.max)
        XCTAssertEqual(clampedInt(-.infinity), Int.min)
        XCTAssertEqual(clampedInt(.nan), 0)
        XCTAssertEqual(clampedInt(1e300), Int.max)
        // Ordinary values are unchanged (truncating toward zero, as before).
        XCTAssertEqual(clampedInt(2918.9), 2918)
        XCTAssertEqual(clampedInt(0), 0)
        XCTAssertEqual(clampedInt(-7.5), -7)
    }
}
