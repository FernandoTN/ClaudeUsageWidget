//
//  CodexUsageServiceTests.swift
//  Claude UsageTests
//
//  Tests for CodexUsageService's non-200 classification — specifically the 429
//  branch (audit H4). Before it existed, a throttled Codex account fell through
//  to a bare `.apiGenericError` with no `retryAfterSeconds`: MenuBarManager keys
//  BOTH the burst backoff and the account-throttle stamp off `.apiRateLimited`
//  plus that field, so the account got neither, was re-fetched every 30s sweep,
//  and the user was told to "re-sync your Codex account" for what was a rate
//  limit.
//
//  The response is stubbed as a constructed HTTPURLResponse rather than a live
//  endpoint — the classification is a pure function precisely so this is
//  possible without a URLProtocol double (the suite has none).
//

import XCTest
@testable import Claude_Usage

final class CodexUsageServiceTests: XCTestCase {

    /// Fixed locale + timezone so the rendered retry clock is deterministic.
    private func fixedClock() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    // MARK: - 429

    func testThrottled429IsTypedRateLimitedAndCarriesRetryAfter() {
        // Given: the usage endpoint refuses with an account-scale Retry-After.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = fixedClock()

        // When
        let error = CodexUsageService.usageFetchError(
            for: response(429, headers: ["Retry-After": "2918"]),
            now: now,
            clockFormatter: clock
        )

        // Then: the taxonomy MenuBarManager's throttle stamp and burst backoff
        // both key on — 2918s is well over accountThrottleRetryAfterFloor, so
        // this is the shape that stamps the account as exhausted.
        XCTAssertEqual(error.code, .apiRateLimited)
        XCTAssertEqual(error.retryAfterSeconds, 2918)
        XCTAssertGreaterThanOrEqual(
            error.retryAfterSeconds ?? 0,
            MenuBarManager.accountThrottleRetryAfterFloor
        )

        // And: the user is told when the app comes back, not to fix a login
        // that is not broken.
        XCTAssertTrue(error.message.contains("rate limited, retrying at "), error.message)
        XCTAssertTrue(error.message.hasSuffix(clock.string(from: now.addingTimeInterval(2918))),
                      error.message)
        XCTAssertFalse(error.message.lowercased().contains("re-sync"), error.message)
        XCTAssertFalse((error.recoverySuggestion ?? "").lowercased().contains("re-sync"))
    }

    /// The header goes through the shared `parseRetryAfter`, so the branch
    /// inherits its RFC 9110 coverage: an HTTP-date form is honored (it used to
    /// read as "no header"), an out-of-range value is clamped rather than
    /// blinding the tile for its full span, and a non-finite one is rejected
    /// before it can reach an `Int(_:)` conversion.
    func testRetryAfterFlowsThroughTheSharedParser() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // HTTP-date form, exactly 5 minutes past `now` (1_800_000_000 GMT is
        // Fri, 15 Jan 2027 08:00:00). This shape used to read as "no header".
        let dateForm = CodexUsageService.usageFetchError(
            for: response(429, headers: ["Retry-After": "Fri, 15 Jan 2027 08:05:00 GMT"]),
            now: now
        )
        XCTAssertEqual(dateForm.code, .apiRateLimited)
        XCTAssertEqual(dateForm.retryAfterSeconds, 300,
                       "an HTTP-date Retry-After must still reach the throttle stamp")

        // Clamped, not honored literally.
        let huge = CodexUsageService.usageFetchError(
            for: response(429, headers: ["Retry-After": "999999999"]), now: now
        )
        XCTAssertEqual(huge.retryAfterSeconds, retryAfterMaximum)

        // Non-finite is rejected outright — never an unguarded Int conversion.
        let bogus = CodexUsageService.usageFetchError(
            for: response(429, headers: ["Retry-After": "1e400"]), now: now
        )
        XCTAssertNil(bogus.retryAfterSeconds)

        // A 429 with no usable header still types as rate-limited (the burst
        // backoff's exponential guess takes over) and still avoids "re-sync".
        let bare = CodexUsageService.usageFetchError(for: response(429), now: now)
        XCTAssertEqual(bare.code, .apiRateLimited)
        XCTAssertNil(bare.retryAfterSeconds)
        XCTAssertTrue(bare.message.contains("rate limited"), bare.message)
        XCTAssertFalse(bare.message.lowercased().contains("re-sync"), bare.message)
    }

    // MARK: - Everything else keeps its existing taxonomy

    func testNon429StatusesAreUnchanged() {
        for status in [401, 403] {
            let error = CodexUsageService.usageFetchError(for: response(status))
            XCTAssertEqual(error.code, .apiUnauthorized, "status \(status)")
            XCTAssertNil(error.retryAfterSeconds, "status \(status)")
        }

        let serverError = CodexUsageService.usageFetchError(for: response(500))
        XCTAssertEqual(serverError.code, .apiGenericError)
        XCTAssertNil(serverError.retryAfterSeconds)
        // A genuinely unexplained failure DOES still point at a re-sync.
        XCTAssertEqual(serverError.recoverySuggestion, "Please re-sync your Codex account in Settings")
    }
}
