//
//  ImportGateTests.swift
//  Claude UsageTests
//
//  The rule behind "Import the CLI's current login into this profile…"
//  (docs/specs/ux-revamp.md D13): silent only when it cannot mix accounts.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class ImportGateTests: XCTestCase {
    func testFreshProfileImportsSilently() {
        XCTAssertEqual(ImportGate.decision(cliAccount: "acct-1", profileAccount: nil, profileHasLogin: false), .allowed)
        XCTAssertEqual(ImportGate.decision(cliAccount: nil, profileAccount: nil, profileHasLogin: false), .allowed,
                       "nothing to contaminate: no login and no stamp")
    }

    func testSameAccountIsTheRepairAndAsksNothing() {
        let d = ImportGate.decision(cliAccount: "acct-1", profileAccount: "acct-1", profileHasLogin: true)
        XCTAssertEqual(d, .repair)
        XCTAssertFalse(d.asksFirst)
    }

    func testDifferentAccountAsksNamingBoth() {
        let d = ImportGate.decision(cliAccount: "acct-owner", profileAccount: "acct-mine", profileHasLogin: true)
        XCTAssertEqual(d, .confirmDifferent(cliAccount: "acct-owner", profileAccount: "acct-mine"))
        XCTAssertTrue(d.asksFirst)
    }

    func testUnknownSidesAskBeforeCopying() {
        XCTAssertEqual(ImportGate.decision(cliAccount: nil, profileAccount: "acct-mine", profileHasLogin: true), .confirmUnknown,
                       "the CLI's identity is unknown")
        XCTAssertEqual(ImportGate.decision(cliAccount: "acct-owner", profileAccount: nil, profileHasLogin: true), .confirmUnknown,
                       "an unstamped login already sits on the profile")
        XCTAssertEqual(ImportGate.decision(cliAccount: "", profileAccount: "acct-mine", profileHasLogin: true), .confirmUnknown)
    }

    func testSuffixNeverPrintsTheWholeIdentifier() {
        XCTAssertEqual(ImportGate.suffix("0123456789abcdef"), "…cdef")
        XCTAssertEqual(ImportGate.suffix("ab"), "…ab")
    }

    func testLoginTabIsAvailableAndLegendGlyphsFeedTheStrip() {
        XCTAssertTrue(AccountTab.available.contains(.login))
        XCTAssertEqual(FleetCounts.stripGlyphs.first { $0.0 == .dead }?.1, DesignGlyph.dead)
        XCTAssertEqual(FleetCounts.stripGlyphs.first { $0.0 == .suspected }?.1, DesignGlyph.suspected)
        XCTAssertEqual(ActiveSelectorMenuModel.tint(for: AccountReadiness.dead), .red, "dead is blocking red, not orange (G1)")
        XCTAssertEqual(ActiveSelectorMenuModel.tint(for: AccountReadiness.low), .orange, "near limit is caution amber")
    }
}
