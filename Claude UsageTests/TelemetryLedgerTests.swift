//
//  TelemetryLedgerTests.swift
//  Claude UsageTests
//
//  The token-consumption ledger (stage 1a): idempotent upserts keyed by unit
//  id, transactions that roll back, cursors, ownership rows, health, meta,
//  private file modes, and the off-main contract. Every test opens its own
//  ledger in a temporary directory — never Application Support.
//

import XCTest
@testable import Claude_Usage

final class TelemetryLedgerTests: XCTestCase {

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
        XCTAssertEqual(ledger.meta("schemaVersion"), "1")
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
        XCTAssertEqual(reopened.meta("schemaVersion"), "1")
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
