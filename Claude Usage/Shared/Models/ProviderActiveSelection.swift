//
//  ProviderActiveSelection.swift
//  Claude Usage
//
//  The two concepts the UX revamp separates (docs/specs/ux-revamp.md §1):
//
//    VIEWING  — the one account the inspector / popover show. Free; never
//               touches a CLI (`ProfileManager.viewProfile`).
//    ACTIVE FOR <provider> — the account each CLI is using (the provider
//               pointers). Changed only by "Make active for <provider>…", the
//               auto-switch, or a CLI-side login the sweep adopts.
//
//  This file holds the shared vocabulary every surface uses for them, and the
//  pure model behind the per-provider ACTIVE selector (§2.1): who is active,
//  with what evidence, who is next, who else could be switched to and why
//  not. Built ONCE per menu open / per paint from the same readiness /
//  candidate / verdict context the fleet tiles and the dashboard read
//  (`FleetSummaryContext`); its `Inputs` mirror `DashboardSnapshot.Inputs` so
//  the dashboard can build it inside its own snapshot.
//

import Foundation

// MARK: - Vocabulary

/// The words for the two concepts. One source, so "Active" never appears
/// without its provider again.
enum ActiveVocabulary {
    /// "Viewing"
    static var viewing: String { "active.viewing".localized }

    /// "Claude" / "Codex" / "Grok".
    static func providerName(_ provider: Profile.ProviderKind) -> String {
        switch provider {
        case .claude: return "provider.claude".localized
        case .codex: return "provider.codex".localized
        case .grok: return "provider.grok".localized
        }
    }

    /// The CLI whose login the provider pointer names: "Claude Code" /
    /// "Codex CLI" / "Grok CLI" — for the switch confirmation's cost sentence.
    static func cliName(_ provider: Profile.ProviderKind) -> String {
        switch provider {
        case .claude: return "provider.cli.claude".localized
        case .codex: return "provider.cli.codex".localized
        case .grok: return "provider.cli.grok".localized
        }
    }

    /// "Active for Claude"
    /// The one word on the active mark ("Active"); the provider goes in the tooltip.
    static var activeWord: String { "active.word".localized }

    static func activeFor(_ provider: Profile.ProviderKind) -> String {
        "active.active_for".localized(with: providerName(provider))
    }

    /// "Make active for Claude…" — always with the ellipsis: a confirmation follows.
    static func makeActive(_ provider: Profile.ProviderKind) -> String {
        "active.make_active".localized(with: providerName(provider))
    }

    /// "No active Claude login"
    static func noActiveLogin(_ provider: Profile.ProviderKind) -> String {
        "active.no_active_login".localized(with: providerName(provider))
    }

    /// The R3 caption: "Viewing Cedar · Active for Claude: Atlas", or
    /// "Viewing Cedar · no active Claude login" when the provider has no owner.
    static func viewingLine(viewing: String, provider: Profile.ProviderKind, owner: String?) -> String {
        if let owner {
            return "active.viewing_line".localized(with: viewing, providerName(provider), owner)
        }
        return "active.viewing_line_none".localized(with: viewing, providerName(provider))
    }

    /// "Active for Claude changed outside the app: now Lark"
    static func changedOutside(_ provider: Profile.ProviderKind, newOwner: String) -> String {
        "active.changed_outside".localized(with: providerName(provider), newOwner)
    }

    /// The one-line summary for a menu (S2): "9 accounts · 5 eligible · 1 dead · 2 duplicates".
    static func countsShort(_ counts: FleetCounts.Provider) -> String {
        var parts = ["counts.accounts".localized(with: counts.distinctAccounts),
                     "counts.eligible_short".localized(with: counts.autoSwitchEligible)]
        if counts.count(.dead) > 0 { parts.append("counts.dead".localized(with: counts.count(.dead))) }
        if counts.duplicateProfiles > 0 { parts.append("counts.duplicates_short".localized(with: counts.duplicateProfiles)) }
        return parts.joined(separator: " · ")
    }

    /// The roster header's words (owner ruling 2026-09-04, replacing the glyph
    /// strip): "4 ready · 2 low · 10 exhausted · 1 dead · 2 duplicates". States
    /// in readiness order, zero counts omitted; the glyph legend moves to hover.
    static func countsWords(_ counts: FleetCounts.Provider) -> String {
        var parts: [String] = []
        // One line at the sidebar's width: each light/bright pair merges by
        // hue (the dot itself carries the nuance); `countsSentence` keeps all six.
        let hues: [([AccountReadiness], String)] = [
            ([.ready, .readyLight], "counts.ready"), ([.unknown], "counts.unknown"), ([.suspected], "counts.suspected"),
            ([.sessionHit, .sessionHitLight], "counts.session_hit_short"), ([.weeklyHitSoon, .weeklyHit], "counts.weekly_hit_short"),
            ([.excluded], "counts.excluded"), ([.dead], "counts.dead"),
        ]
        for (states, key) in hues {
            let n = states.reduce(0) { $0 + counts.count($1) }
            if n > 0 { parts.append(key.localized(with: n)) }
        }
        if counts.duplicateProfiles > 0 { parts.append("counts.duplicates_short".localized(with: counts.duplicateProfiles)) }
        // A count never wraps away from its word; the line breaks only at the separators.
        let glued = parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
        return glued.isEmpty ? "counts.none_measured".localized : glued.joined(separator: " · ")
    }

    /// The strings key for one readiness count ("%d ready" …).
    static func countsKey(_ readiness: AccountReadiness) -> String {
        switch readiness {
        case .ready: return "counts.ready"
        case .readyLight: return "counts.ready_light"
        case .sessionHit: return "counts.session_hit"
        case .sessionHitLight: return "counts.session_hit_light"
        case .weeklyHitSoon: return "counts.weekly_hit_soon"
        case .weeklyHit: return "counts.weekly_hit"
        case .unknown: return "counts.unknown"
        case .suspected: return "counts.suspected"
        case .excluded: return "counts.excluded"
        case .dead: return "counts.dead"
        }
    }

    /// The counts sentence for a provider (docs/specs/ux-revamp.md §3):
    /// "18 Claude profiles, 17 accounts: 4 ready, 2 low, 1 unmeasured,
    /// 10 exhausted, 1 dead · 2 duplicate rows · 7 eligible now".
    static func countsSentence(_ counts: FleetCounts.Provider) -> String {
        var states: [String] = []
        let keys: [(AccountReadiness, String)] = AccountReadiness.legendOrder.map { ($0, ActiveVocabulary.countsKey($0)) }
        for (readiness, key) in keys {
            let n = counts.count(readiness)
            if n > 0 { states.append(key.localized(with: n)) }
        }
        var out = "counts.profiles_accounts".localized(
            with: counts.profiles, providerName(counts.provider), counts.distinctAccounts)
        if !states.isEmpty { out += ": " + states.joined(separator: ", ") }
        if counts.duplicateProfiles > 0 {
            out += " · " + "counts.duplicates".localized(with: counts.duplicateProfiles)
        }
        out += " · " + "counts.eligible".localized(with: counts.autoSwitchEligible)
        return out
    }
}

extension Notification.Name {
    /// Posted to open the ⇄ selector menu on one provider's section (object:
    /// `Profile.ProviderKind`, or nil for the whole menu). The dashboard's
    /// section header posts it; the selector item observes it.
    static let activeSelectorRequested = Notification.Name("activeSelectorRequested")
}

// MARK: - Rows

/// The provider-active account as the selector shows it.
struct OwnerRow: Hashable {
    var id: UUID
    var name: String
    var readiness: AccountReadiness
    var gauges: [WindowGauge]
    /// Provenance + age of the shown numbers — R5: "own · 28 s ago" vs
    /// "headers · 3 m ago"; nil when never measured.
    var measurement: UsageMeasurement?
    /// Set while the account is under an inferred throttle: the last measured
    /// value + its age (+ projection) are shown, never a live-looking number.
    var suspected: SuspectedCaveat?
    /// The display-seam percentage the menu prints (never `effectiveSessionPercentage`).
    var keyedPercentage: Double?
    var etaToThreshold: TimeInterval?
    /// The user activated this account by hand while it was over a threshold;
    /// the auto-switch will not leave it until it regains headroom.
    var isManuallyPinned: Bool
    /// Other profiles that hold the SAME account (one quota).
    var sameAccountAs: [String]
    /// Codex only: usage-limit reset credits the usage payload reported
    /// (nil = none / unknown — indistinguishable on the wire, spec §4.1).
    var resetCreditsAvailable: Int? = nil
    /// The last on-demand detail answer this process fetched for the account
    /// (`CodexUsageService.cachedResetCredits`), if any — the only source of an
    /// expiry; nil until the owner has opened the account's Overview once.
    var resetsDetail: ResetsDetail? = nil

    struct ResetsDetail: Hashable {
        /// Soonest expiry among the usable grants; nil = the soonest never expires.
        var soonestExpiry: Date?
        var fetchedAt: Date
        var availableCount: Int
    }
}

/// One account the user could switch the provider to, and why (not).
struct CandidateRow: Hashable {
    enum Status: Hashable {
        /// The walk would take it: ready, low, or never measured.
        case eligible
        /// Not executable right now (exhausted, suspected, dead).
        case blocked(AccountReadiness)
        /// Same account as the current owner — a switch would change nothing.
        case duplicateOfOwner(ownerName: String)
        /// The walk never picks it: the user's toggle, or a free-plan login.
        case excluded(ExclusionReason)
    }

    enum ExclusionReason: Hashable { case autoSwitchOff, freePlan }

    var id: UUID
    var name: String
    var readiness: AccountReadiness
    var isStale: Bool
    var gauges: [WindowGauge]
    var measurement: UsageMeasurement?
    /// Login evidence — a separate axis from the quota evidence above.
    var verdict: NextCandidate.Verdict
    var verdictKind: PreflightVerdict.Kind?
    var verdictAt: Date?
    var status: Status
    /// 1-based position in the user's hand-off queue, when queued.
    var queuePosition: Int?
    /// #64: a contaminated / duplicate non-owner the user must re-login.
    var needsRelogin: Bool
    var repair: RepairAction?
    /// True for the account the auto-switch would pick next.
    var isNext: Bool
}

struct AutoSwitchPolicy: Hashable {
    var enabled: Bool
    var sessionThreshold: Double
    var weeklyThreshold: Double
}

// MARK: - Selection

struct ProviderActiveSelection: Hashable {
    var provider: Profile.ProviderKind
    /// nil = no active login known for this provider.
    var owner: OwnerRow?
    /// The Viewing account when it belongs to this provider.
    var viewing: UUID?
    var next: NextCandidate?
    /// Every OTHER account of the provider: eligible rows first in the walk's
    /// rank order, then blocked, then duplicates and excluded — the menu draws
    /// a separator between the two halves.
    var candidates: [CandidateRow]
    /// Every OTHER account in the walk's plain rank order (soonest weekly reset
    /// first, queue entries first) — the roster sorts by this; `candidates`
    /// is the same set re-grouped eligible-first for the menu.
    var rankedIds: [UUID] = []
    /// This provider's slice of the hand-off queue.
    var queue: [QueueEntry]
    var counts: FleetCounts.Provider
    var autoSwitch: AutoSwitchPolicy
    var alert: FleetAlert?
    var isSwitching: Bool

    /// The candidates the walk could execute right now, in rank order.
    var eligibleCandidates: [CandidateRow] { candidates.filter { $0.status == .eligible } }
    /// The rest, for the second half of the submenu.
    var blockedCandidates: [CandidateRow] { candidates.filter { $0.status != .eligible } }

    /// Same shape as `DashboardSnapshot.Inputs` so the dashboard can build the
    /// selection inside its own once-per-paint snapshot.
    struct Inputs {
        var profiles: [Profile]
        /// Provider owners (`ProfileManager.activeAccountIds`).
        var activeIds: Set<UUID>
        /// Viewing (`ProfileManager.activeProfile?.id`).
        var focusedId: UUID?
        /// The bar's painted order per provider when known (else the ranking).
        var paintedOrder: [Profile.ProviderKind: [UUID]] = [:]
        var context: FleetSummaryContext
        var queue: [UUID]
        /// `FleetCounts.duplicateGroups(in:published:)`.
        var duplicateGroups: [[UUID]] = []
        /// `MenuBarManager.autoSwitchedProfileIds` (manual pins).
        var manuallyPinned: Set<UUID> = []
        /// `CodexUsageService.cachedResetCredits(for:)` per Codex profile — read,
        /// never fetched, so the per-IP-limited endpoint is never touched here.
        var cachedResets: [UUID: CodexResetCredits] = [:]
        /// `ProfileManager.profilesNeedingAccountRelogin`.
        var needsRelogin: Set<UUID> = []
        var autoSwitchEnabled: Bool = true
    }

    /// Builds one selection per provider that has at least one profile.
    ///
    /// - Parameter ranking: the walk's rank order for a provider's candidates
    ///   (soonest weekly reset first, queue entries first). Defaults to
    ///   `MenuBarManager.rankAutoSwitchCandidates` — never a second resolver.
    static func build(
        _ inputs: Inputs,
        ranking: ((Profile.ProviderKind, [Profile]) -> [UUID])? = nil
    ) -> [ProviderActiveSelection] {
        let now = inputs.context.now
        let thresholds = inputs.context.thresholds
        let byId = Dictionary(uniqueKeysWithValues: inputs.profiles.map { ($0.id, $0) })

        var readiness: [UUID: AccountReadiness] = [:]
        var stale: Set<UUID> = []
        for profile in inputs.profiles {
            readiness[profile.id] = AccountReadiness.classify(
                usage: profile.claudeUsage,
                isLoginDead: inputs.context.isLoginDead(profile),
                isExcluded: inputs.context.isExcluded(profile),
                thresholds: thresholds,
                now: now
            )
            if AccountReadiness.isStale(profile.claudeUsage, thresholds: thresholds, now: now) {
                stale.insert(profile.id)
            }
        }

        var duplicates: [UUID: [String]] = [:]
        for group in inputs.duplicateGroups {
            for id in group {
                duplicates[id] = group.filter { $0 != id }.compactMap { byId[$0]?.name }
            }
        }
        let counts = FleetCounts.build(
            profiles: inputs.profiles, readiness: readiness, stale: stale,
            duplicateGroups: inputs.duplicateGroups, needsRelogin: inputs.needsRelogin,
            queue: inputs.queue, pinned: inputs.manuallyPinned, now: now
        )
        let policy = AutoSwitchPolicy(
            enabled: inputs.autoSwitchEnabled,
            sessionThreshold: thresholds.session,
            weeklyThreshold: thresholds.weekly
        )

        var selections: [ProviderActiveSelection] = []
        for provider in [Profile.ProviderKind.claude, .codex, .grok] {
            let members = inputs.profiles.filter { $0.providerKind == provider }
            guard !members.isEmpty, let providerCounts = counts.provider(provider) else { continue }

            let ownerId = members.first { inputs.activeIds.contains($0.id) }?.id
            let owner = ownerId.flatMap { byId[$0] }
            let ranked = ranking?(provider, members)
                ?? MenuBarManager.rankAutoSwitchCandidates(members, customOrder: inputs.queue, now: now).map(\.id)

            let predicted = inputs.context.nextCandidates[provider]
            let next = predicted.map { candidate -> NextCandidate in
                let candidateReadiness = readiness[candidate.id] ?? .unknown
                return NextCandidate(
                    id: candidate.id, label: candidate.label, queued: candidate.queued,
                    queueHeadBlocked: candidate.queueHeadBlocked, readiness: candidateReadiness,
                    verdict: NextCandidate.verdict(
                        readiness: candidateReadiness,
                        preflight: inputs.context.preflightVerdicts[candidate.id], now: now)
                )
            }

            // The alert and the arming rule are the fleet summary's — reuse it.
            let summary = ProviderSummary.build(
                provider: provider,
                orderedMembers: inputs.paintedOrder[provider] ?? Array(ranked.reversed()),
                activeId: ownerId,
                readiness: readiness,
                stale: stale,
                keyedPercentage: owner?.claudeUsage.map { ProviderSummary.keyedDisplayPercentage($0) },
                next: next,
                isSwitching: inputs.context.isSwitching,
                preferencesDegraded: inputs.context.preferencesDegraded,
                activeLastMeasured: owner?.claudeUsage?.lastUpdated,
                now: now
            )

            var rows: [CandidateRow] = []
            for id in ranked where id != ownerId {
                guard let profile = byId[id] else { continue }
                let state = readiness[id] ?? .unknown
                let status: CandidateRow.Status
                if let owner, !(duplicates[id] ?? []).isEmpty,
                   FleetCounts.accountKey(profile) == FleetCounts.accountKey(owner) {
                    status = .duplicateOfOwner(ownerName: owner.name)
                } else if state == .excluded {
                    status = .excluded(profile.isAutoSwitchEnabled ? .freePlan : .autoSwitchOff)
                } else if state.blocksSwitchTarget {
                    status = .blocked(state)
                } else {
                    status = .eligible
                }
                let preflight = inputs.context.preflightVerdicts[id]
                rows.append(CandidateRow(
                    id: id, name: profile.name, readiness: state, isStale: stale.contains(id),
                    gauges: profile.claudeUsage.map { DashboardSnapshot.gauges(for: $0, thresholds: thresholds) } ?? [],
                    measurement: DashboardSnapshot.measurement(for: profile.claudeUsage),
                    verdict: NextCandidate.verdict(readiness: state, preflight: preflight, now: now),
                    verdictKind: preflight?.kind, verdictAt: preflight?.at,
                    status: status,
                    queuePosition: inputs.queue.firstIndex(of: id).map { $0 + 1 },
                    needsRelogin: inputs.needsRelogin.contains(id),
                    repair: state == .dead ? repairAction(for: profile) : nil,
                    isNext: next?.id == id
                ))
            }
            // Eligible rows keep the rank order; everything else follows.
            let ordered = rows.filter { $0.status == .eligible } + rows.filter { $0.status != .eligible }

            let queue = inputs.queue.enumerated().compactMap { index, id -> QueueEntry? in
                guard let profile = byId[id], profile.providerKind == provider else { return nil }
                return QueueEntry(id: id, name: profile.name, position: index + 1,
                                  blocked: readiness[id]?.blocksSwitchTarget ?? true)
            }

            selections.append(ProviderActiveSelection(
                provider: provider,
                owner: owner.map { profile in
                    ownerRow(profile, readiness: readiness[profile.id] ?? .unknown,
                             pinned: inputs.manuallyPinned.contains(profile.id),
                             sameAccountAs: duplicates[profile.id] ?? [],
                             cachedResets: inputs.cachedResets[profile.id],
                             thresholds: thresholds, now: now)
                },
                viewing: inputs.focusedId.flatMap { id in members.contains { $0.id == id } ? id : nil },
                next: next,
                candidates: ordered,
                rankedIds: ranked.filter { $0 != ownerId },
                queue: queue,
                counts: providerCounts,
                autoSwitch: policy,
                alert: summary.alert,
                isSwitching: inputs.context.isSwitching
            ))
        }
        return selections
    }

    private static func ownerRow(_ profile: Profile, readiness: AccountReadiness, pinned: Bool,
                                 sameAccountAs: [String], cachedResets: CodexResetCredits?,
                                 thresholds: ReadinessThresholds, now: Date) -> OwnerRow {
        let usage = profile.claudeUsage
        let gauges = usage.map { DashboardSnapshot.gauges(for: $0, thresholds: thresholds) } ?? []
        let firing = gauges.first { $0.kind == .session } ?? gauges.first { $0.kind == .weekly }
        var caveat: SuspectedCaveat?
        if let usage, usage.isSuspectedRateLimited {
            caveat = SuspectedCaveat(lastMeasured: usage.sessionPercentage, measuredAt: usage.lastUpdated,
                                     projected: usage.projectedSessionPercentage)
        }
        return OwnerRow(
            id: profile.id, name: profile.name, readiness: readiness, gauges: gauges,
            measurement: DashboardSnapshot.measurement(for: usage), suspected: caveat,
            keyedPercentage: usage.map { ProviderSummary.keyedDisplayPercentage($0) },
            etaToThreshold: firing.flatMap { DashboardSnapshot.etaToThreshold($0, now: now) },
            isManuallyPinned: pinned, sameAccountAs: sameAccountAs,
            resetCreditsAvailable: profile.providerKind == .codex ? usage?.codexResetCreditsAvailable : nil,
            resetsDetail: cachedResets.map {
                OwnerRow.ResetsDetail(soonestExpiry: $0.availableCreditsByExpiry.first?.expiresAt, fetchedAt: $0.fetchedAt, availableCount: $0.availableCount)
            }
        )
    }

    private static func repairAction(for profile: Profile) -> RepairAction {
        switch profile.providerKind {
        case .claude: return .claudeLogin
        case .codex: return .codexLogin
        case .grok: return .grokLogin
        }
    }
}

// MARK: - Viewing navigation

/// The "next account" hotkey VIEWS the next account of the viewed provider
/// group — it never switches a CLI (docs/specs/ux-revamp.md D7; audit M7: the
/// old hotkey activated the next profile in array order, across providers).
enum ViewingNavigation {
    /// The account after `current` in `order` (the bar's painted order,
    /// left→right), wrapping; nil when `current` is not in `order` or the
    /// group has nothing else to view.
    static func next(after current: UUID, in order: [UUID]) -> UUID? {
        guard order.count > 1, let index = order.firstIndex(of: current) else { return nil }
        return order[(index + 1) % order.count]
    }
}
