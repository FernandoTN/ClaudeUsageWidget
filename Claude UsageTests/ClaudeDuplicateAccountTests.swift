//
//  ClaudeDuplicateAccountTests.swift
//  Claude UsageTests
//
//  Two profiles can hold logins for ONE Anthropic account — measured live on
//  2026-09-03, where 'Google' and 'dRir(Fenrir)' returned byte-identical usage
//  windows because they are the same account. Nothing saw it: only one side
//  carried a `claudeAccountUUID`, so the account-keyed checks all read nil and
//  concluded nothing. The consequences were one quota drawn as two tiles, an
//  auto-switch that treated the pair as two candidates (a switch that gains no
//  headroom and costs every running session its context), and an owner who
//  believed two accounts were exhausted while the one account sat at 19%.
//
//  These cover the three mechanisms that close it: the background identity
//  pass that stamps every stored login, the grouping + once-per-episode
//  reporting built on those stamps, and the candidate filter that refuses to
//  rotate onto the account already in use.
//

import XCTest
@testable import Claude_Usage

final class ClaudeDuplicateAccountTests: XCTestCase {

    private let now = Date()

    private func usage(weeklyResetIn: TimeInterval) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 100_000,
            sessionPercentage: 0,
            sessionResetTime: now.addingTimeInterval(3600),
            weeklyTokensUsed: 0,
            weeklyLimit: 1_000_000,
            weeklyPercentage: 0,
            weeklyResetTime: now.addingTimeInterval(weeklyResetIn),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            fableWeeklyPercentage: nil,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: now,
            userTimezone: .current
        )
    }

    /// A Claude-credentialed profile as the roster holds it. `account` nil is
    /// the pre-stamp state the live defect was hiding in.
    private func profile(
        _ name: String,
        account: String?,
        weeklyResetIn: TimeInterval = 86_400
    ) -> Profile {
        var p = Profile(id: UUID(), name: name, hasCliAccount: true, claudeAccountUUID: account)
        p.claudeUsage = usage(weeklyResetIn: weeklyResetIn)
        return p
    }

    // MARK: - Grouping

    func testGroupsProfilesSharingOneAccountAndLeavesSingletonsAlone() {
        let google = profile("Google", account: "76582cd6")
        let fenrir = profile("dRir(Fenrir)", account: "76582cd6")
        let other = profile("Memori", account: "aa11bb22")

        let groups = ProfileManager.duplicateClaudeAccountGroups(in: [google, fenrir, other])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first, [google.id, fenrir.id])
    }

    func testUnstampedProfilesAreNeverGrouped() {
        // Nil is NO EVIDENCE, not a match: grouping two unstamped profiles
        // would invent a duplicate and block a legitimate auto-switch target.
        let a = profile("Google", account: nil)
        let b = profile("dRir(Fenrir)", account: nil)
        let c = profile("Blank", account: "")

        XCTAssertTrue(ProfileManager.duplicateClaudeAccountGroups(in: [a, b, c]).isEmpty)
    }

    // MARK: - Once-per-episode reporting

    func testDuplicateNoticeFiresOncePerEpisodeAndReArmsAfterItClears() {
        let pair = [UUID(), UUID()]

        let first = ProfileManager.duplicateClaudeAccountNotices(groups: [pair], alreadyNotified: [])
        XCTAssertEqual(first.toNotify.count, 1)

        // Same roster, next sweep: already reported, stays quiet.
        let second = ProfileManager.duplicateClaudeAccountNotices(
            groups: [pair], alreadyNotified: first.notified
        )
        XCTAssertTrue(second.toNotify.isEmpty)

        // The duplicate is resolved, then happens again — a NEW episode, so the
        // user is told again rather than being silently left with it.
        let cleared = ProfileManager.duplicateClaudeAccountNotices(
            groups: [], alreadyNotified: second.notified
        )
        XCTAssertTrue(cleared.notified.isEmpty)
        let recurrence = ProfileManager.duplicateClaudeAccountNotices(
            groups: [pair], alreadyNotified: cleared.notified
        )
        XCTAssertEqual(recurrence.toNotify.count, 1)
    }

    // MARK: - Auto-switch candidate walk

    func testWalkSkipsSameAccountCandidateAndPicksTheNextOne() {
        // 'Twin' resets soonest, so the default ranking would pick it first —
        // but it is the ACTIVE account under another name, and switching onto
        // it buys nothing. The walk must land on 'Memori' instead.
        let twin = profile("Twin", account: "76582cd6", weeklyResetIn: 1 * 86_400)
        let memori = profile("Memori", account: "aa11bb22", weeklyResetIn: 3 * 86_400)

        let distinct = MenuBarManager.excludingBlockedClaudeAccounts(
            [twin, memori], blocked: ["76582cd6"]
        )
        let ranked = MenuBarManager.rankAutoSwitchCandidates(distinct, customOrder: nil, now: now)

        XCTAssertEqual(ranked.map(\.name), ["Memori"])
    }

    func testUnstampedCandidateIsNeverBlocked() {
        // Blocking on a missing stamp would strand the fleet: an unstamped
        // profile is usually a DIFFERENT account whose identity has not been
        // resolved yet, and it is the only candidate left in a two-account
        // roster.
        let unknown = profile("Unstamped", account: nil)
        let distinct = MenuBarManager.excludingBlockedClaudeAccounts(
            [unknown], blocked: ["76582cd6"]
        )
        XCTAssertEqual(distinct.map(\.name), ["Unstamped"])
    }

    // MARK: - Background identity pass

    private func stampCandidate(
        _ id: UUID = UUID(), syncedAgo: TimeInterval?, eligible: Bool = true
    ) -> ClaudeCodeSyncService.IdentityStampCandidate {
        ClaudeCodeSyncService.IdentityStampCandidate(
            id: id,
            isEligible: eligible,
            syncedAt: syncedAgo.map { now.addingTimeInterval(-$0) }
        )
    }

    func testIdentityPassTakesTheOldestUnstampedProfileFirst() {
        let oldest = UUID(), newer = UUID()
        let picked = ClaudeCodeSyncService.selectIdentityStampId(candidates: [
            stampCandidate(newer, syncedAgo: 600),
            stampCandidate(oldest, syncedAgo: 90_000),
        ])
        XCTAssertEqual(picked, oldest)
    }

    func testIdentityPassSkipsIneligibleProfilesEvenWhenTheyAreOldest() {
        // Dead / expired / already-stamped logins are ineligible: spending the
        // one-request-per-sweep budget on them would starve the profiles that
        // can actually be resolved. A never-synced profile (nil) outranks a
        // dated one, exactly like the usage scheduler's never-attempted case.
        let dead = UUID(), neverSynced = UUID(), dated = UUID()
        let picked = ClaudeCodeSyncService.selectIdentityStampId(candidates: [
            stampCandidate(dead, syncedAgo: 900_000, eligible: false),
            stampCandidate(dated, syncedAgo: 3600),
            stampCandidate(neverSynced, syncedAgo: nil),
        ])
        XCTAssertEqual(picked, neverSynced)

        XCTAssertNil(ClaudeCodeSyncService.selectIdentityStampId(candidates: [
            stampCandidate(dead, syncedAgo: 900_000, eligible: false)
        ]))
    }
}
