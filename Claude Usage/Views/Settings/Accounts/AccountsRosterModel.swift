//
//  AccountsRosterModel.swift
//  Claude Usage
//
//  The pure model behind the Accounts inspector's roster sidebar
//  (docs/specs/ux-revamp.md §2.2, design pass §12.2): one section per
//  provider with its counts strip, one row per account with a readiness
//  glyph, the keyed percentage and ONE badge; sorting (the bar's order or
//  alphabetical) and a filter over names, emails and state words. Built from
//  the same `ProviderActiveSelection` snapshot the ⇄ selector and the
//  dashboard use — never a second classification.
//

import Foundation

enum AccountsRosterModel {
    enum Sort: String, CaseIterable, Hashable {
        /// The bar's order: soonest weekly reset first (the walk's rank).
        case bar
        case alphabetical
    }

    /// The ONE badge a row carries, by precedence.
    enum Badge: Hashable {
        /// Owns its provider's CLI login ("Cl" / "Cx" / "Gk", cyan).
        case activeFor(Profile.ProviderKind)
        case queued(position: Int)
        /// The account the auto-switch would pick next, with its login verdict.
        case next(NextCandidate.Verdict)
        case duplicate(of: String)
        case excluded(CandidateRow.ExclusionReason)
        case none
    }

    struct Row: Hashable {
        var id: UUID
        var name: String
        var email: String?
        var readiness: AccountReadiness
        var isStale: Bool
        /// Keyed percentage as text: session for Claude, weekly for Codex/Grok;
        /// "W!" / "S!" when maxed; "—" when never measured.
        var percentageText: String
        var badge: Badge
        var needsRelogin: Bool
        var isDead: Bool { readiness == .dead }
        /// Words the filter matches besides name/email.
        var stateWords: [String]
    }

    struct Section: Hashable {
        var provider: Profile.ProviderKind
        var counts: FleetCounts.Provider
        var rows: [Row]
        var title: String { ActiveVocabulary.providerName(provider).uppercased() }
        /// "18 profiles · 17 accounts" — stated so nobody sums the glyphs.
        var subtitle: String {
            if counts.profiles == 1 { return "accounts.roster.profile_one".localized }
            // Only stamped identities can be counted as accounts; until every
            // profile is identified the honest number is how many are.
            if counts.identifiedAccounts < counts.profiles - (counts.profiles - counts.distinctAccounts) {
                return counts.identifiedAccounts == 0
                    ? "accounts.roster.profiles".localized(with: counts.profiles)
                    : "accounts.roster.profiles_identified".localized(with: counts.profiles, counts.identifiedAccounts)
            }
            return counts.profiles == counts.distinctAccounts
                ? "accounts.roster.profiles".localized(with: counts.profiles)
                : "accounts.roster.profiles_accounts".localized(with: counts.profiles, counts.distinctAccounts)
        }
        var strip: String { counts.strip }
    }

    /// - Parameters:
    ///   - selections: the per-provider selection snapshot.
    ///   - profiles: for emails and the alphabetical sort.
    ///   - filter: matched case-insensitively against name, email and state words.
    static func sections(
        selections: [ProviderActiveSelection],
        profiles: [Profile],
        sort: Sort,
        filter: String
    ) -> [Section] {
        let byId = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Section] = []
        for selection in selections {
            var rows: [Row] = []
            if let owner = selection.owner, let profile = byId[owner.id] {
                rows.append(Row(
                    id: owner.id, name: owner.name, email: email(of: profile), readiness: owner.readiness,
                    isStale: false, percentageText: percentageText(owner.gauges, readiness: owner.readiness),
                    badge: .activeFor(selection.provider), needsRelogin: false,
                    stateWords: stateWords(readiness: owner.readiness, badge: .activeFor(selection.provider), pinned: owner.isManuallyPinned)
                ))
            }
            for candidate in selection.candidates {
                let badge = self.badge(for: candidate)
                rows.append(Row(
                    id: candidate.id, name: candidate.name, email: byId[candidate.id].flatMap(email(of:)),
                    readiness: candidate.readiness, isStale: candidate.isStale,
                    percentageText: percentageText(candidate.gauges, readiness: candidate.readiness),
                    badge: badge, needsRelogin: candidate.needsRelogin,
                    stateWords: stateWords(readiness: candidate.readiness, badge: badge, pinned: false)
                        + (candidate.needsRelogin ? ["relogin", "re-login"] : [])
                ))
            }
            // Candidates arrive eligible-first; the bar's order is the rank
            // order across ALL rows, which the selection keeps per group.
            if sort == .bar {
                rows = barOrder(rows, selection: selection)
            } else {
                rows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            if !needle.isEmpty {
                rows = rows.filter { row in
                    row.name.lowercased().contains(needle)
                        || (row.email?.lowercased().contains(needle) ?? false)
                        || row.stateWords.contains { $0.contains(needle) }
                }
            }
            guard !rows.isEmpty || needle.isEmpty else { continue }
            out.append(Section(provider: selection.provider, counts: selection.counts, rows: rows))
        }
        return out
    }

    /// The bar's order = the walk's rank: owner first (it is what the bar
    /// paints cyan), then every other account in the rank order the selection
    /// built its candidate list from — eligible first is the SELECTOR's order,
    /// the roster wants the plain rank, so re-interleave by the original rank.
    private static func barOrder(_ rows: [Row], selection: ProviderActiveSelection) -> [Row] {
        let rank = selection.rankedIds
        guard !rank.isEmpty else { return rows }
        let position = Dictionary(uniqueKeysWithValues: rank.enumerated().map { ($1, $0) })
        return rows.sorted { a, b in
            if a.badge.isActive != b.badge.isActive { return a.badge.isActive }
            return (position[a.id] ?? Int.max) < (position[b.id] ?? Int.max)
        }
    }

    static func badge(for candidate: CandidateRow) -> Badge {
        if let position = candidate.queuePosition { return .queued(position: position) }
        if candidate.isNext { return .next(candidate.verdict) }
        switch candidate.status {
        case .duplicateOfOwner(let ownerName): return .duplicate(of: ownerName)
        case .excluded(let reason): return .excluded(reason)
        case .eligible, .blocked: return .none
        }
    }

    /// The BINDING window with its letter (R2): "S 78" for Claude, "W 95" for a
    /// weekly-only provider; the maxed window wins with its "!" mark ("S!" /
    /// "W!" / "F!"); never measured → "—".
    static func percentageText(_ gauges: [WindowGauge], readiness: AccountReadiness) -> String {
        guard !gauges.isEmpty else { return "—" }
        if readiness.isAtLimit {
            // The legend's glyph for the hit window (R2-2): ◐ for the session,
            // ▲ for a weekly window — the owner's colour scheme split.
            if readiness.isSessionHit, let session = gauges.first(where: { $0.kind == .session }), session.percentage >= session.threshold { return "\(DesignGlyph.sessionHit) S \(Int(session.percentage.rounded()))" }
            if readiness.isWeeklyHit, let fable = gauges.first(where: { $0.kind == .fable }), fable.percentage >= fable.threshold { return "\(DesignGlyph.weeklyHit) F \(Int(fable.percentage.rounded()))" }
            if readiness.isWeeklyHit, let weekly = gauges.first(where: { $0.kind == .weekly }), weekly.percentage >= weekly.threshold { return "\(DesignGlyph.weeklyHit) W \(Int(weekly.percentage.rounded()))" }
        }
        guard let keyed = gauges.first(where: { $0.kind == .session }) ?? gauges.first(where: { $0.kind == .weekly }) else { return "—" }
        return "\(keyed.kind == .session ? "S" : "W") \(Int(keyed.percentage.rounded()))"
    }

    /// Keeps the domain readable (R3): "fernando@mymemori.app" → "f…@mymemori.app"
    /// when the local part is long; short addresses pass through.
    static func shortEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        let local = email[..<at], domain = email[at...]
        guard local.count > 4 else { return email }
        return String(local.prefix(1)) + "…" + domain
    }

    static func stateWords(readiness: AccountReadiness, badge: Badge, pinned: Bool) -> [String] {
        var words: [String] = []
        switch readiness {
        case .ready: words.append("ready")
        case .readyLight: words += ["ready", "low"]
        case .unknown: words += ["unknown", "unmeasured"]
        case .suspected: words += ["suspected", "blind"]
        case .sessionHit, .sessionHitLight: words += ["exhausted", "session"]
        case .weeklyHit, .weeklyHitSoon: words += ["exhausted", "maxed", "weekly"]
        case .excluded: words.append("excluded")
        case .dead: words.append("dead")
        }
        switch badge {
        case .activeFor: words.append("active")
        case .queued: words.append("queued")
        case .next: words.append("next")
        case .duplicate: words.append("duplicate")
        case .excluded(let reason): words.append(reason == .freePlan ? "free" : "off")
        case .none: break
        }
        if pinned { words.append("pinned") }
        return words
    }

    static func email(of profile: Profile) -> String? {
        let raw: String?
        switch profile.providerKind {
        case .claude: raw = profile.claudeAccountEmail
        case .codex: raw = profile.codexEmail
        case .grok: raw = profile.grokEmail
        }
        return raw.map(shortEmail)
    }
}

extension AccountsRosterModel.Badge {
    var isActive: Bool {
        if case .activeFor = self { return true }
        return false
    }

    /// The mark drawn at the row's right edge — words, not codes (R1): the
    /// provider's own name for the active account (drawn as a cyan pill),
    /// "queued 1", "free plan" / "excluded"; the shared glyphs for next and
    /// duplicate.
    var mark: String? {
        switch self {
        case .activeFor: return ActiveVocabulary.activeWord
        case .queued(let position): return "accounts.badge.queued".localized(with: position)
        case .next(let verdict): return verdict.glyph
        case .duplicate: return "⧉"
        case .excluded(let reason): return reason == .freePlan ? "accounts.badge.free_plan".localized : "accounts.badge.excluded".localized
        case .none: return nil
        }
    }
}
