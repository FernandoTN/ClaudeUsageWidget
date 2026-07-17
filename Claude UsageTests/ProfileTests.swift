import XCTest
@testable import Claude_Usage

/// Tests for Profile's provider partition — the invariant the auto-switch
/// same-provider rule and the menu-bar grouping both stand on: every profile
/// belongs to exactly ONE of claude/codex/grok, so a Claude account hitting a
/// limit can never rotate into a Grok (or Codex) login and vice versa.
final class ProfileTests: XCTestCase {

    private func claude() -> Profile {
        Profile(name: "C", claudeSessionKey: "sk-ant-sid01-test", organizationId: "org")
    }

    private func codex() -> Profile {
        Profile(name: "X", codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"t\"}}")
    }

    private func grok() -> Profile {
        Profile(name: "G", grokCredentialsJSON: "{\"https://auth.x.ai::c\":{\"key\":\"jwt\"}}")
    }

    func testEachProviderMapsToItsOwnKind() {
        XCTAssertEqual(claude().providerKind, .claude)
        XCTAssertEqual(codex().providerKind, .codex)
        XCTAssertEqual(grok().providerKind, .grok)
    }

    func testGrokIsNeverInTheClaudeOrCodexPartition() {
        // The isolation the auto-switch relies on: a grok-only profile is not
        // codex-only and carries no Claude usage source.
        let g = grok()
        XCTAssertTrue(g.isGrokOnlyProfile)
        XCTAssertFalse(g.isCodexOnlyProfile)
        XCTAssertFalse(g.hasClaudeUsageSource)
        XCTAssertTrue(g.hasUsageCredentials)
    }

    func testMixedProviderProfilesResolveDeterministically() {
        // A profile that (ab)normally carries BOTH grok and Claude credentials
        // is a CLAUDE profile — grok creds lie dormant, mirroring the Codex
        // precedent, so it participates only in Claude rotation.
        var mixed = grok()
        mixed.claudeSessionKey = "sk-ant-sid01-test"
        mixed.organizationId = "org"
        XCTAssertEqual(mixed.providerKind, .claude)
        XCTAssertFalse(mixed.isGrokOnlyProfile)

        // Grok + codex (no Claude source): codex wins — isGrokOnlyProfile
        // requires the absence of a codex account.
        var grokCodex = grok()
        grokCodex.codexCredentialsJSON = "{\"tokens\":{\"access_token\":\"t\"}}"
        XCTAssertEqual(grokCodex.providerKind, .codex)
    }

    func testProfileWithoutCredentialsDefaultsToClaudePartition() {
        // Credential-less profiles stay in the Claude group (historic default);
        // they are filtered out of switching by hasUsageCredentials anyway.
        let empty = Profile(name: "E")
        XCTAssertEqual(empty.providerKind, .claude)
        XCTAssertFalse(empty.hasUsageCredentials)
    }
}
