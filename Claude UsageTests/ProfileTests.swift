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

    // MARK: - Pre-hydration metadata fallback (2026-08-10 partial-cache incident)

    func testUnhydratedGrokProfileClassifiesByMetadata() {
        // A partial Keychain hydration left grokCredentialsJSON nil and the
        // Grok profile was grouped (and weekly-reset ranked) with the Claude
        // accounts. Persisted metadata must keep the partition right while
        // credentials are missing in memory — including a syncedAt-only
        // profile, because a Grok auth.json need not carry an email.
        let bySync = Profile(name: "Grok", grokAccountSyncedAt: Date())
        XCTAssertNil(bySync.grokCredentialsJSON)
        XCTAssertEqual(bySync.providerKind, .grok)

        let byEmail = Profile(name: "Grok", grokEmail: "g@x.ai")
        XCTAssertEqual(byEmail.providerKind, .grok)
    }

    func testUnhydratedCodexProfileClassifiesByMetadata() {
        XCTAssertEqual(Profile(name: "Kestrel", codexEmail: "c@x.com").providerKind, .codex)
        XCTAssertEqual(Profile(name: "Kestrel", codexAccountSyncedAt: Date()).providerKind, .codex)
    }

    func testUnhydratedClaudeProfileStaysInClaudePartition() {
        XCTAssertEqual(Profile(name: "C", hasCliAccount: true).providerKind, .claude)
        XCTAssertEqual(Profile(name: "C", organizationId: "org").providerKind, .claude)
    }

    func testConflictingMetadataMirrorsCredentialPrecedence() {
        // The metadata fallback must classify a mixed profile the SAME way the
        // credential checks will once hydration fills the fields — a kind that
        // flips at hydration would regroup the menu bar mid-run. Hydrated
        // grok+codex resolves .codex (see the mixed-provider test above), so
        // metadata-only grok+codex must too; anything claude-side stays .claude.
        let codexGrok = Profile(name: "B", codexEmail: "c@x.com", grokEmail: "g@x.ai")
        XCTAssertEqual(codexGrok.providerKind, .codex)

        let claudeGrok = Profile(name: "B", hasCliAccount: true, grokEmail: "g@x.ai")
        XCTAssertEqual(claudeGrok.providerKind, .claude)

        let claudeCodex = Profile(name: "B", hasCliAccount: true, codexEmail: "c@x.com")
        XCTAssertEqual(claudeCodex.providerKind, .claude)
    }

    func testHydratedCredentialsBeatStrayMetadata() {
        // Once real credentials are in memory the credential-based checks run
        // first: stray metadata from another provider must not flip the kind.
        var grokWithCodexEmail = grok()
        grokWithCodexEmail.codexEmail = "stray@x.com"
        XCTAssertEqual(grokWithCodexEmail.providerKind, .grok)
    }
}
