//
//  TelemetryCompactionTests.swift
//  Claude UsageTests
//
//  Stage 4c: folding raw events older than the compaction age into minute
//  rows must be invisible to the report — same aggregation, same distinct
//  sessions, same time span, same unit count — and a replay of folded units
//  must be dropped, not counted twice.
//

import XCTest
@testable import Claude_Usage

final class TelemetryCompactionTests: XCTestCase {
    private var directory: URL!
    private var ledger: TelemetryLedger!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cuw-compaction-\(UUID().uuidString)")
        ledger = try TelemetryLedger(url: directory.appendingPathComponent("ledger.sqlite"))
    }

    override func tearDownWithError() throws {
        ledger = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func event(_ id: String, provider: TelemetryProvider = .claude, daysAgo: Double, model: String = "claude-opus-5",
                       session: String = "s1", source: String? = "proj", sidechain: Bool = false, file: String = "f1",
                       cost: Int? = nil, output: Int = 10, inFlight: Bool = false) -> TelemetryEvent {
        TelemetryEvent(unitId: id, provider: provider, at: now.addingTimeInterval(-daysAgo * day), model: model, input: 7,
                       cacheRead: 40_000, cacheWrite: 3_000, cacheWrite1h: 1_000, output: output, reasoning: output / 2,
                       reportedCostNanoUSD: cost, session: session, sidechain: sidechain, source: source, fileId: file,
                       sourceOffset: 0, parserVersion: 1, inFlight: inFlight)
    }

    /// 200 days of events: several sessions and sources per minute, both
    /// sidechain values, every provider, a Grok cost, one in-flight relic.
    private func seed() throws -> [TelemetryEvent] {
        var events: [TelemetryEvent] = []
        for d in stride(from: 0, through: 200, by: 4) {
            let daysAgo = Double(d) + 0.3
            let file = "f\((d / 4) % 2)"
            events.append(event("c\(d)a", daysAgo: daysAgo, session: "s\(d % 3)", file: file))
            // 17 s later in the same minute, same key as the row above: the two fold into one minute row.
            events.append(event("c\(d)a2", daysAgo: daysAgo - 0.0002, session: "s\(d % 3)", file: file, output: 4))
            events.append(event("c\(d)b", daysAgo: daysAgo, session: "s\(d % 3)", sidechain: true, file: file))
            events.append(event("c\(d)c", daysAgo: daysAgo + 0.0001, model: "claude-sonnet-5", session: "s9", source: nil, file: file))
            events.append(event("x\(d)", provider: .codex, daysAgo: daysAgo, model: "gpt-5.6-sol", session: "r\(d)", source: "exec", file: "r\(d)"))
            events.append(event("g\(d)", provider: .grok, daysAgo: daysAgo, model: "grok-4.6-build", session: "gk", source: "cwd", file: "g", cost: 1_000_000))
        }
        events.append(event("stale-in-flight", daysAgo: 150, file: "f1", inFlight: true))
        try ledger.upsert(events)
        return events
    }

    private struct Snapshot: Equatable {
        var aggregates: [MinuteAggregate]
        var codexSessions: Int
        var claudeSessions: Int
        var count: Int
        var span: Date?
        var spanEnd: Date?
    }

    private func snapshot() throws -> Snapshot {
        let from = now.addingTimeInterval(-400 * day)
        let span = try ledger.eventTimeSpan()
        return Snapshot(aggregates: try ledger.aggregateMinutes(from: from, to: now),
                        codexSessions: try ledger.distinctSessions(provider: .codex, from: from, to: now),
                        claudeSessions: try ledger.distinctSessions(provider: .claude, from: from, to: now),
                        count: try ledger.eventCount(), span: span?.from, spanEnd: span?.to)
    }

    func testCompactionIsInvisibleToTheReport() throws {
        _ = try seed()
        let before = try snapshot()
        XCTAssertEqual(try ledger.compactedMinuteRows(), 0)
        let rawBefore = try ledger.rawEventCount()

        let report = try ledger.compact(before: now.addingTimeInterval(-90 * day))
        XCTAssertFalse(report.remaining)
        XCTAssertGreaterThan(report.daysProcessed, 20)
        XCTAssertGreaterThan(report.eventsRemoved, 100)
        XCTAssertEqual(try ledger.rawEventCount(), rawBefore - report.eventsRemoved)
        XCTAssertGreaterThan(try ledger.compactedMinuteRows(), 0)
        XCTAssertLessThan(try ledger.compactedMinuteRows(), report.eventsRemoved, "sessions sharing a minute fold together")

        let after = try snapshot()
        XCTAssertEqual(after.aggregates, before.aggregates, "the minute aggregation is the same set of rows")
        XCTAssertEqual(after.codexSessions, before.codexSessions)
        XCTAssertEqual(after.claudeSessions, before.claudeSessions)
        XCTAssertEqual(after.count, before.count, "units are counted once, raw or folded")
        XCTAssertEqual(after.span, before.span)
        XCTAssertEqual(after.spanEnd, before.spanEnd)
        // Nothing younger than the cutoff moved.
        let young = try ledger.aggregateMinutes(from: now.addingTimeInterval(-89 * day), to: now)
        XCTAssertEqual(young, before.aggregates.filter { $0.minute >= now.addingTimeInterval(-89 * day) })
    }

    func testInFlightRowsStayRawAndAreCountedOnce() throws {
        _ = try seed()
        let countBefore = try ledger.eventCount()
        try ledger.compact(before: now.addingTimeInterval(-90 * day))
        // The stale in-flight relic is still a raw row: a later finalize can still replace it.
        let raw = try ledger.rawEventCount()
        let youngRaw = try ledger.aggregateMinutes(from: now.addingTimeInterval(-89 * day), to: now).reduce(0) { $0 + $1.totals.units }
        XCTAssertEqual(raw, youngRaw + 1, "everything young plus the one in-flight relic")
        XCTAssertEqual(try ledger.eventCount(), countBefore)
    }

    func testReplayOfFoldedUnitsIsDroppedButNewFilesStillLand() throws {
        let events = try seed()
        try ledger.compact(before: now.addingTimeInterval(-90 * day))
        let count = try ledger.eventCount(), raw = try ledger.rawEventCount()
        // Replaying the whole corpus (a lost cursor) changes nothing.
        try ledger.upsert(events)
        XCTAssertEqual(try ledger.eventCount(), count)
        XCTAssertEqual(try ledger.rawEventCount(), raw)
        // A never-seen unit older than its file's watermark is a replay too …
        try ledger.upsert([event("late-old", daysAgo: 150, file: "f0")])
        XCTAssertEqual(try ledger.rawEventCount(), raw)
        // … but an old unit from a file that was never compacted is news.
        try ledger.upsert([event("other-file", daysAgo: 150, file: "never-seen")])
        XCTAssertEqual(try ledger.rawEventCount(), raw + 1)
        XCTAssertEqual(try ledger.eventCount(), count + 1)
        // Watermarks survive a reopen.
        let url = ledger.url
        ledger = nil
        ledger = try TelemetryLedger(url: url)
        try ledger.upsert([event("late-old-2", daysAgo: 160, file: "f1")])
        XCTAssertEqual(try ledger.rawEventCount(), raw + 1)
    }

    func testBudgetStopsAfterADayAndResumes() throws {
        _ = try seed()
        let first = try ledger.compact(before: now.addingTimeInterval(-90 * day), maxSeconds: 0)
        XCTAssertEqual(first.daysProcessed, 1, "a zero budget still finishes the day it started")
        XCTAssertTrue(first.remaining)
        let rest = try ledger.compact(before: now.addingTimeInterval(-90 * day))
        XCTAssertFalse(rest.remaining)
        XCTAssertGreaterThan(rest.daysProcessed, 1)
        let again = try ledger.compact(before: now.addingTimeInterval(-90 * day))
        XCTAssertEqual(again, TelemetryLedger.CompactionReport(), "nothing left to fold")
        XCTAssertEqual(ledger.meta("schemaVersion"), "3")
    }
}
