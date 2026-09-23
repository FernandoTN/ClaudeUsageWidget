//
//  ClaudeLimitResetsTests.swift
//  Claude UsageTests
//
//  Claude limit resets (`cedar_ember` / `juniper_tide` in the `oauth/usage`
//  payload). Everything here is a decode against stubbed bytes or a pure
//  function; nothing touches the network.
//
//  The invariants:
//  - an empty or missing grant list is UNKNOWN, never zero — the server gives
//    this app `eligible: false`, reason `surface`, and `grants: []` on every
//    account today;
//  - a block the decoder cannot read never costs the rest of the usage
//    payload (the sweep is load-bearing for the auto-switch);
//  - every usage request carries `skip_spend=1`, and only one place in the
//    app builds that URL.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class ClaudeLimitResetsTests: XCTestCase {
    private let service = ClaudeAPIService()
    /// Whole seconds, so ISO-8601 strings built from it round-trip exactly.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
    }

    /// A usage payload with real windows plus whatever program fragments the
    /// test adds, spliced in raw so malformed shapes can be expressed.
    private func payload(_ extra: String = "") -> Data {
        """
        {
          "five_hour": { "utilization": 40.0, "resets_at": "\(iso(3600))" },
          "seven_day": { "utilization": 85.0, "resets_at": "\(iso(3 * 86400))" },
          "limits": [{ "kind": "weekly_scoped", "percent": 12, "resets_at": "\(iso(3 * 86400))",
                       "scope": { "model": { "display_name": "Fable" } } }],
          "spend": null,
          "extra_usage": null\(extra.isEmpty ? "" : ",\n" + extra)
        }
        """.data(using: .utf8)!
    }

    /// The windows every payload above carries — asserted after each decode
    /// so a program block can never cost the usage itself.
    private func assertUsageIntact(_ usage: ClaudeUsage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(usage.sessionPercentage, 40, file: file, line: line)
        XCTAssertEqual(usage.weeklyPercentage, 85, file: file, line: line)
        XCTAssertEqual(usage.fableWeeklyPercentage, 12, file: file, line: line)
    }

    private static let surfaceBlock = """
        "cedar_ember": { "eligible": false, "ineligible_reason": "surface", "at_limit": false, "exhausted": [],
                         "grants": [], "next_grant_id": null, "weekly_resets_at": null, "cooldown_until": null,
                         "event_props": null },
        "juniper_tide": { "eligible": false, "ineligible_reason": "surface", "in_experiment": false, "arm": null,
                          "available": false, "next_available_at": null, "weekly_resets_at": null,
                          "resets_per_week": 1, "event_props": null }
        """

    // MARK: - Decode

    func testGrantsPresentAreCountedWithTheirDetail() throws {
        let usage = try service.parseUsageResponse(payload("""
            "cedar_ember": { "eligible": true, "at_limit": true, "exhausted": ["five_hour"], "next_grant_id": "welcome",
              "weekly_resets_at": "\(iso(3 * 86400))",
              "grants": [
                { "id": "welcome", "label": "Welcome reset", "resets_left": 1, "resets_total": 2,
                  "starts_at": "\(iso(-86400))", "ends_at": "\(iso(9 * 86400))", "clears": ["five_hour", "seven_day"],
                  "blocking": ["seven_day_opus"], "use_requires_limit": true, "usable_now": true, "paused": false },
                { "id": "bonus", "resets_left": 2, "clears": ["five_hour"], "use_requires_limit": false, "usable_now": false }
              ] }
            """))
        assertUsageIntact(usage)
        XCTAssertEqual(usage.claudeLimitResetsAvailable, 3, "sum of resets_left over the grants")
        XCTAssertEqual(usage.claudeLimitResetsUsableNow, 1)
        XCTAssertNotNil(usage.claudeLimitResetsMeasuredAt)
        let bank = try XCTUnwrap(usage.claudeLimitResets?.bank)
        XCTAssertEqual(bank.eligible, true)
        XCTAssertEqual(bank.atLimit, true)
        XCTAssertEqual(bank.exhausted, ["five_hour"])
        XCTAssertEqual(bank.nextGrantId, "welcome")
        let welcome = try XCTUnwrap(bank.grants.first)
        XCTAssertEqual(welcome.label, "Welcome reset")
        XCTAssertEqual(welcome.resetsTotal, 2)
        XCTAssertEqual(welcome.clears, ["five_hour", "seven_day"])
        XCTAssertEqual(welcome.blocking, ["seven_day_opus"])
        XCTAssertTrue(welcome.useRequiresLimit)
        XCTAssertEqual(welcome.endsAt.map { Int($0.timeIntervalSince(now)) }, 9 * 86400)
        XCTAssertFalse(bank.grants[1].useRequiresLimit)
        XCTAssertNil(bank.grants[1].endsAt, "no deadline")
        XCTAssertNil(usage.claudeLimitResets?.unknownReason)
    }

    /// Today's live answer on every account. An empty list is not a zero.
    func testIneligibleWithEmptyGrantsIsUnknownNeverZero() throws {
        let usage = try service.parseUsageResponse(payload(Self.surfaceBlock))
        assertUsageIntact(usage)
        XCTAssertNil(usage.claudeLimitResetsAvailable)
        XCTAssertNil(usage.claudeLimitResetsUsableNow)
        XCTAssertNil(usage.claudeLimitResetsMeasuredAt, "no stamp beside an unknown")
        XCTAssertEqual(usage.claudeLimitResets?.unknownReason, "surface")
        XCTAssertEqual(usage.claudeLimitResets?.weeklySessionReset?.resetsPerWeek, 1)
        XCTAssertEqual(usage.claudeLimitResets?.weeklySessionReset?.available, false)
    }

    /// A plain read (the keys absent) and the null a plain read actually
    /// returns both leave everything unknown — the default before this change.
    func testAbsentOrNullKeysLeaveEverythingUnknown() throws {
        for extra in ["", #""cedar_ember": null, "juniper_tide": null"#] {
            let usage = try service.parseUsageResponse(payload(extra))
            assertUsageIntact(usage)
            XCTAssertNil(usage.claudeLimitResets, extra)
            XCTAssertNil(usage.claudeLimitResetsAvailable, extra)
            XCTAssertNil(usage.claudeLimitResetsMeasuredAt, extra)
        }
    }

    func testUnknownExtraKeysAreIgnored() throws {
        let usage = try service.parseUsageResponse(payload("""
            "cedar_ember": { "eligible": true, "brand_new": { "nested": [1, 2] },
              "grants": [{ "id": "g1", "resets_left": 2, "future_field": "x", "percent_used": { "five_hour": 100 } }] },
            "some_new_program": { "grants": [{ "resets_left": 9 }] }
            """))
        assertUsageIntact(usage)
        XCTAssertEqual(usage.claudeLimitResetsAvailable, 2)
    }

    /// Every malformed shape degrades to "unknown" without throwing and
    /// without touching the windows parsed from the same body.
    func testMalformedBlocksNeverCostTheUsagePayload() throws {
        let malformed = [
            #""cedar_ember": "garbage""#,
            #""cedar_ember": [1, 2, 3]"#,
            #""cedar_ember": { "grants": "not a list" }"#,
            #""cedar_ember": { "grants": [42] }"#,
            #""cedar_ember": { "grants": [{ "resets_left": 1 }] }"#,
            #""cedar_ember": { "grants": [{ "id": "g", "resets_left": "two" }] }"#,
            #""cedar_ember": { "grants": [{ "id": "g", "resets_left": true }] }"#,
            #""cedar_ember": { "grants": [{ "id": "g", "resets_left": -1 }] }"#,
            #""cedar_ember": { "grants": [{ "id": "g", "resets_left": 1.5 }] }"#,
            #""cedar_ember": { "eligible": "yes", "grants": [{ "id": "ok", "resets_left": 1 }, null] }"#,
            #""juniper_tide": "garbage""#,
        ]
        for extra in malformed {
            let usage = try service.parseUsageResponse(payload(extra))
            assertUsageIntact(usage)
            XCTAssertNil(usage.claudeLimitResetsAvailable, "an unreadable grant makes the sum unknown: \(extra)")
            XCTAssertNil(usage.claudeLimitResetsMeasuredAt, extra)
        }
        // The one readable grant is still kept for detail; only the count is withheld.
        let partial = try service.parseUsageResponse(payload(#""cedar_ember": { "grants": [{ "id": "ok", "resets_left": 1 }, 7] }"#))
        XCTAssertEqual(partial.claudeLimitResets?.bank?.grants.map(\.id), ["ok"])
        XCTAssertEqual(partial.claudeLimitResets?.bank?.hasUnreadableGrant, true)
        XCTAssertEqual(ClaudeLimitResetsFormatting.unknownExplanation(partial.claudeLimitResets),
                       "The last usage read listed a grant this app could not read.")
    }

    /// A grant past its use-by date is dropped, as the CLI drops it.
    func testExpiredGrantIsNotCounted() throws {
        let usage = try service.parseUsageResponse(payload("""
            "cedar_ember": { "eligible": true, "grants": [
              { "id": "old", "resets_left": 3, "ends_at": "\(iso(-60))" },
              { "id": "live", "resets_left": 1, "ends_at": "\(iso(86400))" } ] }
            """))
        XCTAssertEqual(usage.claudeLimitResetsAvailable, 1)
        XCTAssertEqual(usage.claudeLimitResets?.bank?.soonestUseBy(at: now).map { Int($0.timeIntervalSince(now)) }, 86400)
    }

    /// Usable-now needs every live grant to say; a paused grant is not usable.
    func testUsableNowIsUnknownUnlessEveryGrantSays() {
        func bank(_ grants: [[String: Any]]) -> ClaudeLimitResetBank? {
            ClaudeLimitResets.decode(usagePayload: ["cedar_ember": ["grants": grants]])?.bank
        }
        XCTAssertNil(bank([["id": "a", "resets_left": 1, "usable_now": true], ["id": "b", "resets_left": 1]])?.usableNowCount(at: now))
        XCTAssertEqual(bank([["id": "a", "resets_left": 2, "usable_now": true, "paused": true],
                             ["id": "b", "resets_left": 1, "usable_now": true]])?.usableNowCount(at: now), 1)
        XCTAssertEqual(bank([["id": "a", "resets_left": 2, "usable_now": false]])?.usableNowCount(at: now), 0,
                       "a stated false is a stated zero")
    }

    // MARK: - The read: skip_spend=1, always

    func testEveryUsageReadCarriesSkipSpend() throws {
        for read in ClaudeUsageRead.allCases {
            let url = try XCTUnwrap(read.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "api.anthropic.com")
            XCTAssertEqual(components.path, "/api/oauth/usage")
            let items = components.queryItems ?? []
            XCTAssertEqual(items.filter { $0.name == "skip_spend" }.map(\.value), ["1"], "\(read): \(url)")
            XCTAssertEqual(items.count, 2, "one program flag plus skip_spend: \(url)")
        }
        XCTAssertEqual(ClaudeUsageRead.status.url?.query, "cedar_ember=1&skip_spend=1")
        XCTAssertEqual(ClaudeUsageRead.atWall.url?.query, "at_wall=1&skip_spend=1")
    }

    /// `ClaudeUsageRead.url` must stay the ONLY place the usage URL is built,
    /// or a new call site could send a read without `skip_spend=1`. Scans the
    /// app's sources for a string literal naming the endpoint.
    func testUsageURLIsBuiltInExactlyOnePlace() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Claude Usage")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw XCTSkip("app sources not found at \(sources.path)")
        }
        let literal = try NSRegularExpression(pattern: #""[^"\n]*oauth/usage[^"\n]*""#)
        var hits: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                if literal.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    hits.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
                }
            }
        }
        XCTAssertEqual(hits.count, 1, hits.joined(separator: "\n"))
        XCTAssertTrue(hits.first?.contains(#"components.path = "/api/oauth/usage""#) == true, hits.joined(separator: "\n"))
    }

    /// The at-wall read only while the last measurement says the account is
    /// at a limit — never a wall the numbers do not show.
    func testAtWallReadOnlyAtAMeasuredLimit() {
        func usage(session: Double = 10, sessionResetIn: TimeInterval = 3600, weekly: Double = 10,
                   fable: Double? = nil) -> ClaudeUsage {
            var u = ClaudeUsage.empty
            u.sessionPercentage = session; u.sessionResetTime = now.addingTimeInterval(sessionResetIn)
            u.weeklyPercentage = weekly; u.weeklyResetTime = now.addingTimeInterval(86400)
            u.fableWeeklyPercentage = fable; u.fableWeeklyResetTime = fable == nil ? nil : now.addingTimeInterval(86400)
            return u
        }
        XCTAssertEqual(ClaudeUsageRead.choose(previous: nil, now: now), .status)
        XCTAssertEqual(ClaudeUsageRead.choose(previous: usage(session: 99.9), now: now), .status)
        XCTAssertEqual(ClaudeUsageRead.choose(previous: usage(session: 100), now: now), .atWall)
        XCTAssertEqual(ClaudeUsageRead.choose(previous: usage(session: 100, sessionResetIn: -1), now: now), .status,
                       "a session window that already reset is not a wall")
        XCTAssertEqual(ClaudeUsageRead.choose(previous: usage(weekly: 100), now: now), .atWall)
        XCTAssertEqual(ClaudeUsageRead.choose(previous: usage(fable: 100), now: now), .atWall)
    }

    // MARK: - Display

    func testCountLineNeverClaimsZeroForUnknown() {
        XCTAssertEqual(ClaudeLimitResetsFormatting.countLine(nil), "Limit resets: unknown")
        XCTAssertFalse(ClaudeLimitResetsFormatting.countLine(nil).contains("0"))
        XCTAssertEqual(ClaudeLimitResetsFormatting.countLine(2), "Limit resets: 2 left")
    }

    func testUnknownExplanationUsesTheServerReason() throws {
        XCTAssertEqual(ClaudeLimitResetsFormatting.unknownExplanation(nil), "Not reported by the last usage read.")
        let surface = try service.parseUsageResponse(payload(Self.surfaceBlock)).claudeLimitResets
        XCTAssertTrue(ClaudeLimitResetsFormatting.unknownExplanation(surface).hasPrefix("Claude reports limit resets only to Claude Code"))
        let other = ClaudeLimitResets.decode(usagePayload: ["cedar_ember": ["eligible": false, "ineligible_reason": "cli_version", "grants": []]])
        XCTAssertEqual(ClaudeLimitResetsFormatting.unknownExplanation(other), "Not reported to this app (server reason: cli_version).")
    }

    func testGrantLineNamesWhatItRefillsAndItsUseBy() throws {
        let grant = try XCTUnwrap(ClaudeLimitResets.decode(usagePayload: ["cedar_ember": ["grants": [
            ["id": "w", "label": "Welcome reset", "resets_left": 1, "resets_total": 2,
             "clears": ["five_hour", "seven_day", "seven_day_overage_included", "mystery_window"], "use_requires_limit": false],
        ]]])?.bank?.grants.first)
        XCTAssertEqual(ClaudeLimitResetsFormatting.grantLine(grant),
                       "Welcome reset · 1 of 2 left · refills session + weekly + mystery_window · usable before a limit")
    }

    func testWeeklySessionResetShownOnlyWhenEligible() {
        let ineligible = ClaudeWeeklySessionReset(eligible: false, ineligibleReason: "surface", inExperiment: false, arm: nil,
                                                  available: true, nextAvailableAt: nil, resetsPerWeek: 1)
        XCTAssertNil(ClaudeLimitResetsFormatting.weeklySessionResetLine(ineligible))
        XCTAssertNil(ClaudeLimitResetsFormatting.weeklySessionResetLine(nil))
        let available = ClaudeWeeklySessionReset(eligible: true, ineligibleReason: nil, inExperiment: true, arm: "reset",
                                                 available: true, nextAvailableAt: nil, resetsPerWeek: 1)
        XCTAssertEqual(ClaudeLimitResetsFormatting.weeklySessionResetLine(available), "Weekly session reset: available")
    }

    private func claudeProfile(_ name: String, _ extra: String?) throws -> Profile {
        let usage = try extra.map { try service.parseUsageResponse(payload($0)) }
        return Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org", claudeUsage: usage)
    }

    private func ownerRows(_ owner: Profile, others: [Profile] = []) -> [ActiveSelectorMenuModel.Row] {
        let context = FleetSummaryContext(
            thresholds: ReadinessThresholds(session: 95, weekly: 99),
            isLoginDead: { _ in false }, isExcluded: { _ in false },
            nextCandidates: [:], preflightVerdicts: [:],
            preferencesDegraded: false, isSwitching: false, now: now)
        let selections = ProviderActiveSelection.build(ProviderActiveSelection.Inputs(
            profiles: [owner] + others, activeIds: [owner.id], focusedId: nil, context: context, queue: []))
        return ActiveSelectorMenuModel.rows(selections: selections, preferencesDegraded: false,
                                            externalChanges: [:], switching: nil, now: now)
    }

    func testSelectorShowsTheClaudeOwnersCountOnlyWhenGrantsArrived() throws {
        let holding = try claudeProfile("Atlas", """
            "cedar_ember": { "eligible": true, "grants": [{ "id": "g", "resets_left": 2, "ends_at": "\(iso(9 * 86400))" }] }
            """)
        let row = try XCTUnwrap(ownerRows(holding).first { $0.title.hasPrefix("Limit resets") })
        XCTAssertTrue(row.title.hasPrefix("Limit resets: 2 left · use by "), row.title)
        XCTAssertFalse(row.enabled, "an info row — nothing to click, nothing to spend")

        for extra in [Self.surfaceBlock, "", nil] {
            let titles = ownerRows(try claudeProfile("Atlas", extra)).map(\.title)
            XCTAssertFalse(titles.contains { $0.contains("Limit resets") }, "unknown → no row, never \"0\": \(titles)")
        }
    }

    func testTooltipListsOnlyAccountsWithAKnownCount() throws {
        let holding = try claudeProfile("Cedar", #""cedar_ember": { "grants": [{ "id": "g", "resets_left": 2 }] }"#)
        let usedUp = try claudeProfile("Atlas", #""cedar_ember": { "grants": [{ "id": "g", "resets_left": 0, "resets_total": 1 }] }"#)
        let unknown = try claudeProfile("Fjord", Self.surfaceBlock)
        XCTAssertEqual(ClaudeLimitResetsFormatting.tooltipLine(profiles: [holding, usedUp, unknown]), "Limit resets: Cedar 2")
        XCTAssertNil(ClaudeLimitResetsFormatting.tooltipLine(profiles: [usedUp, unknown]))
    }

    // MARK: - Persistence

    /// The fields ride with the profile's usage in `profiles_v3`, exactly like
    /// the Codex count: through the store and back, unchanged.
    func testRoundTripsThroughTheProfileStore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.claudeusagewidget.tests"))
        let saved = defaults.data(forKey: "profiles_v3")
        defer {
            if let saved { defaults.set(saved, forKey: "profiles_v3") } else { defaults.removeObject(forKey: "profiles_v3") }
            _ = ProfileStore.shared.loadProfiles()
        }
        // No credentials on the fixture, so nothing reaches the Keychain.
        let usage = try service.parseUsageResponse(payload("""
            "cedar_ember": { "eligible": true, "grants": [{ "id": "g", "label": "Welcome reset", "resets_left": 2, "resets_total": 3,
              "ends_at": "\(iso(9 * 86400))", "clears": ["five_hour"], "usable_now": true }] },
            "juniper_tide": { "eligible": true, "available": false, "next_available_at": "\(iso(86400))", "resets_per_week": 1 }
            """))
        let profile = Profile(name: "Atlas", claudeUsage: usage)
        ProfileStore.shared.saveProfiles([profile])
        let bytes = try XCTUnwrap(defaults.data(forKey: "profiles_v3"))
        let reloaded = try XCTUnwrap(try JSONDecoder().decode([Profile].self, from: bytes).first { $0.id == profile.id })
        let before = try XCTUnwrap(profile.claudeUsage)
        let after = try XCTUnwrap(reloaded.claudeUsage)
        XCTAssertEqual(after.claudeLimitResetsAvailable, 2)
        XCTAssertEqual(after.claudeLimitResetsUsableNow, 2)
        XCTAssertEqual(after.claudeLimitResetsMeasuredAt, before.claudeLimitResetsMeasuredAt)
        XCTAssertEqual(after.claudeLimitResets, before.claudeLimitResets)
    }

    /// Usage cached before this change has none of the keys and must decode
    /// to "unknown", not fail.
    func testLegacyCachedUsageDecodesAsUnknown() throws {
        var legacy = ClaudeUsage.empty
        legacy.sessionPercentage = 33
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        for key in ["claudeLimitResets", "claudeLimitResetsAvailable", "claudeLimitResetsUsableNow", "claudeLimitResetsMeasuredAt"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(ClaudeUsage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.sessionPercentage, 33)
        XCTAssertNil(decoded.claudeLimitResets)
        XCTAssertNil(decoded.claudeLimitResetsAvailable)
    }
}
