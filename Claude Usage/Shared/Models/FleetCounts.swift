//
//  FleetCounts.swift
//  Claude Usage
//
//  "How many accounts do I have, and how many can I still use" — one pure
//  model behind the inspector's group headers, the ⇄ selector's summary
//  line, its tooltip and the dashboard header (docs/specs/ux-revamp.md §3).
//  Built on `AccountReadiness.classify` (never a second classification): the
//  caller passes the readiness / stale maps it already computed. Counts are
//  reported per PROFILE (rows) and per DISTINCT ACCOUNT (one quota), because
//  a duplicate pair is two rows over one quota and every capacity number must
//  be counted once.
//

import Foundation

struct FleetCounts: Hashable {
    /// One provider's counts.
    struct Provider: Hashable {
        var provider: Profile.ProviderKind
        /// Profile rows of this provider.
        var profiles: Int
        /// Distinct accounts behind those rows (`FleetCounts.accountKey`).
        var distinctAccounts: Int
        /// First-match partition of the rows — the seven states sum to `profiles`.
        var byReadiness: [AccountReadiness: Int]
        /// The two meanings of `.excluded`: a toggle the user flipped (still
        /// usable capacity) vs a free-plan login (not capacity).
        var excludedByToggle: Int
        var freePlan: Int
        /// Orthogonal flags — never part of the partition.
        var stale: Int
        var duplicateProfiles: Int
        var duplicateGroups: [[UUID]]
        /// Contaminated / duplicate non-owners that need a human re-login (#64).
        var needsRelogin: Int
        var queued: Int
        var onBar: Int
        var pinned: Int
        /// Distinct accounts whose login is not dead. An account excluded from
        /// the rotation is still the owner's to use, so it counts.
        var loginLive: Int
        /// Σ (100 − weekly %) over `loginLive` DISTINCT accounts with a live,
        /// measured weekly window — one planning number, never inflated by a
        /// duplicate row.
        var capacityRemaining: Double

        func count(_ readiness: AccountReadiness) -> Int { byReadiness[readiness] ?? 0 }

        /// Measured and has headroom.
        var measuredHeadroom: Int { count(.ready) + count(.low) }
        /// Exactly what the auto-switch walk would accept as a target: a
        /// never-measured account is a legal target (`blocksSwitchTarget`).
        var autoSwitchEligible: Int { measuredHeadroom + count(.unknown) }

        /// The bar's own glyphs, zero counts omitted, duplicates after a
        /// separator because they are rows of the partition too — the strip
        /// must never read as a sum: `18 · ●4 ◐2 ○1 ▲10 ×1 · ⧉2`.
        var strip: String {
            var parts: [String] = []
            for (readiness, glyph) in FleetCounts.stripGlyphs {
                let n = count(readiness)
                if n > 0 { parts.append("\(glyph)\(n)") }
            }
            var out = "\(profiles)"
            if !parts.isEmpty { out += " · " + parts.joined(separator: " ") }
            if duplicateProfiles > 0 { out += " · ⧉\(duplicateProfiles)" }
            return out
        }
    }

    /// Glyph per readiness state, in strip order. Same alphabet as the bar's
    /// dots and the dashboard chips (docs/specs/menubar-redesign.md §2.1).
    static let stripGlyphs: [(AccountReadiness, String)] = [
        (.ready, DesignGlyph.ready), (.low, DesignGlyph.low), (.unknown, DesignGlyph.unmeasured),
        (.suspected, DesignGlyph.suspected), (.exhausted, DesignGlyph.exhausted),
        (.excluded, DesignGlyph.excluded), (.dead, DesignGlyph.dead),
    ]

    var providers: [Provider]
    var profiles: Int
    var distinctAccounts: Int
    var dead: Int
    var duplicateProfiles: Int

    func provider(_ kind: Profile.ProviderKind) -> Provider? {
        providers.first { $0.provider == kind }
    }

    // MARK: - Identity

    /// The non-secret stamp that identifies the ACCOUNT behind a profile
    /// (`claudeAccountUUID`, `codexAccountId`); an unstamped profile — and every
    /// Grok profile, which has no persisted account id — is its own account.
    static func accountKey(_ profile: Profile) -> String {
        switch profile.providerKind {
        case .claude:
            if let uuid = profile.claudeAccountUUID, !uuid.isEmpty { return "claude:\(uuid)" }
        case .codex:
            if let id = profile.codexAccountId, !id.isEmpty { return "codex:\(id)" }
        case .grok:
            break
        }
        return "profile:\(profile.id.uuidString)"
    }

    /// Duplicate groups for the whole roster: the published Claude groups
    /// (`ProfileManager.duplicateClaudeAccountGroups`, which the manager
    /// recomputes on every roster mutation) plus the groups derived here from
    /// the non-secret stamps — Claude's `claudeAccountUUID` (same rule as the
    /// manager's) and Codex's `account_id`, which nobody publishes today. A
    /// derived group that repeats a published one is dropped, so a caller may
    /// pass an empty `published` list and still get every duplicate. Each
    /// group keeps the roster's order.
    static func duplicateGroups(in profiles: [Profile], published: [[UUID]]) -> [[UUID]] {
        var groups = published.filter { $0.count > 1 }
        var seen = Set(groups.map { Set($0) })
        func add(_ derived: [[UUID]]) {
            for group in derived where group.count > 1 && !seen.contains(Set(group)) {
                groups.append(group)
                seen.insert(Set(group))
            }
        }
        add(ProfileManager.duplicateClaudeAccountGroups(in: profiles))
        var codexByAccount: [String: [UUID]] = [:]
        var codexOrder: [String] = []
        for profile in profiles where profile.providerKind == .codex {
            guard let id = profile.codexAccountId, !id.isEmpty else { continue }
            if codexByAccount[id] == nil { codexOrder.append(id) }
            codexByAccount[id, default: []].append(profile.id)
        }
        add(codexOrder.compactMap { codexByAccount[$0] })
        return groups
    }

    // MARK: - Build

    /// - Parameters:
    ///   - readiness / stale: the per-profile classification the caller already
    ///     computed (`AccountReadiness.classify` / `isStale`).
    ///   - duplicateGroups: `FleetCounts.duplicateGroups(in:published:)`.
    ///   - needsRelogin: `ProfileManager.profilesNeedingAccountRelogin`.
    ///   - pinned: profiles the user activated by hand while over a threshold
    ///     (`MenuBarManager.autoSwitchedProfileIds`).
    static func build(
        profiles: [Profile],
        readiness: [UUID: AccountReadiness],
        stale: Set<UUID>,
        duplicateGroups: [[UUID]],
        needsRelogin: Set<UUID> = [],
        queue: [UUID] = [],
        pinned: Set<UUID> = [],
        now: Date
    ) -> FleetCounts {
        let duplicateIds = Set(duplicateGroups.flatMap { $0 })
        let queued = Set(queue)
        var providers: [Provider] = []

        for kind in [Profile.ProviderKind.claude, .codex, .grok] {
            let rows = profiles.filter { $0.providerKind == kind }
            guard !rows.isEmpty else { continue }

            var byReadiness: [AccountReadiness: Int] = [:]
            var excludedByToggle = 0
            var freePlan = 0
            var byAccount: [String: [Profile]] = [:]
            for profile in rows {
                let state = readiness[profile.id] ?? .unknown
                byReadiness[state, default: 0] += 1
                if state == .excluded {
                    if profile.isAutoSwitchEnabled { freePlan += 1 } else { excludedByToggle += 1 }
                }
                byAccount[accountKey(profile), default: []].append(profile)
            }

            var loginLive = 0
            var capacity: Double = 0
            for (_, members) in byAccount {
                let alive = members.filter { (readiness[$0.id] ?? .unknown) != .dead }
                guard !alive.isEmpty else { continue }
                loginLive += 1
                // One quota per account: read it from the freshest live measurement.
                let freshest = alive
                    .compactMap { profile in profile.claudeUsage.map { (profile, $0) } }
                    .max { $0.1.lastUpdated < $1.1.lastUpdated }
                if let usage = freshest?.1, usage.weeklyResetTime >= now {
                    capacity += max(0, 100 - usage.weeklyPercentage)
                }
            }

            providers.append(Provider(
                provider: kind,
                profiles: rows.count,
                distinctAccounts: byAccount.count,
                byReadiness: byReadiness,
                excludedByToggle: excludedByToggle,
                freePlan: freePlan,
                stale: rows.filter { stale.contains($0.id) }.count,
                duplicateProfiles: rows.filter { duplicateIds.contains($0.id) }.count,
                duplicateGroups: duplicateGroups.filter { group in
                    group.contains { id in rows.contains { $0.id == id } }
                },
                needsRelogin: rows.filter { needsRelogin.contains($0.id) }.count,
                queued: rows.filter { queued.contains($0.id) }.count,
                onBar: rows.filter(\.isSelectedForDisplay).count,
                pinned: rows.filter { pinned.contains($0.id) }.count,
                loginLive: loginLive,
                capacityRemaining: capacity
            ))
        }

        return FleetCounts(
            providers: providers,
            profiles: providers.reduce(0) { $0 + $1.profiles },
            distinctAccounts: providers.reduce(0) { $0 + $1.distinctAccounts },
            dead: providers.reduce(0) { $0 + $1.count(.dead) },
            duplicateProfiles: providers.reduce(0) { $0 + $1.duplicateProfiles }
        )
    }
}
