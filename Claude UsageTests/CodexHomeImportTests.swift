//
//  CodexHomeImportTests.swift
//  Claude UsageTests
//
//  Tests for importing a Codex account from an isolated CODEX_HOME.
//
//  Why the feature exists: `codex login` REVOKES, server-side, whatever
//  credentials already sit in the home it runs in before it starts the browser
//  flow (codex-rs/cli/src/login.rs: login_with_chatgpt →
//  clear_existing_auth_before_login → logout_with_revoke). Every extra account
//  logged into the default ~/.codex therefore killed the previous one — three
//  accounts died that way on 2026-09-03. The fix is to log each account in
//  under its OWN home, where there is nothing to revoke, and import it.
//
//  The roster mutation is a pure function over `[Profile]` precisely so these
//  assertions need no Keychain and no ProfileStore: a test that wrote real
//  credentials would leave Keychain items behind on the developer's machine.
//

import XCTest
@testable import Claude_Usage

final class CodexHomeImportTests: XCTestCase {

    private let service = CodexUsageService.shared
    private var homes: [URL] = []

    override func tearDown() {
        for home in homes { try? FileManager.default.removeItem(at: home) }
        homes = []
        super.tearDown()
    }

    // MARK: - Import

    /// The happy path: a real auth.json in a real (temporary) home is parsed and
    /// lands on the target profile with its non-secret stamps — including the
    /// home path, which is what tells the user where to re-login WITHOUT
    /// revoking anything.
    func testImportFromAnIsolatedHomeParsesAndStores() throws {
        let home = try makeHome(accountId: "acct-work", email: "work@example.com")
        let target = Profile(name: "Work")
        let bystander = Profile(name: "Personal", codexAccountId: "acct-personal")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Given: the account can be read out of the chosen home without storing it.
        let json = try XCTUnwrap(service.readAuthFile(inHome: home))
        let preview = try service.inspectCodexHome(home)
        XCTAssertEqual(preview.email, "work@example.com")
        XCTAssertEqual(preview.accountId, "acct-work")
        XCTAssertEqual(preview.accountIdSuffix, "cct-work", "the suffix identifies without printing the handle")

        // When
        let roster = try service.importedRoster(
            from: json,
            homePath: home.path,
            into: target.id,
            profiles: [target, bystander],
            now: now
        )

        // Then
        let imported = try XCTUnwrap(roster.first { $0.id == target.id })
        XCTAssertEqual(imported.codexCredentialsJSON, json)
        XCTAssertEqual(imported.codexEmail, "work@example.com")
        XCTAssertEqual(imported.codexAccountId, "acct-work")
        XCTAssertEqual(imported.codexHomePath, home.path)
        XCTAssertEqual(imported.codexAccountSyncedAt, now)
        // And: no other profile is touched, and nothing was written to the
        // default ~/.codex — an import does not switch the CLI.
        XCTAssertEqual(roster.first { $0.id == bystander.id }, bystander)
    }

    /// Same account, two profiles = two tiles for one quota, double the fetch
    /// load, and roster order deciding who owns auth.json. Import runs the same
    /// guard Sync does, and names the profile already holding it.
    func testImportRefusesAnAccountAnotherProfileAlreadyHolds() throws {
        let home = try makeHome(accountId: "acct-work", email: "work@example.com")
        let json = try XCTUnwrap(service.readAuthFile(inHome: home))
        let target = Profile(name: "Second copy")
        // Not hydrated from the Keychain yet — only the non-secret stamp is
        // present. That is the window a duplicate slips through.
        let holder = Profile(name: "Work", codexAccountId: "acct-work")

        XCTAssertThrowsError(
            try service.importedRoster(
                from: json, homePath: home.path, into: target.id, profiles: [target, holder]
            )
        ) { error in
            guard case CodexError.accountAlreadySynced(let profileName) = error else {
                return XCTFail("expected accountAlreadySynced, got \(error)")
            }
            XCTAssertEqual(profileName, "Work")
        }

        // The same account re-imported into the profile that already holds it is
        // a refresh, not a duplicate.
        XCTAssertNoThrow(
            try service.importedRoster(
                from: json, homePath: home.path, into: holder.id, profiles: [target, holder]
            )
        )
    }

    /// A folder the user picked by mistake must say what is wrong and where,
    /// not fail silently or throw the generic "no credentials found" that names
    /// the DEFAULT home the user was told not to log into.
    func testAMissingOrUnreadableHomeReportsThePathItLookedAt() throws {
        let empty = try makeHome(contents: nil)
        let corrupt = try makeHome(contents: "{ this is not json")
        let tokenless = try makeHome(contents: #"{"tokens": {"account_id": "acct-x"}}"#)

        for home in [empty, corrupt, tokenless] {
            XCTAssertThrowsError(try service.inspectCodexHome(home), home.path) { error in
                guard case CodexError.noCredentialsInHome(let path) = error else {
                    return XCTFail("expected noCredentialsInHome, got \(error)")
                }
                XCTAssertEqual(path, home.appendingPathComponent("auth.json").path)
                let message = (error as? LocalizedError)?.errorDescription ?? ""
                XCTAssertTrue(message.contains(home.path), message)
                XCTAssertTrue(message.contains("CODEX_HOME="), message)
            }
        }

        // Two different refusals reach the same error: the reader rejects an
        // absent or non-JSON file outright, while a well-formed file with no
        // access token parses and is refused by the token check.
        XCTAssertNil(service.readAuthFile(inHome: empty))
        XCTAssertNil(service.readAuthFile(inHome: corrupt))
        XCTAssertNotNil(service.readAuthFile(inHome: tokenless))
        XCTAssertNil(service.extractAccessToken(from: try XCTUnwrap(service.readAuthFile(inHome: tokenless))))

        // And the pure roster mutation refuses the tokenless body too, so no
        // path can store a login the app cannot use.
        XCTAssertThrowsError(
            try service.importedRoster(
                from: try XCTUnwrap(service.readAuthFile(inHome: tokenless)),
                homePath: tokenless.path,
                into: UUID(),
                profiles: []
            )
        )
    }

    // MARK: - Persistence

    /// `codexHomePath` is persisted (non-secret), so it must survive the
    /// UserDefaults round-trip AND a profile written before the field existed
    /// must still decode.
    func testCodexHomePathRoundTripsAndLegacyProfilesStillDecode() throws {
        let original = Profile(
            name: "Work",
            codexEmail: "work@example.com",
            codexAccountId: "acct-work",
            codexHomePath: "/Users/someone/.codex-accounts/work"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: encoded)
        XCTAssertEqual(decoded.codexHomePath, "/Users/someone/.codex-accounts/work")
        XCTAssertEqual(decoded.codexAccountId, "acct-work")

        // A fixture in the shape stored before this field existed.
        let legacy = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy",
            "hasCliAccount": false,
            "codexAccountId": "acct-old",
            "iconConfig": \(String(data: try JSONEncoder().encode(MenuBarIconConfiguration.default), encoding: .utf8)!),
            "refreshInterval": 30,
            "checkOverageLimitEnabled": true,
            "notificationSettings": \(String(data: try JSONEncoder().encode(NotificationSettings()), encoding: .utf8)!),
            "isSelectedForDisplay": true,
            "createdAt": 0,
            "lastUsedAt": 0
        }
        """
        let legacyProfile = try JSONDecoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertNil(legacyProfile.codexHomePath, "a missing key decodes as nil, not a failure")
        XCTAssertEqual(legacyProfile.codexAccountId, "acct-old")
        XCTAssertEqual(legacyProfile.name, "Legacy")
    }

    // MARK: - Relogin guidance

    /// Telling a user to `codex login` in the default home is the advice that
    /// killed the accounts. When the app can see that the default home no
    /// longer holds the OWNER's account, the notification must send them to an
    /// isolated home instead — and it must NOT make that claim otherwise: a
    /// background profile's account legitimately differs from whatever is
    /// currently in ~/.codex.
    func testReloginGuidanceOnlyBlamesTheDefaultHomeForItsOwner() {
        let guidance = CodexUsageService.reloginGuidance

        // The live 2026-09-03 shape: the owner's account was replaced.
        XCTAssertEqual(guidance(true, "acct-dex", "acct-cod"), .defaultHomeClobbered)
        // `codex logout` removed the file under its owner.
        XCTAssertEqual(guidance(true, "acct-dex", nil), .defaultHomeClobbered)

        // The owner's account is still there — the death has another cause.
        XCTAssertEqual(guidance(true, "acct-dex", "acct-dex"), .unknown)
        // A background profile: a mismatch here is the normal state.
        XCTAssertEqual(guidance(false, "acct-dex", "acct-cod"), .unknown)
        XCTAssertEqual(guidance(false, "acct-dex", nil), .unknown)
        // No account id to compare: no claim.
        XCTAssertEqual(guidance(true, nil, "acct-cod"), .unknown)
        XCTAssertEqual(guidance(true, "", "acct-cod"), .unknown)
    }

    // MARK: - CLI parity

    /// The refresh grant must be byte-identical to the CLI's. The widget used
    /// to add `scope: "openid profile email"`, but the live access token's
    /// `scp` is wider (`… offline_access api.connectors.read
    /// api.connectors.invoke`) and RFC 6749 §6 lets a supplied scope NARROW the
    /// grant while an omitted one keeps it — so that field could cost an
    /// account `offline_access`, i.e. its ability to refresh at all. The CLI
    /// sends exactly three fields (codex-rs/login/src/auth/manager.rs,
    /// `RefreshRequest`).
    func testRefreshBodyMatchesTheCLIRequestExactly() throws {
        let body = CodexUsageService.refreshRequestBody(refreshToken: "rt-1")

        XCTAssertEqual(Set(body.keys), ["client_id", "grant_type", "refresh_token"])
        XCTAssertNil(body["scope"], "a supplied scope can downscope the grant away from offline_access")
        XCTAssertEqual(body["grant_type"], "refresh_token")
        XCTAssertEqual(body["refresh_token"], "rt-1")
        XCTAssertEqual(body["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann", "the CLI's public client id")

        // And it survives JSON encoding as a flat string map — the shape the
        // token endpoint is posted.
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONSerialization.data(withJSONObject: body)
        ) as? [String: String]
        XCTAssertEqual(encoded, body)
    }

    /// The widget rewrites the CLI's auth.json on every profile switch, so both
    /// sides have to agree on WHICH home that is. The path was hard-coded to
    /// `~/.codex` while the CLI honours `$CODEX_HOME` (audit M11).
    func testDefaultHomeFollowsCodexHomeWhenItIsSet() {
        let userHome = URL(fileURLWithPath: "/Users/someone")
        let resolve = CodexUsageService.resolvedDefaultCodexHome

        XCTAssertEqual(resolve([:], userHome).path, "/Users/someone/.codex")
        XCTAssertEqual(resolve(["CODEX_HOME": "/opt/codex-home"], userHome).path, "/opt/codex-home")
        XCTAssertEqual(resolve(["CODEX_HOME": "~/alt-codex"], userHome).path,
                       (("~/alt-codex" as NSString).expandingTildeInPath))
        // An exported-but-empty variable is not a home.
        XCTAssertEqual(resolve(["CODEX_HOME": ""], userHome).path, "/Users/someone/.codex")
        XCTAssertEqual(resolve(["CODEX_HOME": "   "], userHome).path, "/Users/someone/.codex")

        // The auth file always hangs off whichever home won.
        XCTAssertEqual(
            CodexUsageService.authFileURL(inHome: resolve(["CODEX_HOME": "/opt/codex-home"], userHome)).path,
            "/opt/codex-home/auth.json"
        )
    }

    // MARK: - In-app login under an isolated home

    /// The label names a directory, so it must not be able to escape
    /// `~/.codex-accounts` or produce an unusable name.
    func testLoginSlugIsFolderSafe() {
        let slug = CodexLoginService.slug

        XCTAssertEqual(slug("work"), "work")
        XCTAssertEqual(slug("  Work Account  "), "work-account")
        XCTAssertEqual(slug("Cod/Dex"), "cod-dex")
        XCTAssertEqual(slug("a.b"), "a-b")
        // Traversal cannot survive: `/` and `.` are separators, not characters.
        XCTAssertEqual(slug("../../etc"), "etc")
        XCTAssertNil(slug(".."))
        XCTAssertNil(slug("/"))
        XCTAssertNil(slug("   "))
        XCTAssertNil(slug(""))
        XCTAssertEqual(slug(String(repeating: "x", count: 80))?.count, 32, "capped")

        // Every accepted slug stays a single component directly under the root.
        for label in ["work", "Cod/Dex", "../../etc", "a b c"] {
            let name = try! XCTUnwrap(slug(label))
            let home = CodexLoginService.home(forSlug: name)
            XCTAssertEqual(home.deletingLastPathComponent().path,
                           CodexUsageService.isolatedHomesRoot.path,
                           label)
        }
    }

    /// A GUI app inherits launchd's PATH, not the user's, so the well-known
    /// install paths are tried before paying for a login shell — and a shell
    /// answer is only trusted when it is an absolute path that exists.
    func testCodexBinaryDiscoveryOrder() {
        var shellCalls = 0
        func discover(existing: Set<String>, shell: String?) -> String? {
            CodexLoginService.codexBinaryPath(
                wellKnown: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"],
                isExecutable: { existing.contains($0) },
                loginShellLookup: { shellCalls += 1; return shell }
            )
        }

        XCTAssertEqual(
            discover(existing: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"], shell: nil),
            "/opt/homebrew/bin/codex",
            "Apple silicon Homebrew wins"
        )
        XCTAssertEqual(shellCalls, 0, "a well-known hit must not spawn a shell")

        XCTAssertEqual(discover(existing: ["/usr/local/bin/codex"], shell: nil), "/usr/local/bin/codex")
        XCTAssertEqual(
            discover(existing: ["/Users/someone/.bun/bin/codex"], shell: "/Users/someone/.bun/bin/codex\n"),
            "/Users/someone/.bun/bin/codex",
            "the login shell answers for everyone else"
        )

        // Refusals: nothing found, a relative/alias answer, and a path the
        // shell names but that is not executable.
        XCTAssertNil(discover(existing: [], shell: nil))
        XCTAssertNil(discover(existing: [], shell: "codex: aliased to codex --yolo"))
        XCTAssertNil(discover(existing: [], shell: "/opt/gone/codex"))
    }

    /// The child gets our whole environment plus a CODEX_HOME override, and the
    /// verdict refuses anything that did not actually produce a login.
    func testLoginEnvironmentOverridesCodexHomeAndVerdictNeedsAnAuthFile() throws {
        let home = URL(fileURLWithPath: "/Users/someone/.codex-accounts/work")
        let inherited = ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "CODEX_HOME": "/Users/someone/.codex"]

        let environment = CodexLoginService.loginEnvironment(home: home, inherited: inherited)
        XCTAssertEqual(environment["CODEX_HOME"], home.path, "an inherited CODEX_HOME must not win")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin", "the rest is inherited")
        XCTAssertEqual(environment["HOME"], "/Users/someone")
        XCTAssertNotEqual(environment["CODEX_HOME"], CodexUsageService.defaultCodexHome.path)

        let verdict = CodexLoginService.loginVerdict
        XCTAssertNil(verdict(0, false, false, true), "exit 0 with a login written")
        XCTAssertEqual(verdict(0, false, false, false), .noCredentialsAfterLogin,
                       "exit 0 alone is not success")
        XCTAssertEqual(verdict(1, false, false, false), .failed(status: 1))
        XCTAssertEqual(verdict(15, true, false, false), .cancelled, "cancel outranks the signal status")
        XCTAssertEqual(verdict(15, false, true, false), .timedOut)
    }

    /// Where a login lands. A profile the user opened *because* its Codex
    /// account is missing or dead must receive the login itself — creating a
    /// second profile beside it leaves an empty or broken one to clean up. Only
    /// a profile holding a WORKING account sends the login elsewhere.
    func testLoginTargetsTheViewedProfileUnlessItHoldsALiveAccount() {
        let target = CodexLoginService.loginTarget

        // No Codex account yet (the `xFenrir(dev)` case).
        XCTAssertEqual(target(false, false), .viewedProfile)
        // Account present but flagged dead (the `Cod` / `Dex` case) — replacing
        // those tokens in place IS the repair.
        XCTAssertEqual(target(true, true), .viewedProfile)
        // A working account: a profile holds exactly one, so this login needs
        // its own.
        XCTAssertEqual(target(true, false), .newProfile)

        // The folder is named after the profile, and a remembered home is
        // reused so a re-login does not mint a directory per attempt — the only
        // grant it revokes is that profile's own dead one.
        let fresh = try? XCTUnwrap(CodexLoginService.loginHome(existingHomePath: nil, profileName: "xFenrir(dev)"))
        XCTAssertEqual(fresh?.lastPathComponent, "xfenrir-dev")
        XCTAssertEqual(fresh?.deletingLastPathComponent().path, CodexUsageService.isolatedHomesRoot.path)

        XCTAssertEqual(
            CodexLoginService.loginHome(existingHomePath: "/Users/someone/.codex-accounts/cod", profileName: "Cod")?.path,
            "/Users/someone/.codex-accounts/cod",
            "a re-login reuses the home the profile already knows"
        )
        // A remembered path is not a licence to log into the default home.
        XCTAssertNil(CodexLoginService.loginHome(
            existingHomePath: CodexUsageService.defaultCodexHome.path,
            profileName: "Cod"
        ))
        // A name with nothing usable in it cannot name a folder.
        XCTAssertNil(CodexLoginService.loginHome(existingHomePath: nil, profileName: "///"))
    }

    /// The post-login path is the import path: whatever the CLI wrote into the
    /// isolated home goes through the same parser, the same duplicate guard and
    /// the same stamps.
    func testPostLoginImportUsesTheSameStoreAndStamps() throws {
        let home = try makeHome(accountId: "acct-new", email: "new@example.com")
        XCTAssertNil(CodexLoginService.loginVerdict(
            status: 0,
            cancelled: false,
            timedOut: false,
            authFileExists: FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path)
        ))

        let created = Profile(name: "cod")
        let roster = try service.importedRoster(
            from: try XCTUnwrap(service.readAuthFile(inHome: home)),
            homePath: home.path,
            into: created.id,
            profiles: [created]
        )

        let imported = try XCTUnwrap(roster.first { $0.id == created.id })
        XCTAssertEqual(imported.codexAccountId, "acct-new")
        XCTAssertEqual(imported.codexEmail, "new@example.com")
        XCTAssertEqual(imported.codexHomePath, home.path)
        XCTAssertNotEqual(imported.codexHomePath, CodexUsageService.defaultCodexHome.path,
                          "the login never touches the default home")
    }

    // MARK: - Fixtures

    /// A temporary CODEX_HOME holding a minimal but real auth.json.
    private func makeHome(accountId: String, email: String?) throws -> URL {
        try makeHome(contents: authJSON(accountId: accountId, email: email))
    }

    /// A temporary CODEX_HOME; `contents` nil leaves it without an auth.json.
    private func makeHome(contents: String?) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        homes.append(home)
        if let contents {
            try contents.write(to: home.appendingPathComponent("auth.json"),
                               atomically: true, encoding: .utf8)
        }
        return home
    }

    /// The auth.json shape the codex CLI writes: a JWT access token carrying
    /// `exp`, the account handle the duplicate guard keys on, and an id_token
    /// carrying the email shown in the confirm step.
    private func authJSON(accountId: String, email: String?) -> String {
        var tokens: [String: Any] = [
            "access_token": jwt(claims: ["exp": Date().addingTimeInterval(10 * 24 * 3600).timeIntervalSince1970]),
            "refresh_token": "rt-\(accountId)",
            "account_id": accountId
        ]
        if let email { tokens["id_token"] = jwt(claims: ["email": email]) }
        let root: [String: Any] = ["tokens": tokens, "last_refresh": "2026-09-03T17:52:21.319149Z"]
        return String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
    }

    private func jwt(claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }
}
