//
//  ActiveSelectorMenuModel.swift
//  Claude Usage
//
//  The pure model behind the ⇄ selector's menu, badge, tooltip and switch
//  confirmation (docs/specs/ux-revamp.md §2.1, design pass §12.1). Every row
//  is a plain value — title, detail, glyph, tint, enabled, action — so the
//  frames can be tested without AppKit; `ActiveSelectorItem` maps rows to
//  `NSMenuItem`s one-to-one and adds nothing of its own.
//

import Foundation

enum ActiveSelectorMenuModel {
    /// Colour roles; the AppKit layer maps them to system colours so light and
    /// dark menus both work.
    enum Tint: Hashable { case cyan, green, orange, red, purple, secondary }

    /// The item's attention badge, by precedence (frame 0).
    enum Badge: Hashable {
        case red     // no executable candidate, or a dead active login
        case purple  // an active account is suspected / blind
        case amber   // cfprefsd degraded
    }

    /// What a row does when chosen. `nil` rows are informational (disabled).
    enum Action: Hashable {
        case switchTo(UUID, Profile.ProviderKind)
        case queueNext(UUID)
        case editQueue
        case repairDead(UUID, Profile.ProviderKind)
        case openActiveSettings
        case openAccounts
        case openDashboard
        case openTelemetry
        /// Flip the fleet-wide auto-switch (the checkmark footer item, S5).
        case toggleAutoSwitch(enabled: Bool)
    }

    struct Row: Hashable {
        enum Kind: Hashable { case header, banner, info, action, separator }
        var kind: Kind
        var title: String
        /// Secondary text drawn after the title (monospaced digits when it is numbers).
        var detail: String? = nil
        var glyph: String? = nil
        var glyphTint: Tint? = nil
        var titleTint: Tint? = nil
        var enabled: Bool = true
        var action: Action? = nil
        /// The one action per provider a user reaches for first — drawn bold.
        var isPrimary: Bool = false
        /// A state item (checkmark) rather than a command.
        var checked: Bool = false
        /// Rows of a submenu (the "Switch X to ▸" and "Queue next ▸" lists).
        var submenu: [Row] = []
        /// The ⌥ alternate of this row, shown in its place while Option is held.
        var alternate: Row? { alternateTitle.map { Row(kind: .action, title: $0, glyph: glyph, glyphTint: glyphTint, action: alternateAction) } }
        var alternateTitle: String? = nil
        var alternateAction: Action? = nil

        static let separator = Row(kind: .separator, title: "")
    }

    // MARK: - Rows

    /// - Parameters:
    ///   - externalChanges: provider → new owner name for owners that changed
    ///     outside the app since the menu was last opened (frame 8).
    static func rows(
        selections: [ProviderActiveSelection],
        preferencesDegraded: Bool,
        externalChanges: [Profile.ProviderKind: String],
        switching: (provider: Profile.ProviderKind, target: String)?,
        now: Date
    ) -> [Row] {
        var rows: [Row] = []
        if preferencesDegraded {
            rows.append(Row(kind: .banner, title: "selector.degraded".localized, glyph: "⚠", glyphTint: .orange, titleTint: .orange, enabled: false))
        }
        let anySwitching = switching != nil || selections.contains { $0.isSwitching }

        for selection in selections {
            let provider = selection.provider
            rows.append(Row(kind: .header, title: ActiveVocabulary.activeFor(provider).uppercased(), enabled: false))

            if let owner = selection.owner {
                rows.append(ownerRow(owner, provider: provider, hasCandidates: !selection.candidates.isEmpty, now: now))
            } else {
                rows.append(Row(kind: .info, title: "selector.no_owner_chosen".localized(with: ActiveVocabulary.providerName(provider)),
                                glyph: "○", glyphTint: .secondary, titleTint: .secondary, enabled: false))
            }
            if let newOwner = externalChanges[provider] {
                rows.append(Row(kind: .banner, title: ActiveVocabulary.changedOutside(provider, newOwner: newOwner),
                                glyph: "↺", glyphTint: .cyan, titleTint: .cyan, enabled: false))
            }
            if let owner = selection.owner, provider == .codex, let resets = owner.resetCreditsAvailable, resets > 0 {
                rows.append(Row(kind: .info, title: resetsRowTitle(count: resets, detail: owner.resetsDetail), glyph: "↻", glyphTint: .secondary, enabled: false))
            }

            let deadCount = selection.counts.count(.dead)
            let needsSentence = deadCount > 0 || selection.counts.duplicateProfiles > 0 || selection.alert == .noCandidate
            if needsSentence, selection.candidates.count + (selection.owner == nil ? 0 : 1) > 1 {
                // One line (S2); the full breakdown lives in the tooltip and the inspector.
                rows.append(Row(kind: .info, title: ActiveVocabulary.countsShort(selection.counts), titleTint: .secondary, enabled: false))
            }

            if let switching, switching.provider == provider {
                rows.append(Row(kind: .banner, title: "selector.switching".localized(with: ActiveVocabulary.providerName(provider), switching.target),
                                glyph: "⇄", glyphTint: .cyan, titleTint: .cyan, enabled: false))
            }

            if selection.candidates.isEmpty {
                rows.append(Row(kind: .info, title: "selector.single_account".localized, titleTint: .secondary, enabled: false))
                continue
            }

            // Evidence row: the next candidate and what is known about it.
            rows.append(evidenceRow(selection, now: now))
            // Status above, actions below (S3).
            rows.append(.separator)

            let eligible = selection.eligibleCandidates
            if let next = selection.next, let nextRow = selection.candidates.first(where: { $0.id == next.id }), nextRow.status == .eligible {
                rows.append(Row(kind: .action,
                                title: "selector.switch_to_next".localized(with: ActiveVocabulary.providerName(provider), nextRow.name),
                                enabled: !anySwitching, action: .switchTo(nextRow.id, provider), isPrimary: true))
            }
            rows.append(Row(kind: .action, title: "selector.switch_to".localized(with: ActiveVocabulary.providerName(provider)),
                            enabled: !anySwitching,
                            submenu: candidateRows(selection, now: now, switching: anySwitching)))
            if !eligible.isEmpty {
                rows.append(Row(kind: .action, title: "selector.queue_next".localized, enabled: !anySwitching,
                                submenu: eligible.map { candidate in
                                    Row(kind: .action, title: candidate.name, detail: gaugeText(candidate.gauges),
                                        glyph: glyph(for: candidate.readiness), glyphTint: tint(for: candidate.readiness),
                                        enabled: !anySwitching, action: .queueNext(candidate.id))
                                }))
            }
            if !selection.queue.isEmpty {
                rows.append(Row(kind: .action,
                                title: "selector.queue_line".localized(with: selection.queue.map(\.name).joined(separator: " › ")),
                                glyph: "≡", glyphTint: .secondary, action: .editQueue))
            }
            if deadCount > 0, let firstDead = selection.candidates.first(where: { $0.readiness == .dead }) {
                rows.append(Row(kind: .action,
                                title: deadCount == 1
                                    ? "selector.repair_one".localized(with: ActiveVocabulary.providerName(provider))
                                    : "selector.repair_many".localized(with: deadCount, ActiveVocabulary.providerName(provider)),
                                glyph: DesignGlyph.dead, glyphTint: .red, action: .repairDead(firstDead.id, provider)))
            }
        }

        rows.append(.separator)
        if let policy = selections.first?.autoSwitch {
            // A state the user can act on (S5): a checkmark item that toggles
            // the fleet-wide auto-switch; the thresholds stay in Settings.
            rows.append(Row(kind: .action,
                            title: "selector.policy_toggle".localized(with: Int(policy.sessionThreshold), Int(policy.weeklyThreshold)),
                            action: .toggleAutoSwitch(enabled: !policy.enabled), checked: policy.enabled))
        }
        rows.append(Row(kind: .action, title: "selector.open_active_settings".localized, action: .openActiveSettings))
        rows.append(Row(kind: .action, title: "selector.open_accounts".localized, action: .openAccounts))
        rows.append(Row(kind: .action, title: "selector.open_dashboard".localized, action: .openDashboard))
        rows.append(Row(kind: .action, title: "selector.open_telemetry".localized, action: .openTelemetry))
        return rows
    }

    private static func ownerRow(_ owner: OwnerRow, provider: Profile.ProviderKind, hasCandidates: Bool, now: Date) -> Row {
        var details: [String] = []
        var tint: Tint? = nil
        if let caveat = owner.suspected {
            var text = "selector.last_measured".localized(with: Int(caveat.lastMeasured.rounded()), DashboardFormatting.age(caveat.measuredAt, now: now))
            if let projected = caveat.projected {
                text += " " + "selector.projection".localized(with: Int(projected.rounded()))
            }
            details.append(text)
            tint = .purple
        } else {
            details.append(compactGaugeText(owner.gauges))
            // "fires at 99 %" names the switch trigger — meaningless for a
            // provider with nobody to switch to.
            if hasCandidates, let weekly = owner.gauges.first(where: { $0.kind == .weekly }),
               !owner.gauges.contains(where: { $0.kind == .session }) {
                details.append("selector.fires_at".localized(with: Int(weekly.threshold)))
            }
        }
        if let measurement = owner.measurement {
            details.append(DashboardFormatting.provenance(measurement, now: now))
        }
        if owner.isManuallyPinned { details.append("selector.pinned".localized) }
        if !owner.sameAccountAs.isEmpty {
            details.append("selector.same_account".localized(with: owner.sameAccountAs.joined(separator: ", ")))
        }
        return Row(kind: .info, title: owner.name, detail: details.joined(separator: " · "),
                   glyph: glyph(for: owner.readiness), glyphTint: .cyan, titleTint: tint, enabled: false)
    }

    private static func evidenceRow(_ selection: ProviderActiveSelection, now: Date) -> Row {
        guard let next = selection.next, let row = selection.candidates.first(where: { $0.id == next.id }) else {
            let dead = selection.counts.count(.dead)
            let total = selection.counts.profiles
            let reason = dead > 0
                ? "selector.no_candidate_dead".localized(with: dead, total)
                : "selector.no_candidate".localized
            return Row(kind: .info, title: reason, glyph: "→", glyphTint: .red, titleTint: .red, enabled: false)
        }
        var parts: [String] = []
        parts.append(next.queued ? "selector.queued".localized : (next.queueHeadBlocked ? "selector.ranked_blocked_head".localized : "selector.ranked".localized))
        parts.append(verdictText(row.verdict, kind: row.verdictKind, at: row.verdictAt, now: now))
        if let measurement = row.measurement {
            parts.append("selector.headroom_age".localized(with: DashboardFormatting.age(measurement.measuredAt, now: now)))
        }
        return Row(kind: .info, title: "selector.next".localized(with: row.name), detail: parts.joined(separator: " · "),
                   glyph: "→", glyphTint: tint(for: next.verdict), enabled: false)
    }

    private static func candidateRows(_ selection: ProviderActiveSelection, now: Date, switching: Bool) -> [Row] {
        var out: [Row] = []
        let provider = selection.provider
        for candidate in selection.eligibleCandidates {
            var detail = compactGaugeText(candidate.gauges)
            detail += " · " + verdictText(candidate.verdict, kind: candidate.verdictKind, at: candidate.verdictAt, now: now)
            if let position = candidate.queuePosition { detail += " · " + "selector.queued_position".localized(with: position) }
            out.append(Row(kind: .action, title: candidate.name, detail: detail,
                           glyph: glyph(for: candidate.readiness), glyphTint: tint(for: candidate.readiness),
                           enabled: !switching, action: .switchTo(candidate.id, provider),
                           alternateTitle: "selector.queue_alternate".localized(with: candidate.name),
                           alternateAction: .queueNext(candidate.id)))
        }
        let blocked = selection.blockedCandidates
        if !out.isEmpty, !blocked.isEmpty { out.append(.separator) }
        for candidate in blocked {
            let reason: String
            var enabled = false
            var action: Action? = nil
            switch candidate.status {
            case .eligible:
                continue
            case .blocked(let readiness):
                switch readiness {
                case .dead:
                    reason = "selector.login_dead".localized
                    enabled = !switching
                    action = .repairDead(candidate.id, provider)
                case .suspected:
                    reason = "selector.suspected".localized
                case .sessionHit, .sessionHitLight, .weeklyHit, .weeklyHitSoon:
                    reason = exhaustedReason(candidate, now: now)
                default:
                    reason = DashboardFormatting.chip(.unmeasured, now: now)
                }
            case .duplicateOfOwner(let ownerName):
                reason = "selector.same_account".localized(with: ownerName)
                    + (candidate.needsRelogin ? " · " + "selector.relogin_needed".localized : "")
            case .excluded(let why):
                reason = why == .freePlan ? "selector.excluded_free".localized : "selector.excluded_toggle".localized
            }
            out.append(Row(kind: .action, title: candidate.name, detail: reason,
                           glyph: glyph(for: candidate.readiness), glyphTint: tint(for: candidate.readiness),
                           enabled: enabled, action: action))
        }
        return out
    }

    private static func exhaustedReason(_ candidate: CandidateRow, now: Date) -> String {
        if let session = candidate.gauges.first(where: { $0.kind == .session }), session.percentage >= session.threshold,
           let reset = session.resetAt, reset > now {
            return "selector.session_exhausted".localized(with: reset.timeRemainingString(from: now))
        }
        if let fable = candidate.gauges.first(where: { $0.kind == .fable }), fable.percentage >= fable.threshold {
            return "selector.fable_maxed".localized
        }
        if let weekly = candidate.gauges.first(where: { $0.kind == .weekly }), let reset = weekly.resetAt, reset > now {
            return "selector.weekly_maxed".localized(with: reset.timeRemainingString(from: now))
        }
        return "selector.exhausted".localized
    }

    // MARK: - Pieces

    static func gaugeText(_ gauges: [WindowGauge]) -> String {
        gauges.map { gauge in
            let letter: String
            switch gauge.kind {
            case .session: letter = "S"
            case .weekly: letter = "W"
            case .fable: letter = "F"
            }
            return "\(letter) \(Int(gauge.percentage.rounded())) %"
        }.joined(separator: " · ")
    }

    /// "S 78 · W 16 · F 16" — the menu's stats without the percent signs (S1).
    /// The resets row: the sweep's count, then the cached detail's expiry with
    /// its "as of" time when the owner has opened the account view once (S2).
    static func resetsRowTitle(count: Int, detail: OwnerRow.ResetsDetail?) -> String {
        let base = "selector.resets_available".localized(with: count)
        guard let detail else { return base }
        let asOf = Self.timeFormatter.string(from: detail.fetchedAt)
        if let expiry = detail.soonestExpiry {
            return base + " · " + "selector.resets_expires".localized(with: Self.expiryFormatter.string(from: expiry), asOf)
        }
        return base + " · " + "selector.resets_never_expires".localized(with: asOf)
    }

    static let expiryFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    static func compactGaugeText(_ gauges: [WindowGauge]) -> String {
        gauges.map { gauge in
            let letter: String
            switch gauge.kind {
            case .session: letter = "S"
            case .weekly: letter = "W"
            case .fable: letter = "F"
            }
            return "\(letter) \(Int(gauge.percentage.rounded()))"
        }.joined(separator: " · ")
    }

    /// "✓ verified 12 m ago" / "? unverified (expiry only)" / "× login dead" —
    /// plain words (S4); the kind survives only where it changes the meaning.
    static func verdictText(_ verdict: NextCandidate.Verdict, kind: PreflightVerdict.Kind?, at: Date?, now: Date) -> String {
        switch verdict {
        case .verified:
            return "✓ " + "selector.verified".localized + (at.map { " " + DashboardFormatting.age($0, now: now) } ?? "")
        case .unverified:
            return "? " + (kind == .expiryOnly ? "selector.unverified_expiry_only".localized : "selector.verdict_unverified".localized)
        case .dead:
            return "× " + "selector.verdict_dead".localized
        }
    }

    static func glyph(for readiness: AccountReadiness) -> String {
        FleetCounts.stripGlyphs.first { $0.0 == readiness }?.1 ?? "○"
    }

    /// Colour roles from the shared legend (G1): dead = blocking red, near limit
    /// and exhausted = caution amber, suspected = purple, ready = green, the
    /// rest informational gray.
    static func tint(for readiness: AccountReadiness) -> Tint {
        switch readiness.role {
        case .ready, .readyLight: return .green
        case .caution, .cautionLight: return .orange
        case .blocking, .blockingLight: return .red
        case .suspected: return .purple
        case .informational, .action, .active: return .secondary
        }
    }

    static func tint(for verdict: NextCandidate.Verdict) -> Tint {
        switch verdict {
        case .verified: return .green
        case .unverified: return .secondary
        case .dead: return .red
        }
    }

    static func verdictKindText(_ kind: PreflightVerdict.Kind?) -> String {
        switch kind {
        case .probed: return "selector.verdict_probed".localized
        case .refreshed: return "selector.verdict_refreshed".localized
        case .ownsLogin: return "selector.verdict_owns_login".localized
        case .switched: return "selector.verdict_switched".localized
        case .expiryOnly: return "selector.verdict_expiry_only".localized
        case nil: return "selector.verdict_unverified".localized
        }
    }

    // MARK: - Badge and tooltip (frame 0)

    static func badge(selections: [ProviderActiveSelection], preferencesDegraded: Bool) -> Badge? {
        if selections.contains(where: { $0.alert == .noCandidate || $0.owner?.readiness == .dead }) { return .red }
        if selections.contains(where: { $0.owner?.suspected != nil }) { return .purple }
        if preferencesDegraded { return .amber }
        return nil
    }

    /// "Active: Claude Atlas 78 % · Codex Marlin 95 % · Grok 12 % — 23 profiles / 22 accounts · 3 dead · 2 duplicates",
    /// prefixed with the badge's meaning when one is shown (I2).
    static func tooltip(selections: [ProviderActiveSelection], badge: Badge? = nil) -> String {
        let prefix: String
        switch badge {
        case .red: prefix = "selector.badge_red".localized + " — "
        case .purple: prefix = "selector.badge_purple".localized + " — "
        case .amber: prefix = "selector.badge_amber".localized + " — "
        case nil: prefix = ""
        }
        return prefix + summaryTooltip(selections: selections) + "\n" + DesignLegend.line
    }

    private static func summaryTooltip(selections: [ProviderActiveSelection]) -> String {
        let owners = selections.map { selection -> String in
            let name = ActiveVocabulary.providerName(selection.provider)
            guard let owner = selection.owner else { return "\(name) —" }
            let pct = owner.keyedPercentage.map { " \(Int($0.rounded())) %" } ?? ""
            return "\(name) \(owner.name)\(pct)"
        }
        let profiles = selections.reduce(0) { $0 + $1.counts.profiles }
        let accounts = selections.reduce(0) { $0 + $1.counts.distinctAccounts }
        let dead = selections.reduce(0) { $0 + $1.counts.count(.dead) }
        let duplicates = selections.reduce(0) { $0 + $1.counts.duplicateProfiles }
        var summary = "selector.tooltip_counts".localized(with: profiles, accounts)
        if dead > 0 { summary += " · " + "counts.dead".localized(with: dead) }
        if duplicates > 0 { summary += " · " + "counts.duplicates".localized(with: duplicates) }
        return "selector.tooltip".localized(with: owners.joined(separator: " · "), summary)
    }

    // MARK: - Confirmation (frame 9)

    struct Confirmation: Hashable {
        var title: String
        var body: String
        /// True when the candidate's login is unverified / the switch may be refused.
        var risky: Bool
        /// False for a dead login: the switch button is disabled and reads
        /// "Log in first"; Cancel stays the default either way.
        var switchAllowed: Bool
        var confirmButton: String { switchAllowed ? "selector.confirm_switch".localized : "selector.confirm_login_first".localized }
        var cancelButton: String { "common.cancel".localized }
    }

    /// "From Atlas (78 % session) to Cedar (12 % session · resets in 4 h)." then
    /// the cost sentence, then the candidate's evidence — both sides named.
    static func confirmation(provider: Profile.ProviderKind, candidate: CandidateRow, owner: OwnerRow?, now: Date) -> Confirmation {
        let cli = ActiveVocabulary.cliName(provider)
        var body = "selector.confirm_from_to".localized(
            with: owner?.name ?? "selector.nobody".localized, owner.map { sideText($0.gauges, now: now) } ?? "—",
            candidate.name, sideText(candidate.gauges, now: now))
        body += "\n" + "selector.confirm_cost".localized(with: cli, candidate.name)
        var facts = gaugeText(candidate.gauges)
        switch candidate.verdict {
        case .verified:
            facts += " — " + "selector.confirm_verified".localized(with: candidate.verdictAt.map { DashboardFormatting.age($0, now: now) } ?? "")
        case .unverified:
            facts += " — " + "selector.confirm_unverified".localized
        case .dead:
            facts += " — " + "selector.confirm_dead".localized
        }
        body += "\n" + candidate.name + ": " + facts + "."
        if let owner {
            if let session = owner.gauges.first(where: { $0.kind == .session }), let reset = session.resetAt, reset > now {
                body += "\n" + "selector.confirm_owner_keeps".localized(
                    with: owner.name, max(0, Int((100 - session.percentage).rounded())), reset.timeRemainingString(from: now))
            } else if let weekly = owner.gauges.first(where: { $0.kind == .weekly }) {
                body += "\n" + "selector.confirm_owner_weekly".localized(with: owner.name, Int(weekly.percentage.rounded()))
            }
        }
        return Confirmation(
            title: "selector.confirm_title".localized(with: cli, candidate.name),
            body: body,
            risky: candidate.verdict != .verified,
            switchAllowed: candidate.readiness != .dead
        )
    }

    /// "78 % session" / "12 % session · resets in 4 h" / "95 % weekly".
    private static func sideText(_ gauges: [WindowGauge], now: Date) -> String {
        guard let keyed = gauges.first(where: { $0.kind == .session }) ?? gauges.first(where: { $0.kind == .weekly }) else {
            return "selector.not_measured".localized
        }
        let window = keyed.kind == .session ? "selector.window_session".localized : "selector.window_weekly".localized
        var text = "\(Int(keyed.percentage.rounded())) % \(window)"
        if let reset = keyed.resetAt, reset > now { text += " · " + "accounts.resets_in".localized(with: reset.timeRemainingString(from: now)) }
        return text
    }
}
