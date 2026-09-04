//
//  TelemetryIndexerTests.swift
//  Claude UsageTests
//
//  The bounded, incremental, idempotent indexer over temporary roots shaped
//  like the real homes — never the user's. Covers: the three providers in one
//  pass with pruning, resume through a trailing fragment, file and byte
//  bounds with catch-up, shrink/rewrite replay, a rollout moved into
//  archived_sessions, a vanished file, health, and the off-main contract.
//

import XCTest
@testable import Claude_Usage

final class TelemetryIndexerTests: XCTestCase {

    private var root: URL!
    private var ledger: TelemetryLedger!
    private var roots: TelemetrySourceRoots!
    private var claudeFile: URL!
    private var codexFile: URL!
    private var grokFile: URL!

    private let claudeLine1 = #"{"type":"assistant","uuid":"u1","timestamp":"2026-09-01T10:00:01.000Z","sessionId":"S1","cwd":"/Users/x/Projects/Demo","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":3000,"cache_read_input_tokens":40000,"output_tokens":1730}}}"#
    private let claudeLine2 = #"{"type":"assistant","uuid":"u2","timestamp":"2026-09-01T10:00:05.000Z","sessionId":"S1","cwd":"/Users/x/Projects/Demo","message":{"id":"msg_2","model":"claude-opus-5","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":100,"output_tokens":50}}}"#
    private let claudeLine3 = #"{"type":"assistant","uuid":"u3","timestamp":"2026-09-01T10:00:09.000Z","sessionId":"S1","cwd":"/Users/x/Projects/Demo","message":{"id":"msg_3","model":"claude-sonnet-5","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":9}}}"#
    private let claudeLine4 = #"{"type":"assistant","uuid":"u4","timestamp":"2026-09-01T10:00:12.000Z","sessionId":"S1","cwd":"/Users/x/Projects/Demo","message":{"id":"msg_4","model":"claude-sonnet-5","usage":{"input_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":20,"output_tokens":11}}}"#
    private let codexLines = [
        #"{"timestamp":"2026-07-25T21:39:42.288Z","type":"session_meta","payload":{"id":"sid","originator":"codex_exec","source":"exec"}}"#,
        #"{"timestamp":"2026-07-25T21:39:42.300Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        #"{"timestamp":"2026-07-25T21:39:52.332Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30251,"cached_input_tokens":0,"output_tokens":312,"reasoning_output_tokens":149,"total_tokens":30563}}}}"#,
        #"{"timestamp":"2026-07-25T21:39:56.196Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":60827,"cached_input_tokens":29440,"output_tokens":477,"reasoning_output_tokens":159,"total_tokens":61304}}}}"#,
    ]
    private let grokLine = #"{"timestamp":1788491778,"method":"_x.ai/session/update","params":{"sessionId":"01a06a5e","update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":1000,"outputTokens":100,"cachedReadTokens":600,"cacheCreationTokens":0,"reasoningTokens":40,"costUsdTicks":5000,"modelUsage":{"grok-4.6-build":{"inputTokens":1000,"outputTokens":100,"cachedReadTokens":600,"cacheCreationTokens":0,"reasoningTokens":40,"costUsdTicks":5000}}}},"_meta":{"eventId":"e1"}}}"#

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cuw-indexer-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let claudeRoot = root.appendingPathComponent("claude/projects")
        let codexHome = root.appendingPathComponent("codex-home")
        let grokRoot = root.appendingPathComponent("grok/sessions")
        try fm.createDirectory(at: claudeRoot.appendingPathComponent("-Users-x-Projects-Demo/S1/tool-results"), withIntermediateDirectories: true)
        try fm.createDirectory(at: claudeRoot.appendingPathComponent("-Users-x-Projects-Demo/S1/subagents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: codexHome.appendingPathComponent("sessions/2026/07/25"), withIntermediateDirectories: true)
        try fm.createDirectory(at: codexHome.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        let grokSession = grokRoot.appendingPathComponent("%2FUsers%2Fx%2FProjects%2FDemo/01a06a5e")
        try fm.createDirectory(at: grokSession, withIntermediateDirectories: true)

        claudeFile = claudeRoot.appendingPathComponent("-Users-x-Projects-Demo/S1.jsonl")
        try write(claudeFile, [claudeLine1, claudeLine2])
        try write(claudeRoot.appendingPathComponent("-Users-x-Projects-Demo/S1/subagents/agent-a.jsonl"), [claudeLine3])
        try write(claudeRoot.appendingPathComponent("-Users-x-Projects-Demo/S1/tool-results/blob.jsonl"), [claudeLine3])
        codexFile = codexHome.appendingPathComponent("sessions/2026/07/25/rollout-2026-07-25T14-39-42-019f9b38.jsonl")
        try write(codexFile, codexLines)
        grokFile = grokSession.appendingPathComponent("updates.jsonl")
        try write(grokFile, [grokLine])
        try write(grokSession.appendingPathComponent("chat_history.jsonl"), [#"{"type":"system","content":"…"}"#])

        ledger = try TelemetryLedger(url: root.appendingPathComponent("ledger.sqlite"))
        roots = TelemetrySourceRoots(claudeProjects: [claudeRoot], codexHomes: [codexHome], grokSessions: [grokRoot])
    }

    override func tearDownWithError() throws {
        ledger = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ url: URL, _ lines: [String], trailingNewline: Bool = true) throws {
        try Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8).write(to: url)
    }

    private func append(_ url: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func allEvents() throws -> [TelemetryEvent] {
        try ledger.events(from: .distantPast, to: .distantFuture)
    }

    // MARK: - Tests

    func testOnePassIndexesAllThreeProvidersAndPrunesToolResults() throws {
        let indexer = TelemetryIndexer(ledger: ledger, roots: roots)
        let report = indexer.runSlice()
        XCTAssertFalse(report.hitBound)
        XCTAssertEqual(report.filesScanned, 4, "two Claude files (main + subagent), one rollout, one updates.jsonl; tool-results pruned, chat_history ignored")
        XCTAssertEqual(report.backlogFiles, 0)
        let events = try allEvents()
        XCTAssertEqual(events.filter { $0.provider == .claude }.count, 3)
        XCTAssertEqual(events.filter { $0.provider == .codex }.count, 2)
        XCTAssertEqual(events.filter { $0.provider == .grok }.count, 1)
        XCTAssertEqual(events.first { $0.provider == .grok }?.source, "Demo", "the percent-encoded cwd decodes to the project name")
        XCTAssertEqual(events.first { $0.provider == .codex }?.source, "codex_exec")
        XCTAssertEqual(events.first { $0.unitId == "msg_2" }?.inFlight, true, "the last message of a growing file stays in flight")
        XCTAssertEqual(try ledger.health(provider: .claude).filesSeen, 2)
        XCTAssertNotNil(try ledger.health(provider: .codex).scannedAt)
        XCTAssertEqual(try ledger.health(provider: .grok).dataThrough, Date(timeIntervalSince1970: 1_788_491_778))
        // A second slice with nothing changed scans nothing.
        XCTAssertEqual(indexer.runSlice().filesScanned, 0)
    }

    func testTrailingFragmentIsPickedUpWhenCompletedWithoutDuplicates() throws {
        let indexer = TelemetryIndexer(ledger: ledger, roots: roots)
        _ = indexer.runSlice()
        let half = String(claudeLine4.prefix(60))
        try append(claudeFile, half)
        _ = indexer.runSlice()
        XCTAssertEqual(try allEvents().filter { $0.provider == .claude }.count, 3, "the fragment is not a record yet")
        let cursor = try ledger.cursor(for: "claude:-Users-x-Projects-Demo/S1.jsonl")
        XCTAssertEqual(cursor?.offset, Int64((claudeLine1 + "\n" + claudeLine2 + "\n").utf8.count), "the cursor stops before the fragment")
        try append(claudeFile, String(claudeLine4.dropFirst(60)) + "\n")
        _ = indexer.runSlice()
        let claude = try allEvents().filter { $0.provider == .claude }
        XCTAssertEqual(claude.count, 4)
        XCTAssertEqual(claude.first { $0.unitId == "msg_2" }?.inFlight, false, "msg_2 finished when msg_4 arrived")
        XCTAssertEqual(claude.filter { $0.unitId == "msg_4" }.count, 1)
        XCTAssertEqual(claude.first { $0.unitId == "msg_4" }?.inFlight, true)
    }

    func testFileBoundLeavesABacklogThatCatchUpDrains() throws {
        let indexer = TelemetryIndexer(ledger: ledger, roots: roots, bounds: IndexerBounds(maxFiles: 1))
        let first = indexer.runSlice()
        XCTAssertTrue(first.hitBound)
        XCTAssertEqual(first.filesScanned, 1)
        XCTAssertEqual(first.backlogFiles, 3)
        var slices = 1
        while indexer.runSlice().hitBound { slices += 1; XCTAssertLessThan(slices, 10) }
        XCTAssertEqual(try allEvents().count, 6)
    }

    func testByteBoundResumesInsideAFile() throws {
        let indexer = TelemetryIndexer(ledger: ledger, roots: roots, bounds: IndexerBounds(maxBytes: 400))
        var slices = 0
        var report = indexer.runSlice()
        while report.hitBound { slices += 1; XCTAssertLessThan(slices, 40); report = indexer.runSlice() }
        XCTAssertGreaterThan(slices, 0, "400-byte slices cannot swallow a 700-byte rollout in one go")
        XCTAssertEqual(try allEvents().count, 6, "every unit exactly once")
        XCTAssertEqual(try ledger.cursor(for: "codex:rollout-2026-07-25T14-39-42-019f9b38.jsonl")?.offset,
                       Int64((codexLines.joined(separator: "\n") + "\n").utf8.count))
    }

    func testRewrittenFileIsReplayedIdempotently() throws {
        let indexer = TelemetryIndexer(ledger: ledger, roots: roots)
        _ = indexer.runSlice()
        // Shrink to one line, then grow back with the same content.
        try write(claudeFile, [claudeLine1])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: claudeFile.path)
        _ = indexer.runSlice()
        try write(claudeFile, [claudeLine1, claudeLine2])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: claudeFile.path)
        _ = indexer.runSlice()
        let claude = try allEvents().filter { $0.provider == .claude }
        XCTAssertEqual(claude.count, 3, "no duplicate units after a shrink and re-read")
        XCTAssertEqual(claude.first { $0.unitId == "msg_1" }?.output, 1730)
    }

    func testRolloutMovedIntoArchivedSessionsIsNotReimported() throws {
        let indexer = TelemetryIndexer(ledger: ledger, roots: roots)
        _ = indexer.runSlice()
        let archived = roots.codexHomes[0].appendingPathComponent("archived_sessions").appendingPathComponent(codexFile.lastPathComponent)
        try FileManager.default.moveItem(at: codexFile, to: archived)
        let report = indexer.runSlice()
        XCTAssertEqual(report.filesScanned, 0, "same basename, same inode, same size: nothing to do")
        XCTAssertEqual(try allEvents().filter { $0.provider == .codex }.count, 2)
        XCTAssertEqual(try ledger.cursor(for: "codex:" + codexFile.lastPathComponent)?.path.hasSuffix("sessions/2026/07/25/" + codexFile.lastPathComponent), true,
                       "the cursor still names the old location — nothing was re-read")
    }

    func testVanishedFileKeepsItsEventsAndDropsItsCursor() throws {
        let indexer = TelemetryIndexer(ledger: ledger, roots: roots)
        _ = indexer.runSlice()
        try FileManager.default.removeItem(at: grokFile)
        _ = indexer.runSlice()
        XCTAssertEqual(try allEvents().filter { $0.provider == .grok }.count, 1)
        XCTAssertNil(try ledger.cursor(for: "grok:01a06a5e"))
    }

    func testMalformedLinesAreCountedInHealthNotRenderedAsConsumption() throws {
        try append(claudeFile, "{\"type\":\"assistant\", broken\n")
        let indexer = TelemetryIndexer(ledger: ledger, roots: roots)
        _ = indexer.runSlice()
        XCTAssertEqual(try ledger.health(provider: .claude).linesMalformed, 1)
        XCTAssertEqual(try allEvents().filter { $0.provider == .claude }.count, 3)
    }

    func testIndexerRunsOffTheMainThread() throws {
        let indexer = TelemetryIndexer(ledger: ledger, roots: roots)
        let done = expectation(description: "slice")
        DispatchQueue(label: "cuw-indexer-test", qos: .utility).async {
            XCTAssertFalse(Thread.isMainThread)
            let report = indexer.runSlice()
            XCTAssertEqual(report.filesScanned, 4)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
}
