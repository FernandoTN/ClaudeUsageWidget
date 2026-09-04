//
//  PopoverSwitchRuleTests.swift
//  Claude UsageTests
//
//  B2.2: the classic popover's "Make active for <provider>…" row — offered
//  on the VIEWED account only when it is not its provider's owner and
//  carries a login the activation could apply.
//

import XCTest
@testable import Claude_Usage

final class PopoverSwitchRuleTests: XCTestCase {
    func testOfferedOnlyToNonOwnersThatCarryAnApplicableLogin() {
        // `hasCliAccount` is the sync's stored stamp, not derived from the JSON.
        var claude = Profile(name: "C", claudeSessionKey: "sk-ant-sid01-test", organizationId: "org")
        claude.hasCliAccount = true
        let webOnly = Profile(name: "W", claudeSessionKey: "sk-ant-sid01-test", organizationId: "org")
        let codex = Profile(name: "X", codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
                            codexEmail: "x@example.com")
        let grok = Profile(name: "G", grokCredentialsJSON: "{\"a::b\":{\"key\":\"k\"}}")

        XCTAssertTrue(PopoverSwitchRule.canMakeActive(claude, activeIds: []))
        XCTAssertFalse(PopoverSwitchRule.canMakeActive(claude, activeIds: [claude.id]), "never for the current owner")
        XCTAssertFalse(PopoverSwitchRule.canMakeActive(webOnly, activeIds: []), "no CLI login to apply")
        XCTAssertTrue(PopoverSwitchRule.canMakeActive(codex, activeIds: []))
        XCTAssertTrue(PopoverSwitchRule.canMakeActive(grok, activeIds: []))
        XCTAssertFalse(PopoverSwitchRule.canMakeActive(grok, activeIds: [grok.id]))
    }
}
