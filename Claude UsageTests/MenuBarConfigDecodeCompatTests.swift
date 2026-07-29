//
//  MenuBarConfigDecodeCompatTests.swift
//  Claude UsageTests
//
//  Phase 5.2 (packet H): decode-tolerant retirement of MenuBarMetricType.api and
//  Profile.apiUsage — existing UserDefaults / profiles_v3 blobs must keep decoding
//  after the API Console billing feature was removed.
//

import XCTest
@testable import Claude_Usage

final class MenuBarConfigDecodeCompatTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - MenuBarIconConfiguration + "api" metric

    func testMenuBarIconConfigurationWithAPIMetricDecodesAndPreservesEntry() throws {
        // Build a fixture the way a pre-cut install would have saved it: default
        // session/week metrics PLUS an explicit .api entry (case still present for
        // decode compatibility).
        let configWithAPI = MenuBarIconConfiguration(
            colorMode: .multiColor,
            singleColorHex: "#00BFFF",
            showIconNames: true,
            showRemainingPercentage: false,
            showTimeMarker: true,
            showPaceMarker: true,
            usePaceColoring: true,
            metrics: [
                .sessionDefault,
                .weekDefault,
                MetricIconConfig(
                    metricType: .api,
                    isEnabled: true,
                    iconStyle: .battery,
                    order: 2,
                    apiDisplayMode: .remaining
                )
            ]
        )

        let data = try encoder.encode(configWithAPI)
        let decoded = try decoder.decode(MenuBarIconConfiguration.self, from: data)

        // Decode must succeed and keep the legacy entry in the metrics array.
        let apiEntry = decoded.metrics.first { $0.metricType == .api }
        XCTAssertNotNil(apiEntry, "decoded config must preserve the 'api' metric entry")
        XCTAssertEqual(apiEntry?.isEnabled, true)
        XCTAssertEqual(apiEntry?.apiDisplayMode, .remaining)
        XCTAssertEqual(apiEntry?.order, 2)

        // Runtime surfaces must ignore .api even when it was enabled in saved JSON.
        XCTAssertFalse(
            decoded.enabledMetrics.contains { $0.metricType == .api },
            "enabledMetrics must exclude decode-only .api so no status item is minted"
        )
        XCTAssertEqual(decoded.enabledMetrics.map(\.metricType), [.session])
    }

    func testMenuBarIconConfigurationJSONLiteralWithAPIKeyDecodes() throws {
        // Hand-built JSON matching the wire shape of a saved metrics array entry.
        let json = """
        {
          "colorMode": "multiColor",
          "singleColorHex": "#00BFFF",
          "showIconNames": true,
          "showRemainingPercentage": false,
          "showTimeMarker": true,
          "showPaceMarker": false,
          "usePaceColoring": false,
          "metrics": [
            {
              "metricType": "session",
              "isEnabled": true,
              "iconStyle": "battery",
              "order": 0,
              "weekDisplayMode": "percentage",
              "apiDisplayMode": "remaining",
              "showNextSessionTime": false
            },
            {
              "metricType": "api",
              "isEnabled": true,
              "iconStyle": "battery",
              "order": 2,
              "weekDisplayMode": "percentage",
              "apiDisplayMode": "used",
              "showNextSessionTime": false
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(MenuBarIconConfiguration.self, from: json)
        XCTAssertEqual(decoded.metrics.count, 2)
        XCTAssertEqual(decoded.metrics.last?.metricType, .api)
        XCTAssertEqual(decoded.metrics.last?.apiDisplayMode, .used)
        XCTAssertFalse(decoded.enabledMetrics.contains { $0.metricType == .api })
    }

    // MARK: - Profile + apiUsage payload

    func testProfileWithAPIUsagePayloadDecodes() throws {
        let apiUsage = APIUsage(
            currentSpendCents: 4_200,
            resetsAt: Date(timeIntervalSince1970: 1_700_086_400),
            prepaidCreditsCents: 10_000,
            currency: "USD",
            apiTokenCostCents: 150.5,
            apiCostByModel: ["claude-3-5-sonnet": 100.0],
            costBySource: [
                APICostSource(
                    keyId: "key-1",
                    keyName: "CLI",
                    sourceType: .cli,
                    totalCents: 150.5,
                    costByModel: ["claude-3-5-sonnet": 100.0]
                )
            ],
            dailyCostCents: ["2026-07-01": 50.0]
        )

        let profile = Profile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Legacy API Profile",
            apiOrganizationId: "org_legacy",
            apiUsage: apiUsage
        )

        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(Profile.self, from: data)

        XCTAssertEqual(decoded.name, "Legacy API Profile")
        XCTAssertEqual(decoded.apiOrganizationId, "org_legacy")
        XCTAssertNotNil(decoded.apiUsage)
        XCTAssertEqual(decoded.apiUsage?.currentSpendCents, 4_200)
        XCTAssertEqual(decoded.apiUsage?.prepaidCreditsCents, 10_000)
        XCTAssertEqual(decoded.apiUsage?.currency, "USD")
        XCTAssertEqual(decoded.apiUsage?.apiTokenCostCents, 150.5)
        XCTAssertEqual(decoded.apiUsage?.apiCostByModel?["claude-3-5-sonnet"], 100.0)
        XCTAssertEqual(decoded.apiUsage?.costBySource?.count, 1)
        XCTAssertEqual(decoded.apiUsage?.costBySource?.first?.sourceType, .cli)
        XCTAssertEqual(decoded.apiUsage?.dailyCostCents?["2026-07-01"], 50.0)
    }
}
