//
//  FleetInsightsTests.swift
//  Claude UsageTests
//
//  Stage 4a (docs/specs/ux-revamp.md §4): the insights model is pure and every
//  section derives from data the app already keeps.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class FleetInsightsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func usage(session: Double, weekly: Double, weeklyIn: TimeInterval, fable: Double? = nil, fableIn: TimeInterval? = nil, age: TimeInterval = 30) -> ClaudeUsage {
        var u = ClaudeUsage(sessionTokensUsed: 0, sessionLimit: 100, sessionPercentage: session, sessionResetTime: now.addingTimeInterval(3600),
                            weeklyTokensUsed: 0, weeklyLimit: 100, weeklyPercentage: weekly, weeklyResetTime: now.addingTimeInterval(weeklyIn),
                            opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0, sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0,
                            lastUpdated: now.addingTimeInterval(-age), userTimezone: .current)
        u.fableWeeklyPercentage = fable
        u.fableWeeklyResetTime = fableIn.map { now.addingTimeInterval($0) }
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?, account: String? = nil) -> Profile {
        var p = Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org")
        p.claudeUsage = u
        p.claudeAccountUUID = account
        return p
    }

    private func inputs(profiles: [Profile], selections: [ProviderActiveSelection] = [], history: [SwitchEvent] = [],
                        measured: [UUID: [(at: Date, pct: Double)]] = [:], incidents: [FleetInsights.Incident] = [],
                        backoffs: [UUID: FleetInsights.Backoff] = [:]) -> FleetInsights.Inputs {
        FleetInsights.Inputs(selections: selections, profiles: profiles, switchHistory: history, measured: measured,
                             incidents: incidents, drift: [], backoffs: backoffs, counts: [], now: now)
    }

    // MARK: Timeline

    func testTimelineHasOneMarkerPerDistinctAccountPerWindowInsideTheHorizon() {
        let a = claude("A", usage(session: 10, weekly: 60, weeklyIn: 3600, fable: 90, fableIn: 7200), account: "acct-1")
        let dup = claude("A-dup", usage(session: 10, weekly: 60, weeklyIn: 3600), account: "acct-1")
        let far = claude("Far", usage(session: 10, weekly: 20, weeklyIn: 8 * 24 * 3600))
        let past = claude("Past", usage(session: 10, weekly: 20, weeklyIn: -60))
        let markers = FleetInsights.build(inputs(profiles: [a, dup, far, past])).resetTimeline
        XCTAssertEqual(markers.map(\.name), ["A", "A"], "the duplicate row, the far reset and the past reset are all out")
        XCTAssertEqual(markers.map(\.window), [.weekly, .fable], "sorted by reset time")
        XCTAssertEqual(markers.map(\.headroomReturning), [60, 90])
    }

    // MARK: Burn

    func testBurnRateNeedsTwoSamplesTwentyFiveSecondsApartAndRising() {
        let s = { (offset: TimeInterval, pct: Double) in FleetInsights.Burn.Sample(at: self.now.addingTimeInterval(offset), pct: pct) }
        XCTAssertNil(FleetInsights.burnRate([s(0, 50)]))
        XCTAssertNil(FleetInsights.burnRate([s(0, 50), s(10, 60)]), "too close together")
        XCTAssertNil(FleetInsights.burnRate([s(0, 60), s(60, 50)]), "falling")
        XCTAssertEqual(FleetInsights.burnRate([s(0, 50), s(120, 54)])!, 2.0, accuracy: 0.001, "4 pp over 2 min")
    }

    func testBurnKeepsTheLastFourSamplesNewestLastAndSortsByRate() {
        let a = claude("A", usage(session: 50, weekly: 10, weeklyIn: 3600)), b = claude("B", usage(session: 50, weekly: 10, weeklyIn: 3600))
        let series = (0..<6).map { i in (at: now.addingTimeInterval(Double(i) * 60), pct: 40.0 + Double(i) * 2) }
        let flat = [(at: now, pct: 30.0), (at: now.addingTimeInterval(60), pct: 30.0)]
        let burn = FleetInsights.build(inputs(profiles: [a, b], measured: [a.id: series.shuffled(), b.id: flat])).burn
        XCTAssertEqual(burn.map(\.name), ["A", "B"], "rising first")
        XCTAssertEqual(burn[0].samples.count, 4)
        XCTAssertEqual(burn[0].samples.map(\.pct), [44, 46, 48, 50])
        XCTAssertEqual(burn[0].ratePerMinute!, 2.0, accuracy: 0.001)
        XCTAssertNil(burn[1].ratePerMinute)
    }

    // MARK: Switch log

    func testSwitchLogIsNewestFirstWithProviderInferredAndLegacyRowsMarked() {
        let a = claude("Fjord", usage(session: 10, weekly: 10, weeklyIn: 3600))
        let old = SwitchEvent(at: FleetInsights.viewingSplitDate.addingTimeInterval(-3600), from: "X", to: "Fjord", trigger: .manual, reason: nil)
        let new = SwitchEvent(at: now, from: "Fjord", to: "Gone", trigger: .auto, reason: "session 96 %", fromHeadroom: 4, providerRaw: "codex")
        let log = FleetInsights.build(inputs(profiles: [a], history: [old, new])).switchLog
        XCTAssertEqual(log.map(\.to), ["Gone", "Fjord"])
        XCTAssertEqual(log.map(\.isLegacy), [false, true])
        XCTAssertEqual(log[0].provider, .claude, "a name that resolves wins over the recorded raw provider")
        XCTAssertEqual(log[0].fromHeadroom, 4)
        XCTAssertEqual(log[1].provider, .claude)
    }

    /// The ring is persisted as JSON, so a field the encoder drops is a column
    /// the dashboard silently loses on the next launch.
    func testSwitchEventRoundTripsBothNewFields() throws {
        let event = SwitchEvent(at: Date(timeIntervalSince1970: 1_786_600_000), from: "Fjord", to: "Iris",
                                trigger: .auto, reason: "session 96 %", fromHeadroom: 3.5, providerRaw: "codex")
        let decoded = try JSONDecoder().decode(SwitchEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.fromHeadroom, 3.5)
        XCTAssertEqual(FleetInsights.providerKind(from: decoded.providerRaw ?? ""), .codex,
                       "the raw string must be the one `providerKind(from:)` reads back")
    }

    func testSwitchEventDecodesRowsWrittenBeforeTheNewFields() throws {
        let json = #"{"at":0,"from":"A","to":"B","trigger":"auto","reason":null}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(SwitchEvent.self, from: json)
        XCTAssertNil(event.fromHeadroom)
        XCTAssertNil(event.providerRaw)
    }

    // MARK: Incidents, drift, filter

    func testIncidentRingCapsAtOneHundredAndWindowsToADay() {
        let ring = IncidentRing()
        // Oldest first, as a live ring is fed; the ring keeps the 100 newest.
        for i in stride(from: 129, through: 0, by: -1) {
            ring.record(FleetInsights.Incident(at: now.addingTimeInterval(-Double(i) * 1800), profileId: nil, name: "A", provider: .claude, kind: .inferredStamp, detail: nil))
        }
        XCTAssertEqual(ring.entries.count, 100)
        XCTAssertEqual(ring.recent(now: now).count, 49, "every half-hour up to 24 h back")
        let built = FleetInsights.build(inputs(profiles: [], incidents: ring.entries)).incidents
        XCTAssertEqual(built.count, 49)
        XCTAssertEqual(built.first?.at, now, "newest first")
    }

    func testDriftLogRecordsTheNotificationPayload() {
        let center = NotificationCenter()
        let log = DriftLog(center: center)
        let id = UUID()
        center.post(name: .providerOwnerChangedExternally, object: id, userInfo: ["provider": "codex", "ownerName": "Petrel"])
        XCTAssertEqual(log.episodes.count, 1)
        XCTAssertEqual(log.episodes.first?.provider, .codex)
        XCTAssertEqual(log.episodes.first?.newOwnerId, id)
        XCTAssertEqual(log.episodes.first?.newOwnerName, "Petrel")
    }
}
