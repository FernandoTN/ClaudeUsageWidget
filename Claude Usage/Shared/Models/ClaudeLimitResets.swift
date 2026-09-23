//
//  ClaudeLimitResets.swift
//  Claude Usage
//
//  Claude "limit resets" — the Claude side of what Codex calls usage limit
//  resets. Two programs ride in the SAME `api/oauth/usage` payload the sweep
//  already fetches, as top-level keys:
//
//  - `cedar_ember`: a BANK of grants, each with `resets_left` / `resets_total`,
//    a use-by date (`ends_at`) and the windows it refills (`clears`). This is
//    the Codex analogue and the only one that carries a count.
//  - `juniper_tide`: a weekly session-only allowance (an experiment arm, not a
//    bank): `available`, `next_available_at`, `resets_per_week`.
//
//  Both are null on a plain read. They populate only under the program reads
//  `ClaudeUsageRead` builds, and today every account answers the app with
//  `eligible: false, ineligible_reason: "surface"` and `grants: []` — the
//  server reports grants only to Claude Code and claude.ai. So the rule this
//  file exists to hold: **no grants in hand is UNKNOWN, never zero.** A count
//  is stated only when grants actually arrive.
//
//  Read only. Claiming (`POST /api/organizations/{org}/reset_rate_limits`) is
//  irreversible and the app has no code path to it.
//
//  Field provenance: docs/research/2026-09-22-claude-reset-credits.md.
//

import Foundation

/// One grant in the `cedar_ember` bank.
nonisolated struct ClaudeLimitResetGrant: Codable, Equatable, Identifiable {
    let id: String
    let label: String?
    let resetsLeft: Int
    let resetsTotal: Int?
    let startsAt: Date?
    /// The use-by date. nil means no deadline.
    let endsAt: Date?
    /// The limit types it refills (`five_hour`, `seven_day`, …).
    let clears: [String]
    /// Limit types that block its use while they are exhausted.
    let blocking: [String]
    let usableNow: Bool?
    let paused: Bool?
    /// True (the server's default): the grant only works at a limit.
    let useRequiresLimit: Bool

    func isExpired(at now: Date) -> Bool { endsAt.map { $0 <= now } ?? false }
}

/// The `cedar_ember` block.
nonisolated struct ClaudeLimitResetBank: Codable, Equatable {
    let eligible: Bool?
    /// `surface`, `tier`, `no_grant`, … — or a reason the app has not seen.
    let ineligibleReason: String?
    let atLimit: Bool?
    let exhausted: [String]
    let grants: [ClaudeLimitResetGrant]
    /// True when a grant element could not be read. The balance is a sum over
    /// the grants, so a missing one would under-count: the count is then unknown.
    let hasUnreadableGrant: Bool
    let nextGrantId: String?
    let weeklyResetsAt: Date?
    let cooldownUntil: Date?

    /// Whether the grants that arrived can be summed at all: an empty list is
    /// what an ineligible caller gets, and an unreadable element would make
    /// the sum an under-count.
    var isCountKnown: Bool { !grants.isEmpty && !hasUnreadableGrant }

    /// The grants a count may include: not past their use-by date.
    func liveGrants(at now: Date) -> [ClaudeLimitResetGrant] {
        grants.filter { !$0.isExpired(at: now) }
    }

    /// Sum of `resets_left` over the live grants — or nil, UNKNOWN, when no
    /// grant arrived or one could not be read. It never reads an empty list
    /// as zero.
    func availableCount(at now: Date) -> Int? {
        guard isCountKnown else { return nil }
        return liveGrants(at: now).reduce(0) { $0 + $1.resetsLeft }
    }

    /// Of those, the ones the server says can be used right now (`usable_now`
    /// and not paused). nil unless the count is known and every live grant
    /// states `usable_now` — a hint beside the balance, never a gate.
    func usableNowCount(at now: Date) -> Int? {
        guard availableCount(at: now) != nil else { return nil }
        let live = liveGrants(at: now)
        guard live.allSatisfy({ $0.usableNow != nil }) else { return nil }
        return live.filter { $0.usableNow == true && $0.paused != true }.reduce(0) { $0 + $1.resetsLeft }
    }

    /// The soonest use-by among live grants that still hold a reset.
    func soonestUseBy(at now: Date) -> Date? {
        liveGrants(at: now).filter { $0.resetsLeft > 0 }.compactMap(\.endsAt).min()
    }
}

/// The `juniper_tide` block: one session reset a week, not a bank.
nonisolated struct ClaudeWeeklySessionReset: Codable, Equatable {
    let eligible: Bool?
    let ineligibleReason: String?
    let inExperiment: Bool?
    let arm: String?
    let available: Bool?
    let nextAvailableAt: Date?
    let resetsPerWeek: Int?
}

/// Both programs as the last usage read reported them. Stored on
/// `ClaudeUsage.claudeLimitResets`; nil when the payload carried neither.
nonisolated struct ClaudeLimitResets: Codable, Equatable {
    var bank: ClaudeLimitResetBank?
    var weeklySessionReset: ClaudeWeeklySessionReset?

    /// Why no count is known, in the server's words, for hover text and the
    /// inspector — nil when there is a count or the server gave no reason.
    var unknownReason: String? {
        guard let bank, !bank.isCountKnown else { return nil }
        return bank.ineligibleReason
    }
}

extension ClaudeUsage {
    /// Stores what one usage read said about limit resets: the decoded blocks,
    /// the count and usable-now derived from them, and a measurement stamp
    /// only beside a known count. Replaces whatever the previous read said —
    /// a read that reports nothing makes the count unknown again.
    nonisolated mutating func applyLimitResets(_ resets: ClaudeLimitResets?, measuredAt now: Date) {
        claudeLimitResets = resets
        claudeLimitResetsAvailable = resets?.bank?.availableCount(at: now)
        claudeLimitResetsUsableNow = resets?.bank?.usableNowCount(at: now)
        claudeLimitResetsMeasuredAt = claudeLimitResetsAvailable == nil ? nil : now
    }
}

// MARK: - Decoding

extension ClaudeLimitResets {
    /// Reads both program blocks out of a usage payload. Never throws: absent,
    /// null or mistyped blocks read as nothing known, unknown keys are ignored,
    /// and a single unreadable grant costs that grant (and the count), never
    /// the block — the usage sweep that carries this is load-bearing for the
    /// auto-switch.
    nonisolated static func decode(usagePayload json: [String: Any]) -> ClaudeLimitResets? {
        let bank = (json["cedar_ember"] as? [String: Any]).map(decodeBank)
        let weekly = (json["juniper_tide"] as? [String: Any]).map(decodeWeekly)
        guard bank != nil || weekly != nil else { return nil }
        return ClaudeLimitResets(bank: bank, weeklySessionReset: weekly)
    }

    private nonisolated static func decodeBank(_ block: [String: Any]) -> ClaudeLimitResetBank {
        var grants: [ClaudeLimitResetGrant] = []
        var unreadable = false
        if let raw = block["grants"], !(raw is NSNull) {
            if let elements = raw as? [Any] {
                for element in elements {
                    if let object = element as? [String: Any], let grant = decodeGrant(object) {
                        grants.append(grant)
                    } else {
                        unreadable = true
                    }
                }
            } else {
                unreadable = true
            }
        }
        return ClaudeLimitResetBank(
            eligible: bool(block["eligible"]),
            ineligibleReason: string(block["ineligible_reason"]),
            atLimit: bool(block["at_limit"]),
            exhausted: strings(block["exhausted"]),
            grants: grants,
            hasUnreadableGrant: unreadable,
            nextGrantId: string(block["next_grant_id"]),
            weeklyResetsAt: date(block["weekly_resets_at"]),
            cooldownUntil: date(block["cooldown_until"])
        )
    }

    /// A grant needs an id and a readable `resets_left`; everything else is
    /// optional detail.
    private nonisolated static func decodeGrant(_ object: [String: Any]) -> ClaudeLimitResetGrant? {
        guard let id = string(object["id"]), let resetsLeft = count(object["resets_left"]) else { return nil }
        return ClaudeLimitResetGrant(
            id: id,
            label: string(object["label"]),
            resetsLeft: resetsLeft,
            resetsTotal: count(object["resets_total"]),
            startsAt: date(object["starts_at"]),
            endsAt: date(object["ends_at"]),
            clears: strings(object["clears"]),
            blocking: strings(object["blocking"]),
            usableNow: bool(object["usable_now"]),
            paused: bool(object["paused"]),
            useRequiresLimit: bool(object["use_requires_limit"]) ?? true
        )
    }

    private nonisolated static func decodeWeekly(_ block: [String: Any]) -> ClaudeWeeklySessionReset {
        ClaudeWeeklySessionReset(
            eligible: bool(block["eligible"]),
            ineligibleReason: string(block["ineligible_reason"]),
            inExperiment: bool(block["in_experiment"]),
            arm: string(block["arm"]),
            available: bool(block["available"]),
            nextAvailableAt: date(block["next_available_at"]),
            resetsPerWeek: count(block["resets_per_week"])
        )
    }

    // JSONSerialization hands booleans back as NSNumber, which also bridges to
    // Int (and numbers to Bool), so each reader checks the CoreFoundation type.

    private nonisolated static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private nonisolated static func bool(_ value: Any?) -> Bool? {
        guard let value, isBoolean(value) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// A non-negative whole number, or nil.
    private nonisolated static func count(_ value: Any?) -> Int? {
        guard let value, !isBoolean(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= Double(Int32.max), double.rounded() == double else { return nil }
        return Int(double)
    }

    private nonisolated static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private nonisolated static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private nonisolated static func date(_ value: Any?) -> Date? {
        string(value).flatMap { CodexResetCredits.rfc3339Date($0) }
    }
}
