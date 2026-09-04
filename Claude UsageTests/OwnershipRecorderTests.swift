//
//  OwnershipRecorderTests.swift
//  Claude UsageTests
//
//  The ownership log's rules (spec §2.4): the strict one-time seed from the
//  switch ring, tick diffs, heartbeats, the switching guard, and the two
//  notification paths.
//

import XCTest
@testable import Claude_Usage

final class OwnershipRecorderTests: XCTestCase {

    private var directory: URL!
    private var ledger: TelemetryLedger!
    private var recorder: OwnershipRecorder!

    private let atlas = UUID(), cedar = UUID(), juniper = UUID(), grok = UUID(), twinA = UUID(), twinB = UUID()

    private var roster: [ProfileSummary] {
        [
            ProfileSummary(id: atlas, name: "Atlas", provider: .claude, accountStamp: "acct-atl"),
            ProfileSummary(id: cedar, name: "Cedar", provider: .claude, accountStamp: "acct-ced"),
            ProfileSummary(id: juniper, name: "Juniper (dev)", provider: .codex, accountStamp: "codex-acct"),
            ProfileSummary(id: grok, name: "GROK", provider: .grok, accountStamp: "owner@x"),
            ProfileSummary(id: twinA, name: "Twin", provider: .claude, accountStamp: nil),
            ProfileSummary(id: twinB, name: "Twin", provider: .codex, accountStamp: nil),
        ]
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuw-ownership-\(UUID().uuidString)", isDirectory: true)
        ledger = try TelemetryLedger(url: directory.appendingPathComponent("ledger.sqlite"))
        recorder = OwnershipRecorder(ledger: ledger, heartbeatInterval: 3_600)
    }

    override func tearDownWithError() throws {
        recorder = nil
        ledger = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    // MARK: - Seed

    func testSeedMapsUniqueNamesSkipsFocusOnlyDuplicatesAndUnknowns() {
        let ring = [
            SwitchEvent(at: at(30), from: "Atlas", to: "Cedar", trigger: .auto, reason: "session 96 % ≥ 95 %"),
            SwitchEvent(at: at(10), from: "Cedar", to: "Atlas", trigger: .manual, reason: nil),
            SwitchEvent(at: at(20), from: "Atlas", to: "Lark", trigger: .manual, reason: "focus only — dead login, login NOT applied, CLI unchanged"),
            SwitchEvent(at: at(25), from: "Atlas", to: "Twin", trigger: .manual, reason: nil),
            SwitchEvent(at: at(26), from: "Atlas", to: "Renamed", trigger: .manual, reason: nil),
            SwitchEvent(at: at(40), from: "GROK", to: "Juniper (dev)", trigger: .queued, reason: nil),
        ]
        let records = OwnershipRecorder.seedRecords(ring: ring, roster: roster)
        XCTAssertEqual(records.map(\.at), [at(10), at(30), at(40)], "sorted by time; focus-only, duplicate and unknown names dropped")
        XCTAssertEqual(records.map(\.profileId), [atlas, cedar, juniper])
        XCTAssertEqual(records.map(\.provider), [.claude, .claude, .codex])
        XCTAssertEqual(records[0].previousProfileId, cedar)
        XCTAssertEqual(records[1].previousProfileId, atlas)
        // Cross-provider "from" (a Grok name before a Codex switch) is not a previous Codex owner.
        XCTAssertNil(records[2].previousProfileId)
        XCTAssertEqual(records.map(\.basis), [.seededFromRing, .seededFromRing, .seededFromRing])
        XCTAssertEqual(records.map(\.cause), ["manual", "auto", "queued"])
        XCTAssertEqual(records[0].accountStamp, "acct-atl")
    }

    func testSeedRunsOnce() throws {
        let ring = [SwitchEvent(at: at(10), from: "Cedar", to: "Atlas", trigger: .manual, reason: nil)]
        XCTAssertEqual(try recorder.seedIfNeeded(ring: ring, roster: roster), 1)
        XCTAssertEqual(try recorder.seedIfNeeded(ring: ring, roster: roster), 0)
        XCTAssertEqual(try ledger.ownership().count, 1)
        XCTAssertNotNil(ledger.meta(OwnershipRecorder.seedMetaKey))
    }

    // MARK: - Tick

    private func snapshot(_ time: TimeInterval, claude: UUID?, codex: UUID? = nil, switching: Bool = false) -> OwnerSnapshot {
        var owners: [TelemetryProvider: OwnerIdentity] = [:]
        if let claude { owners[.claude] = OwnerIdentity(profileId: claude, name: claude == atlas ? "Atlas" : "Cedar", accountStamp: "stamp") }
        if let codex { owners[.codex] = OwnerIdentity(profileId: codex, name: "Juniper (dev)", accountStamp: "codex-acct") }
        return OwnerSnapshot(capturedAt: at(time), owners: owners, isSwitching: switching)
    }

    func testTickRecordsChangesThenHeartbeatsOnlyAfterTheInterval() throws {
        let first = try recorder.record(snapshot: snapshot(100, claude: atlas, codex: juniper))
        XCTAssertEqual(Set(first.map(\.provider)), [.claude, .codex], "first sighting of each owner is recorded; Grok has no owner and no row")
        XCTAssertEqual(first.map(\.basis), [.observedAtTick, .observedAtTick])

        XCTAssertTrue(try recorder.record(snapshot: snapshot(400, claude: atlas, codex: juniper)).isEmpty, "unchanged, too soon for a heartbeat")

        let changed = try recorder.record(snapshot: snapshot(700, claude: cedar, codex: juniper))
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].provider, .claude)
        XCTAssertEqual(changed[0].profileId, cedar)
        XCTAssertEqual(changed[0].previousProfileId, atlas)

        let beats = try recorder.record(snapshot: snapshot(100 + 3_600, claude: cedar, codex: juniper))
        XCTAssertEqual(beats.map(\.provider), [.codex], "Codex is an hour old and heartbeats; Claude's last row is recent")
        XCTAssertEqual(beats[0].basis, .heartbeat)
        XCTAssertEqual(beats[0].profileId, juniper)

        // 100 s after Codex's heartbeat: only the cleared Claude pointer is news.
        let cleared = try recorder.record(snapshot: snapshot(3_800, claude: nil, codex: juniper))
        XCTAssertEqual(cleared.map(\.provider), [.claude])
        XCTAssertNil(cleared[0].profileId, "a cleared pointer is recorded as no owner")
        XCTAssertEqual(cleared[0].previousProfileId, cedar)
    }

    func testTickIsSkippedWhileSwitching() throws {
        XCTAssertTrue(try recorder.record(snapshot: snapshot(100, claude: atlas, switching: true)).isEmpty)
        XCTAssertEqual(try ledger.ownership().count, 0)
    }

    // MARK: - Notifications

    func testClaimAndExternalObservationAreRecordedWithTheirBasis() throws {
        try recorder.recordClaim(provider: .claude, newOwner: atlas, previousOwner: nil, accountStamp: "acct-atl",
                                 name: "Atlas", cause: "activate", at: at(10))
        try recorder.recordExternalChange(provider: .claude, newOwner: atlas, name: "Atlas", at: at(20))
        XCTAssertEqual(try ledger.ownership(provider: .claude).count, 1, "an observation of the owner we already know adds nothing")
        try recorder.recordExternalChange(provider: .claude, newOwner: cedar, name: "Cedar", at: at(30))
        let rows = try ledger.ownership(provider: .claude)
        XCTAssertEqual(rows.map(\.basis), [.exactClaim, .externalObservation])
        XCTAssertEqual(rows[1].previousProfileId, atlas)
        XCTAssertEqual(rows[1].cause, "adoption")
        // A tick that agrees with the external observation stays quiet.
        XCTAssertTrue(try recorder.record(snapshot: snapshot(40, claude: cedar)).isEmpty)
    }

    func testProviderNameDecoding() {
        XCTAssertEqual(TelemetryProvider(name: "claude"), .claude)
        XCTAssertEqual(TelemetryProvider(name: "Codex"), .codex)
        XCTAssertEqual(TelemetryProvider(Profile.ProviderKind.grok), .grok)
        XCTAssertNil(TelemetryProvider(name: "openai"))
    }
}
