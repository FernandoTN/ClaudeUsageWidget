//
//  TelemetryCorpusVerificationTests.swift
//  Claude UsageTests
//
//  The CLI-free verification harness (spec §2.3): indexes the REAL logs on
//  this Mac into a throw-away ledger and prints per-provider totals to compare
//  with the census tools in docs/research/tools/token-telemetry/. Read-only
//  against the sources, and OPT-IN — it walks ~27 GB, so it runs only when
//  `CUW_TELEMETRY_VERIFY=1` is in the test runner's environment
//  (xcodebuild: TEST_RUNNER_CUW_TELEMETRY_VERIFY=1). Never in the normal suite.
//

import XCTest
@testable import Claude_Usage

final class TelemetryCorpusVerificationTests: XCTestCase {

    func testIndexTheRealCorpusIntoAThrowawayLedgerAndPrintTotals() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CUW_TELEMETRY_VERIFY"] == "1",
                          "opt-in: set TEST_RUNNER_CUW_TELEMETRY_VERIFY=1 to walk the real logs")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuw-corpus-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try TelemetryLedger(url: directory.appendingPathComponent("ledger.sqlite"))
        let indexer = TelemetryIndexer(ledger: ledger, roots: .live(),
                                       bounds: IndexerBounds(maxFiles: 2_000, maxBytes: 512 << 20, maxSeconds: 30))
        let start = Date()
        var slices = 0
        var report = indexer.runSlice()
        var totalFiles = report.filesScanned
        var totalBytes = report.bytesRead
        while report.hitBound {
            slices += 1
            report = indexer.runSlice()
            totalFiles += report.filesScanned
            totalBytes += report.bytesRead
        }
        let elapsed = Date().timeIntervalSince(start)
        print("CORPUS VERIFY: \(totalFiles) files, \(totalBytes) bytes, \(slices + 1) slices, \(String(format: "%.1f", elapsed)) s")
        for provider in TelemetryProvider.allCases {
            let events = try ledger.events(provider: provider, from: .distantPast, to: .distantFuture)
            let input = events.reduce(0) { $0 + $1.input }
            let cacheRead = events.reduce(0) { $0 + $1.cacheRead }
            let cacheWrite = events.reduce(0) { $0 + $1.cacheWrite }
            let output = events.reduce(0) { $0 + $1.output }
            let reasoning = events.reduce(0) { $0 + $1.reasoning }
            let inFlight = events.filter(\.inFlight).count
            let health = try ledger.health(provider: provider)
            var byModel: [String: (Int, Int)] = [:]
            for event in events {
                var entry = byModel[event.model] ?? (0, 0)
                entry.0 += 1; entry.1 += event.inputClass
                byModel[event.model] = entry
            }
            print("CORPUS VERIFY \(provider.rawValue): units=\(events.count) inFlight=\(inFlight) input=\(input) cacheRead=\(cacheRead) cacheWrite=\(cacheWrite) output=\(output) reasoning=\(reasoning) files=\(health.filesSeen) malformed=\(health.linesMalformed) unknown=\(health.unknownShapes) unreadable=\(health.filesUnreadable) through=\(health.dataThrough.map { ISO8601DateFormatter().string(from: $0) } ?? "-")")
            for (model, entry) in byModel.sorted(by: { $0.value.1 > $1.value.1 }) {
                print("CORPUS VERIFY \(provider.rawValue)   \(model): units=\(entry.0) inputClass=\(entry.1)")
            }
        }
        let markers = try ledger.markers(from: .distantPast, to: .distantFuture)
        print("CORPUS VERIFY markers=\(markers.count) rateLimit=\(markers.filter { $0.kind == .rateLimit }.count) quotaRejected=\(markers.filter { $0.kind == .quotaRejected }.count)")
        XCTAssertGreaterThan(try ledger.eventCount(), 0)
    }

    /// Opt-in: times the schema migration on a COPY of a real ledger
    /// (`TEST_RUNNER_CUW_TELEMETRY_MIGRATE_PATH=/path/to/copy.sqlite`). Never
    /// point it at the live file — the migration rewrites the events table.
    func testMigrateACopyOfARealLedgerAndPrintTiming() throws {
        guard let path = ProcessInfo.processInfo.environment["CUW_TELEMETRY_MIGRATE_PATH"], !path.isEmpty else {
            throw XCTSkip("opt-in: set TEST_RUNNER_CUW_TELEMETRY_MIGRATE_PATH to a copy of a ledger")
        }
        let url = URL(fileURLWithPath: path)
        let before = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        let start = Date()
        let ledger = try TelemetryLedger(url: url)
        let elapsed = Date().timeIntervalSince(start)
        let count = try ledger.eventCount()
        let after = ledger.storageBytes()
        print("MIGRATE TIMING: \(count) events, \(before) → \(after) bytes (\(String(format: "%.0f", Double(after) / Double(max(count, 1)))) B/event), \(String(format: "%.1f", elapsed)) s, schema \(ledger.meta("schemaVersion") ?? "?")")
        let sample = try ledger.aggregateMinutes(from: Date().addingTimeInterval(-86_400), to: Date())
        print("MIGRATE TIMING: last-24h minute aggregates = \(sample.count)")
        XCTAssertEqual(ledger.meta("schemaVersion"), "2")
        XCTAssertGreaterThan(count, 0)
    }
}
