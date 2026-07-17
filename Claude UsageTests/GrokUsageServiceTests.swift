import XCTest
@testable import Claude_Usage

/// Tests for GrokUsageService's pure parsing: the billing→ClaudeUsage mapping
/// and the xAI ISO-8601 variants (6-digit fractional seconds).
final class GrokUsageServiceTests: XCTestCase {

    func testParsesXAITimestampsWithMicrosecondFractions() {
        // The exact shapes auth.json and the billing endpoint emit.
        XCTAssertNotNil(GrokUsageService.parseISODate("2026-07-18T04:39:00.548618Z"))
        XCTAssertNotNil(GrokUsageService.parseISODate("2026-07-17T22:38:23.372161+00:00"))
        XCTAssertNotNil(GrokUsageService.parseISODate("2026-07-18T04:39:00Z"))
        XCTAssertNil(GrokUsageService.parseISODate("not-a-date"))
    }

    func testBillingResponseMapsWeeklyWindow() throws {
        // Fields present (post-usage account shape from the CLI's billing.rs schema).
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
          "start":"2026-07-17T22:38:23.372161+00:00","end":"2026-07-24T22:38:23.372161+00:00"},
          "creditUsagePercent":42.5,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},
          "isUnifiedBillingUser":true,"prepaidBalance":{"val":0}}}
        """
        let usage = try GrokUsageService.parseBillingResponse(Data(json.utf8))
        XCTAssertEqual(usage.weeklyPercentage, 42.5)
        XCTAssertEqual(usage.weeklyResetTime, GrokUsageService.parseISODate("2026-07-24T22:38:23.372161+00:00"))
        // No 5h session concept: raw 0% with a future reset (not rolled-over 0).
        XCTAssertEqual(usage.sessionPercentage, 0)
        XCTAssertEqual(usage.sessionResetTime, usage.weeklyResetTime)
        XCTAssertNil(usage.fableWeeklyPercentage)
    }

    func testBillingResponseWithOmittedUsageFieldsIsZeroPercent() throws {
        // Fresh account: usage fields omitted entirely — must read as 0, not fail.
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
          "start":"2026-07-17T22:38:23.372161+00:00","end":"2026-07-24T22:38:23.372161+00:00"},
          "onDemandCap":{"val":0},"isUnifiedBillingUser":true}}
        """
        let usage = try GrokUsageService.parseBillingResponse(Data(json.utf8))
        XCTAssertEqual(usage.weeklyPercentage, 0)
    }

    func testBillingResponseDerivesPercentFromWrappedUsedAndLimit() throws {
        // creditUsagePercent absent but included/limit present ({"val":n} wrappers).
        let json = """
        {"config":{"currentPeriod":{"end":"2026-07-24T22:38:23.372161+00:00"},
          "includedUsed":{"val":300},"monthlyLimit":{"val":1200}}}
        """
        let usage = try GrokUsageService.parseBillingResponse(Data(json.utf8))
        XCTAssertEqual(usage.weeklyPercentage, 25)
    }

    func testMalformedBillingResponseThrows() {
        XCTAssertThrowsError(try GrokUsageService.parseBillingResponse(Data("{}".utf8)))
    }
}
