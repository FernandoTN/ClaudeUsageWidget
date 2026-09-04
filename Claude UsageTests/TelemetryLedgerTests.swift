//
//  TelemetryLedgerTests.swift
//  Claude UsageTests
//
//  The token-consumption ledger (stage 1a): idempotent upserts keyed by unit
//  id, transactions that roll back, cursors, ownership rows, health, meta,
//  private file modes, and the off-main contract. Every test opens its own
//  ledger in a temporary directory — never Application Support.
//

import SQLite3
import XCTest
@testable import Claude_Usage

final class TelemetryLedgerTests: XCTestCase {

    // MARK: - Schema migration

    /// Builds a schema-v1 ledger by hand (the shape the first deploy wrote),
    /// then opens it through the class and expects the v2 interned layout with
    /// every row, cursor and ownership entry intact.
    func testOpeningAV1LedgerMigratesItToV2InPlace() throws {
        let url = directory.appendingPathComponent("v1/ledger.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        let v1 = """
        CREATE TABLE events (unit_id TEXT PRIMARY KEY, provider TEXT NOT NULL, at REAL NOT NULL, model TEXT NOT NULL,
            input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL,
            output INTEGER NOT NULL, reasoning INTEGER NOT NULL, cost_nano INTEGER, session TEXT NOT NULL, sidechain INTEGER NOT NULL,
            source TEXT, file_id TEXT NOT NULL, source_offset INTEGER NOT NULL, parser_version INTEGER NOT NULL, in_flight INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX events_provider_at ON events(provider, at); CREATE INDEX events_at ON events(at); CREATE INDEX events_file ON events(file_id);
        CREATE TABLE cursors (file_id TEXT PRIMARY KEY, path TEXT NOT NULL, inode INTEGER NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL, offset INTEGER NOT NULL, state BLOB);
        CREATE TABLE ownership (seq INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, provider TEXT NOT NULL, profile_id TEXT, previous_profile_id TEXT, account_stamp TEXT, name TEXT, basis TEXT NOT NULL, cause TEXT);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO meta VALUES ('schemaVersion', '1');
        INSERT INTO events VALUES ('msg_1', 'claude', 1000, 'claude-opus-5', 2, 40000, 3000, 3000, 1730, 900, NULL, 'S1', 0, 'Demo', 'claude:proj/S1.jsonl', 0, 1, 0);
        INSERT INTO events VALUES ('codex:r.jsonl#1', 'codex', 2000, 'gpt-5.6-sol', 100, 50, 0, 0, 10, 2, NULL, 'codex:r.jsonl', 0, NULL, 'codex:r.jsonl', 40, 1, 0);
        INSERT INTO events VALUES ('e1', 'grok', 3000, 'grok-4.6-build', 400, 600, 0, 0, 100, 40, 5000, '01a0', 0, 'Demo', 'grok:01a0', 0, 1, 0);
        INSERT INTO cursors VALUES ('claude:proj/S1.jsonl', '/x/S1.jsonl', 7, 900, 1500, 900, NULL);
        INSERT INTO ownership (at, provider, profile_id, basis) VALUES (900, 'claude', '11111111-1111-1111-1111-111111111111', 'exactClaim');
        """
        XCTAssertEqual(sqlite3_exec(raw, v1, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let migrated = try TelemetryLedger(url: url)
        XCTAssertEqual(migrated.meta("schemaVersion"), "2")
        let events = try migrated.events(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(events.map(\.unitId), ["msg_1", "codex:r.jsonl#1", "e1"])
        XCTAssertEqual(events[0].fileId, "claude:proj/S1.jsonl")
        XCTAssertEqual(events[0].session, "S1")
        XCTAssertEqual(events[0].source, "Demo")
        XCTAssertNil(events[1].source)
        XCTAssertEqual(events[2].reportedCostNanoUSD, 5_000)
        XCTAssertEqual(try migrated.cursor(for: "claude:proj/S1.jsonl")?.offset, 900)
        XCTAssertEqual(try migrated.ownership(provider: .claude).count, 1)
        // The migrated ledger keeps working: upsert, reassignment by file, aggregation.
        try migrated.upsert([event("msg_2")])
        try migrated.reassignUnknownModel(fileId: "codex:r.jsonl", to: "gpt-5.5")
        XCTAssertEqual(try migrated.eventCount(), 4)
        XCTAssertEqual(try migrated.aggregateMinutes(from: .distantPast, to: .distantFuture).count, 4)
        XCTAssertEqual(try migrated.distinctSessions(provider: .claude, from: .distantPast, to: .distantFuture), 2)
        // Reopening does not migrate again.
        let reopened = try TelemetryLedger(url: url)
        XCTAssertEqual(try reopened.eventCount(), 4)
    }

    func testAggregateMinutesGroupsByProviderModelSourceAndMinute() throws {
        let minute = Date(timeIntervalSince1970: 1_788_000_000)
        try ledger.upsert([
            event("a", at: minute.addingTimeInterval(5)),
            event("b", at: minute.addingTimeInterval(40), output: 30),
            event("c", provider: .codex, at: minute.addingTimeInterval(61), model: "gpt-5.6-sol"),
        ])
        let rows = try ledger.aggregateMinutes(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].totals.units, 2)
        XCTAssertEqual(rows[0].totals.output, 40)
        XCTAssertEqual(rows[0].totals.cacheRead, 80_000)
        XCTAssertEqual(rows[0].minute, Date(timeIntervalSince1970: floor(minute.timeIntervalSince1970 / 60) * 60))
        XCTAssertEqual(rows[0].source, "proj")
        XCTAssertEqual(rows[0].totals.unpricedUnits, 2, "the ledger counts null costs; the builder prices Claude from the table")
        XCTAssertEqual(rows[1].provider, .codex)
        XCTAssertEqual(try ledger.aggregateMinutes(provider: .codex, from: .distantPast, to: .distantFuture).count, 1)
    }

    private var directory: URL!
    private var ledger: TelemetryLedger!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuw-telemetry-\(UUID().uuidString)", isDirectory: true)
        ledger = try TelemetryLedger(url: directory.appendingPathComponent("nested/ledger.sqlite"))
    }

    override func tearDownWithError() throws {
        ledger = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func event(_ id: String, provider: TelemetryProvider = .claude, at: Date = Date(timeIntervalSince1970: 1_000),
                       output: Int = 10, inFlight: Bool = false, model: String = "claude-opus-5") -> TelemetryEvent {
        TelemetryEvent(unitId: id, provider: provider, at: at, model: model, input: 2, cacheRead: 40_000, cacheWrite: 3_000,
                       cacheWrite1h: 3_000, output: output, reasoning: output / 2, reportedCostNanoUSD: nil,
                       session: "s1", sidechain: false, source: "proj", fileId: "f1", sourceOffset: 0,
                       parserVersion: 1, inFlight: inFlight)
    }

    // MARK: - Events

    func testUpsertIsIdempotentAndKeepsTheLargerOutput() throws {
        try ledger.upsert([event("m1", output: 4, inFlight: true)])
        try ledger.upsert([event("m1", output: 1_730)])
        // A replay of the early partial block must not regress the finished message.
        try ledger.upsert([event("m1", output: 4, inFlight: true)])
        let rows = try ledger.events(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].output, 1_730)
        XCTAssertFalse(rows[0].inFlight)
        XCTAssertEqual(rows[0].inputClass, 2 + 40_000 + 3_000)
        XCTAssertEqual(try ledger.eventCount(), 1)
    }

    func testEventsQueryFiltersByProviderAndRange() throws {
        try ledger.upsert([
            event("a", provider: .claude, at: Date(timeIntervalSince1970: 100)),
            event("b", provider: .codex, at: Date(timeIntervalSince1970: 200), model: "gpt-5.6-sol"),
            event("c", provider: .claude, at: Date(timeIntervalSince1970: 300)),
        ])
        let claude = try ledger.events(provider: .claude, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 250))
        XCTAssertEqual(claude.map(\.unitId), ["a"])
        let all = try ledger.events(from: Date(timeIntervalSince1970: 150), to: Date(timeIntervalSince1970: 301))
        XCTAssertEqual(all.map(\.unitId), ["b", "c"])
        let span = try ledger.eventTimeSpan()
        XCTAssertEqual(span?.from.timeIntervalSince1970, 100)
        XCTAssertEqual(span?.to.timeIntervalSince1970, 300)
        XCTAssertNil(try ledger.eventTimeSpan(provider: .grok))
    }

    func testReassignUnknownModelTouchesOnlyThatFilesUnknownUnits() throws {
        var a = event("r1#1", provider: .codex, model: "unknown"); a.fileId = "r1"
        var b = event("r1#2", provider: .codex, model: "gpt-5.5"); b.fileId = "r1"
        var c = event("r2#1", provider: .codex, model: "unknown"); c.fileId = "r2"
        try ledger.upsert([a, b, c])
        try ledger.reassignUnknownModel(fileId: "r1", to: "gpt-5.6-sol")
        let rows = try ledger.events(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: rows.map { ($0.unitId, $0.model) }),
                       ["r1#1": "gpt-5.6-sol", "r1#2": "gpt-5.5", "r2#1": "unknown"])
    }

    func testMarkersIgnoreDuplicates() throws {
        let marker = TelemetryMarker(markerId: "k1", provider: .claude, kind: .rateLimit,
                                     at: Date(timeIntervalSince1970: 50), session: "s1", detail: "resets 10:50pm")
        try ledger.insert([marker, marker])
        XCTAssertEqual(try ledger.markers(from: .distantPast, to: .distantFuture), [marker])
    }

    func testTransactionRollsBackOnError() throws {
        struct Boom: Error {}
        XCTAssertThrowsError(try ledger.transaction {
            try ledger.upsert([event("doomed")])
            throw Boom()
        })
        XCTAssertEqual(try ledger.eventCount(), 0)
        // The connection is usable afterwards.
        try ledger.upsert([event("ok")])
        XCTAssertEqual(try ledger.eventCount(), 1)
    }

    // MARK: - Cursors

    func testCursorRoundTripAndDelete() throws {
        let state = Data([1, 2, 3])
        let cursor = TelemetryCursor(fileId: "rollout-x", path: "/tmp/rollout-x.jsonl", inode: 42, size: 1_024,
                                     mtime: Date(timeIntervalSince1970: 7), offset: 512, state: state)
        try ledger.save(cursor)
        XCTAssertEqual(try ledger.cursor(for: "rollout-x"), cursor)
        var moved = cursor
        moved.offset = 1_024
        moved.state = nil
        try ledger.save(moved)
        XCTAssertEqual(try ledger.allCursors(), [moved])
        try ledger.deleteCursor(fileId: "rollout-x")
        XCTAssertNil(try ledger.cursor(for: "rollout-x"))
    }

    // MARK: - Ownership, health, meta

    func testOwnershipAppendsInOrderAndReturnsTheLast() throws {
        let a = UUID(), b = UUID()
        try ledger.append(OwnershipRecord(at: Date(timeIntervalSince1970: 10), provider: .claude, profileId: a,
                                          previousProfileId: nil, accountStamp: "acct-a", name: "dRir",
                                          basis: .seededFromRing, cause: "manual"))
        try ledger.append(OwnershipRecord(at: Date(timeIntervalSince1970: 20), provider: .claude, profileId: b,
                                          previousProfileId: a, accountStamp: nil, name: "dJormun",
                                          basis: .exactClaim, cause: "activate"))
        try ledger.append(OwnershipRecord(at: Date(timeIntervalSince1970: 15), provider: .codex, profileId: nil,
                                          previousProfileId: nil, accountStamp: nil, name: nil, basis: .observedAtTick, cause: nil))
        let claude = try ledger.ownership(provider: .claude)
        XCTAssertEqual(claude.map(\.profileId), [a, b])
        XCTAssertEqual(claude.map(\.basis), [.seededFromRing, .exactClaim])
        XCTAssertEqual(try ledger.lastOwnership(provider: .claude)?.name, "dJormun")
        XCTAssertNil(try ledger.lastOwnership(provider: .codex)?.profileId)
        XCTAssertNil(try ledger.lastOwnership(provider: .grok))
        XCTAssertEqual(try ledger.ownership().count, 3)
    }

    func testHealthAndMetaRoundTrip() throws {
        XCTAssertEqual(try ledger.health(provider: .grok), ProviderHealth(provider: .grok))
        var health = ProviderHealth(provider: .grok)
        health.scannedAt = Date(timeIntervalSince1970: 1)
        health.dataThrough = Date(timeIntervalSince1970: 2)
        health.filesSeen = 3; health.filesUnreadable = 1; health.linesMalformed = 4; health.unknownShapes = 5
        health.backlogFiles = 6; health.backlogBytes = 7_000
        try ledger.save(health)
        XCTAssertEqual(try ledger.health(provider: .grok), health)
        XCTAssertEqual(ledger.meta("schemaVersion"), "2")
        try ledger.setMeta("lastScope", "fleet")
        try ledger.setMeta("lastScope", "codex")
        XCTAssertEqual(ledger.meta("lastScope"), "codex")
        XCTAssertNil(ledger.meta("missing"))
    }

    // MARK: - Files and threading

    func testDirectoryAndDatabaseArePrivate() throws {
        let fm = FileManager.default
        let dirMode = (try fm.attributesOfItem(atPath: ledger.url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (try fm.attributesOfItem(atPath: ledger.url.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertGreaterThan(ledger.storageBytes(), 0)
    }

    func testReopeningKeepsTheData() throws {
        try ledger.upsert([event("persist")])
        let url = ledger.url
        ledger = nil
        let reopened = try TelemetryLedger(url: url)
        XCTAssertEqual(try reopened.eventCount(), 1)
        XCTAssertEqual(reopened.meta("schemaVersion"), "2")
    }

    func testLedgerWorksOffTheMainThread() throws {
        let queue = DispatchQueue(label: "cuw-telemetry-test", qos: .utility)
        let done = expectation(description: "off-main write")
        let ledger = self.ledger!
        let background = event("bg")
        queue.async {
            XCTAssertFalse(Thread.isMainThread)
            do {
                try ledger.upsert([background])
            } catch {
                XCTFail("off-main upsert failed: \(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try ledger.eventCount(), 1)
    }
}
