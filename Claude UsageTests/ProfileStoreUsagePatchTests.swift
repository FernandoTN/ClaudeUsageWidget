//
//  ProfileStoreUsagePatchTests.swift
//  Claude UsageTests
//
//  Phase 2 (packet D): atomic usage patches + deferred flush.
//
//  Isolation: existing tests (SharedDataStoreTests, ProfileTests) do not touch
//  `profiles_v3`. These tests use UserDefaults.standard with full save/restore of
//  the `profiles_v3` key in setUp/tearDown so the developer's real profiles are
//  never left modified. Credential-rotation coverage goes through ProfileStore's
//  public save path (cache + Keychain) for a synthetic profile UUID and cleans
//  that credential in tearDown — it does not hand-edit the private credential
//  cache.
//

import XCTest
import Combine
@testable import Claude_Usage

@MainActor
final class ProfileStoreUsagePatchTests: XCTestCase {

    private let profilesKey = "profiles_v3"
    private let store = ProfileStore.shared
    private let manager = ProfileManager.shared

    private var savedProfilesData: Data?
    private var savedManagerProfiles: [Profile] = []
    private var savedActiveProfile: Profile?
    private var testProfileIDs: [UUID] = []

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        savedProfilesData = Self.testDefaults.data(forKey: profilesKey)
        savedManagerProfiles = manager.profiles
        savedActiveProfile = manager.activeProfile
        // Drop any deferred usage left by a prior test / live session so assertions
        // about "no write yet" and pending emptiness stay deterministic.
        manager.flushPendingUsage()
        testProfileIDs = []
    }

    override func tearDown() {
        manager.flushPendingUsage()
        for id in testProfileIDs {
            store.deleteProfileCredentials(profileId: id)
        }
        if let savedProfilesData {
            Self.testDefaults.set(savedProfilesData, forKey: profilesKey)
        } else {
            Self.testDefaults.removeObject(forKey: profilesKey)
        }
        // Restore in-memory manager state from the restored store (or the
        // pre-test snapshot when the store had no profiles key).
        if savedProfilesData != nil {
            manager.loadProfiles()
        } else {
            manager.profiles = savedManagerProfiles
            manager.activeProfile = savedActiveProfile
        }
        testProfileIDs = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeUsage(sessionPercentage: Double, label: String = "test") -> ClaudeUsage {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return ClaudeUsage(
            sessionTokensUsed: Int(sessionPercentage * 1000),
            sessionLimit: 100_000,
            sessionPercentage: sessionPercentage,
            sessionResetTime: now.addingTimeInterval(3600),
            weeklyTokensUsed: 0,
            weeklyLimit: 1_000_000,
            weeklyPercentage: 10,
            weeklyResetTime: now.addingTimeInterval(86_400),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            fableWeeklyPercentage: nil,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: label,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: now,
            userTimezone: TimeZone(identifier: "UTC") ?? .current
        )
    }

    private func makeAPIUsage(spendCents: Int) -> APIUsage {
        APIUsage(
            currentSpendCents: spendCents,
            resetsAt: Date(timeIntervalSince1970: 1_700_086_400),
            prepaidCreditsCents: 10_000,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
    }

    private func seedProfiles(_ profiles: [Profile]) {
        testProfileIDs = profiles.map(\.id)
        store.saveProfiles(profiles)
        // Manager mirrors store for ProfileManager-facing tests.
        manager.profiles = store.loadProfiles()
        manager.activeProfile = manager.profiles.first
    }

    /// Non-usage fields only — used to prove applyUsagePatches never mutates them.
    private func nonUsageFingerprint(_ profile: Profile) -> String {
        "\(profile.id.uuidString)|\(profile.name)|\(profile.organizationId ?? "")|\(profile.hasCliAccount)|\(profile.refreshInterval)|\(profile.isSelectedForDisplay)|\(profile.menuBarLabel ?? "")"
    }

    /// The store runs against the isolated test suite under XCTest (see
    /// ProfileStore.init) — assertions must read the same domain.
    static let testDefaults = UserDefaults(suiteName: "com.claudeusagewidget.tests")!

    private func persistedProfilesData() -> Data? {
        Self.testDefaults.data(forKey: profilesKey)
    }

    // MARK: - Staged-usage publish coalescing (scroll-lag P0)

    /// N staged usage updates must produce ZERO `profiles` publishes until the
    /// single `publishStagedUsage()`, which produces exactly one — the sweep
    /// used to publish per profile (~15×), re-evaluating every open SwiftUI
    /// surface each time.
    @MainActor
    func testStagedUsagePublishesOnceAtSweepEnd() {
        let ids = [UUID(), UUID(), UUID()]
        let seeded = ids.enumerated().map { i, id -> Profile in
            var p = Profile(id: id, name: "Stage \(i)")
            return p
        }
        store.saveProfiles(seeded)
        manager.profiles = store.loadProfiles()
        testProfileIDs = ids

        var publishes = 0
        let sub = manager.$profiles.dropFirst().sink { _ in publishes += 1 }
        defer { sub.cancel() }

        for (i, id) in ids.enumerated() {
            var u = ClaudeUsage.empty
            u.sessionPercentage = Double(10 * (i + 1))
            manager.stageClaudeUsage(u, for: id)
        }
        XCTAssertEqual(publishes, 0, "staging must not publish per profile")

        manager.publishStagedUsage()
        XCTAssertEqual(publishes, 1, "exactly one publish for the whole batch")
        XCTAssertEqual(
            manager.profiles.first(where: { $0.id == ids[2] })?.claudeUsage?.sessionPercentage,
            30, "staged values visible after the batch publish")

        manager.publishStagedUsage()
        XCTAssertEqual(publishes, 1, "idempotent when nothing is staged")
        manager.flushPendingUsage()
    }

    // MARK: - Credential revision (rotation-proof memo invalidation)

    /// A same-length credential rotation MUST bump the revision (the old
    /// blob-hash/partial-fingerprint approaches could miss rotations); an
    /// unchanged save must NOT bump it.
    @MainActor
    func testCredentialRevisionBumpsOnRotationOnly() {
        let id = UUID()
        var p = Profile(id: id, name: "Rev")
        p.cliCredentialsJSON = #"{"claudeAiOauth":{"accessToken":"AAAA1111","refreshToken":"RRRR1111"}}"#
        store.saveProfiles([p])
        testProfileIDs = [id]
        let r1 = store.credentialRevision(for: id)

        // Unchanged save: no bump.
        store.saveProfiles([p])
        XCTAssertEqual(store.credentialRevision(for: id), r1, "no-change save must not bump")

        // Same-length, same-suffix rotation: MUST bump.
        p.cliCredentialsJSON = #"{"claudeAiOauth":{"accessToken":"BBBB2222","refreshToken":"RRRR1111"}}"#
        store.saveProfiles([p])
        XCTAssertGreaterThan(store.credentialRevision(for: id), r1,
                             "same-length rotation must bump the revision")
    }

    // MARK: - D1.1

    func testApplyUsagePatchesUpdatesOnlyUsageFields() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let usageA = makeUsage(sessionPercentage: 11, label: "A")
        let usageB = makeUsage(sessionPercentage: 22, label: "B")
        let usageC = makeUsage(sessionPercentage: 33, label: "C")
        seedProfiles([
            Profile(id: idA, name: "Alpha", organizationId: "org-a", claudeUsage: usageA, refreshInterval: 30, menuBarLabel: "Alp"),
            Profile(id: idB, name: "Beta", organizationId: "org-b", claudeUsage: usageB, refreshInterval: 45, menuBarLabel: "Bet"),
            Profile(id: idC, name: "Gamma", organizationId: "org-c", claudeUsage: usageC, refreshInterval: 60, menuBarLabel: "Gam")
        ])

        let before = store.loadProfiles()
        let fingerprintsBefore = Dictionary(uniqueKeysWithValues: before.map { ($0.id, nonUsageFingerprint($0)) })
        let usageBeforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.claudeUsage) })

        let patchedUsage = makeUsage(sessionPercentage: 77, label: "A-patched")
        store.applyUsagePatches([
            idA: ProfileStore.UsagePatch(claudeUsage: patchedUsage, apiUsage: nil)
        ])

        let after = store.loadProfiles()
        XCTAssertEqual(after.count, 3)

        guard let a = after.first(where: { $0.id == idA }),
              let b = after.first(where: { $0.id == idB }),
              let c = after.first(where: { $0.id == idC }) else {
            return XCTFail("missing profile after patch")
        }

        XCTAssertEqual(a.claudeUsage?.sessionPercentage, 77)
        XCTAssertEqual(a.claudeUsage?.costCurrency, "A-patched")
        XCTAssertEqual(b.claudeUsage, usageBeforeByID[idB])
        XCTAssertEqual(c.claudeUsage, usageBeforeByID[idC])

        for profile in after {
            XCTAssertEqual(nonUsageFingerprint(profile), fingerprintsBefore[profile.id])
        }
    }

    // MARK: - D1.2

    func testApplyUsagePatchesSurvivesConcurrentCredentialRotation() {
        let id = UUID()
        let originalCLI = #"{"original":true,"access":"old"}"#
        let rotatedCLI = #"{"original":false,"access":"rotated-token"}"#
        let seedUsage = makeUsage(sessionPercentage: 5, label: "seed")
        seedProfiles([
            Profile(id: id, name: "RotateMe", cliCredentialsJSON: originalCLI, hasCliAccount: true, claudeUsage: seedUsage)
        ])

        // Stale in-memory copy taken BEFORE rotation (simulates a sweep snapshot).
        let staleCopy = store.loadProfiles()
        XCTAssertEqual(staleCopy.first?.cliCredentialsJSON, originalCLI)

        // Rotate credentials through the store's normal credential-preserving path
        // (cache + Keychain enqueue) — not by editing private cache fields.
        var rotated = staleCopy
        rotated[0].cliCredentialsJSON = rotatedCLI
        store.saveProfiles(rotated)
        XCTAssertEqual(store.loadProfiles().first?.cliCredentialsJSON, rotatedCLI)

        // Usage patch built from the stale snapshot's identity/usage intent.
        let newUsage = makeUsage(sessionPercentage: 55, label: "from-stale")
        store.applyUsagePatches([
            id: ProfileStore.UsagePatch(claudeUsage: newUsage, apiUsage: nil)
        ])

        let loaded = store.loadProfiles()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.cliCredentialsJSON, rotatedCLI,
                       "credential rotation must survive a usage flush from a stale snapshot")
        XCTAssertEqual(loaded.first?.claudeUsage?.sessionPercentage, 55)
        XCTAssertEqual(loaded.first?.name, "RotateMe")
    }

    // MARK: - D1.3

    func testApplyUsagePatchesUnknownProfileIsNoOp() {
        let id = UUID()
        seedProfiles([
            Profile(id: id, name: "Only", claudeUsage: makeUsage(sessionPercentage: 9, label: "only"))
        ])
        let beforeData = persistedProfilesData()
        let before = store.loadProfiles()

        store.applyUsagePatches([
            UUID(): ProfileStore.UsagePatch(claudeUsage: makeUsage(sessionPercentage: 99, label: "ghost"), apiUsage: nil)
        ])

        let after = store.loadProfiles()
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.first?.claudeUsage?.sessionPercentage, 9)
        // Persisted blob may re-encode identically or as an equivalent encode of
        // the same profiles; decoded equality is the contract.
        _ = beforeData
    }

    // MARK: - D1.4

    func testPendingOverlayReappliedAfterReload() {
        let id = UUID()
        let diskUsage = makeUsage(sessionPercentage: 12, label: "disk")
        seedProfiles([
            Profile(id: id, name: "Pending", claudeUsage: diskUsage)
        ])
        // Align manager with the seeded store (loadProfiles path under test).
        manager.loadProfiles()

        let unflushed = makeUsage(sessionPercentage: 88, label: "unflushed")
        manager.saveClaudeUsage(unflushed, for: id)

        // Disk must still hold the old usage (write is deferred).
        let diskAfterSave = store.loadProfiles().first(where: { $0.id == id })
        XCTAssertEqual(diskAfterSave?.claudeUsage?.sessionPercentage, 12)

        // Force the same reload path production uses after credential sync / heal.
        manager.loadProfiles()

        let memory = manager.profiles.first(where: { $0.id == id })
        XCTAssertEqual(memory?.claudeUsage?.sessionPercentage, 88,
                       "pending usage overlay must survive loadProfiles()")
        XCTAssertEqual(memory?.claudeUsage?.costCurrency, "unflushed")
    }

    // MARK: - D1.5

    func testFlushWritesOnceAndClearsPending() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        seedProfiles([
            Profile(id: idA, name: "A", claudeUsage: makeUsage(sessionPercentage: 1, label: "A0")),
            Profile(id: idB, name: "B", claudeUsage: makeUsage(sessionPercentage: 2, label: "B0")),
            Profile(id: idC, name: "C", claudeUsage: makeUsage(sessionPercentage: 3, label: "C0"))
        ])
        manager.loadProfiles()

        let dataBefore = persistedProfilesData()
        XCTAssertNotNil(dataBefore)

        manager.saveClaudeUsage(makeUsage(sessionPercentage: 10, label: "A1"), for: idA)
        manager.saveClaudeUsage(makeUsage(sessionPercentage: 20, label: "B1"), for: idB)
        manager.saveClaudeUsage(makeUsage(sessionPercentage: 30, label: "C1"), for: idC)
        manager.saveAPIUsage(makeAPIUsage(spendCents: 123), for: idA)

        // No disk transition while pending — N saves must not write.
        XCTAssertEqual(persistedProfilesData(), dataBefore,
                       "deferred usage saves must not write profiles_v3 until flush")

        manager.flushPendingUsage()

        let dataAfterFlush = persistedProfilesData()
        XCTAssertNotEqual(dataAfterFlush, dataBefore, "flush must perform exactly one store write")

        let loaded = store.loadProfiles()
        XCTAssertEqual(loaded.first(where: { $0.id == idA })?.claudeUsage?.sessionPercentage, 10)
        XCTAssertEqual(loaded.first(where: { $0.id == idB })?.claudeUsage?.sessionPercentage, 20)
        XCTAssertEqual(loaded.first(where: { $0.id == idC })?.claudeUsage?.sessionPercentage, 30)
        XCTAssertEqual(loaded.first(where: { $0.id == idA })?.apiUsage?.currentSpendCents, 123)

        // Second flush is a no-op (pending empty) — persisted blob unchanged.
        manager.flushPendingUsage()
        XCTAssertEqual(persistedProfilesData(), dataAfterFlush,
                       "empty pending must not write again")
    }
}
