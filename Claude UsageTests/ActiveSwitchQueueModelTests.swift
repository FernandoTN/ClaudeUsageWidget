//
//  ActiveSwitchQueueModelTests.swift
//  Claude UsageTests
//
//  The Active & Auto-switch page's queue view model (docs/specs/ux-revamp.md
//  §5.1): rows in queue order with a provider filter, "next" per provider,
//  deleted profiles skipped, and what can still be queued.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class ActiveSwitchQueueModelTests: XCTestCase {
    private func claude(_ name: String) -> Profile {
        Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org")
    }
    private func codex(_ name: String) -> Profile {
        Profile(name: name, codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}", codexEmail: "\(name)@example.com")
    }

    func testRowsKeepQueueOrderAndMarkTheFirstEntryPerProvider() {
        let a = claude("Fjord"), b = codex("Petrel"), c = claude("Ridge"), gone = UUID()
        let rows = ActiveSwitchQueueModel.rows(queue: [a.id, gone, b.id, c.id], profiles: [a, b, c], filter: nil)
        XCTAssertEqual(rows.map(\.name), ["Fjord", "Petrel", "Ridge"], "a deleted profile's entry is skipped")
        XCTAssertEqual(rows.map(\.position), [1, 3, 4], "positions are the whole queue's")
        XCTAssertEqual(rows.map(\.isNextForProvider), [true, true, false], "the first entry of EACH provider is that provider's next")
    }

    func testProviderFilterKeepsPositionsAndNextMarks() {
        let a = claude("Fjord"), b = codex("Petrel"), c = claude("Ridge")
        let rows = ActiveSwitchQueueModel.rows(queue: [a.id, b.id, c.id], profiles: [a, b, c], filter: .claude)
        XCTAssertEqual(rows.map(\.name), ["Fjord", "Ridge"])
        XCTAssertEqual(rows.map(\.position), [1, 3])
        XCTAssertEqual(rows.map(\.isNextForProvider), [true, false])
    }

    func testAddableExcludesQueuedAndCredentiallessAndHonoursTheFilter() {
        let a = claude("Fjord"), b = codex("Petrel"), c = claude("Ridge")
        let empty = Profile(name: "Empty")
        XCTAssertEqual(ActiveSwitchQueueModel.addable(profiles: [a, b, c, empty], queue: [a.id], filter: nil).map(\.name), ["Petrel", "Ridge"])
        XCTAssertEqual(ActiveSwitchQueueModel.addable(profiles: [a, b, c, empty], queue: [], filter: .codex).map(\.name), ["Petrel"])
    }

    func testActiveSectionIsRegistered() {
        XCTAssertTrue(SettingsSection.allCases.contains(.activeAccounts))
        XCTAssertEqual(SettingsSection.activeAccounts.title, "Active & Auto-switch")
        XCTAssertEqual(SettingsRoute(deepLink: "activeAccounts")?.section, .activeAccounts)
    }
}
