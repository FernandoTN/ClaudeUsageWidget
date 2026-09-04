//
//  FleetSummary.swift
//  Claude Usage
//
//  The pure model behind the fleet-summary menu-bar layouts
//  (`MenuBarLayout.fleetDots` / `.fleetCounts`) and the dashboard:
//  one readiness state per account, one summary per provider group.
//  Everything here is `nonisolated`, `now`-injectable and free of AppKit so
//  the rules are unit-testable (see FleetSummaryTests).
//
//  Design brief: docs/specs/menubar-redesign.md §2, consult log §6.
//

import Foundation

// MARK: - Readiness

/// How usable an account is RIGHT NOW, as the bar's dots/counts and the
/// dashboard's state chips render it. One dot, one precedence:
/// dead → excluded → exhausted → suspected → unknown → low → ready.
/// Staleness is NOT a state (a stale "maxed" is still a fact until its
/// window rolls over) — it is an orthogonal flag rendered as dimming.
enum AccountReadiness: Int, Hashable, CaseIterable, Comparable {
    /// BRIGHT GREEN — session available; weekly AND Fable both have more
    /// than half left. The auto-switch would accept it.
    case ready
    /// LIGHT GREEN — session available; weekly or Fable has half or less left.
    case readyLight
    /// Never fetched — no reading at all.
    case unknown
    /// Inferred (unverified) throttle stamp live — data quality, not a fact.
    case suspected
    /// BRIGHT ORANGE — the 5-hour session limit is hit (server-affirmed);
    /// weekly and Fable still have more than half left.
    case sessionHit
    /// FADED ORANGE — session hit AND weekly or Fable has half or less left.
    case sessionHitLight
    /// BRIGHT RED — weekly or Fable limit hit, and the reset is within a
    /// day (bright = relief is closer, the owner's rule for every hue).
    case weeklyHitSoon
    /// LIGHT RED — weekly or Fable limit hit; the reset is more than a day
    /// away. Blocked regardless of the session window.
    case weeklyHit
    /// The auto-switch will never pick it: per-profile toggle off, or a
    /// free-plan CLI login. Not a capacity statement.
    case excluded
    /// The provider login is dead (flagged, or expired with no refresh
    /// token), or the profile carries no usable credentials at all.
    case dead

    nonisolated static func < (lhs: AccountReadiness, rhs: AccountReadiness) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// True for the states the auto-switch would refuse as a target.
    var blocksSwitchTarget: Bool {
        switch self {
        case .ready, .readyLight, .unknown: return false
        case .suspected, .sessionHit, .sessionHitLight, .weeklyHitSoon, .weeklyHit, .excluded, .dead: return true
        }
    }

    /// A measured limit — session, weekly or Fable — is hit.
    var isAtLimit: Bool { isSessionHit || isWeeklyHit }
    var isSessionHit: Bool { self == .sessionHit || self == .sessionHitLight }
    var isWeeklyHit: Bool { self == .weeklyHit || self == .weeklyHitSoon }
    var hasHeadroom: Bool { self == .ready || self == .readyLight }
}

/// What each dot showed last time, so a dot changes colour only on
/// server-affirmed evidence (owner round 2026-09-04, B3: dots flipped
/// between sweeps). A change is adopted when the account was measured
/// again (any provenance), its login died or revived, a server-affirmed
/// limit stamp appeared or expired, a window reset passed, or the account
/// was excluded / included; an INFERRED throttle (a suspicion, not a
/// measurement) has to persist for `suspectedDebounce` before it turns a
/// dot purple, and everything else — the mere passage of time — keeps the
/// dot as it was. Every adoption returns a reason for the log.
struct FleetDotMemory {
    nonisolated static let suspectedDebounce: TimeInterval = 60

    struct Shown: Hashable {
        var readiness: AccountReadiness
        var measuredAt: Date?
        var sessionResetAt: Date?
        var weeklyResetAt: Date?
        var dead: Bool
        var excluded: Bool
        var affirmedStamp: Bool
    }

    struct Change: Hashable {
        var from: AccountReadiness?
        var to: AccountReadiness
        var reason: String
    }

    private(set) var shown: [UUID: Shown] = [:]
    private var suspectedSince: [UUID: Date] = [:]

    nonisolated init() {}

    /// The readiness to draw for `id`, and the change record when it changed.
    nonisolated mutating func adopt(
        id: UUID,
        candidate: AccountReadiness,
        usage: ClaudeUsage?,
        isLoginDead: Bool,
        isExcluded: Bool,
        now: Date
    ) -> (readiness: AccountReadiness, change: Change?) {
        let affirmedStamp = (usage?.rateLimitedUntil.map { $0 > now } ?? false) && usage?.rateLimitedInferred != true
        let next = Shown(
            readiness: candidate, measuredAt: usage?.lastUpdated,
            sessionResetAt: usage?.sessionResetTime, weeklyResetAt: usage?.weeklyResetTime,
            dead: isLoginDead, excluded: isExcluded, affirmedStamp: affirmedStamp
        )
        guard let previous = shown[id] else {
            shown[id] = next
            return (candidate, Change(from: nil, to: candidate, reason: "first paint"))
        }
        if candidate == previous.readiness {
            shown[id] = next
            suspectedSince[id] = nil
            return (candidate, nil)
        }
        var reason: String?
        if previous.dead != isLoginDead {
            reason = isLoginDead ? "login dead" : "login revived"
        } else if previous.excluded != isExcluded {
            reason = isExcluded ? "excluded from auto-switch" : "included in auto-switch"
        } else if previous.affirmedStamp != affirmedStamp {
            reason = affirmedStamp ? "server-affirmed limit stamp" : "limit stamp expired"
        } else if let measuredAt = usage?.lastUpdated, measuredAt != previous.measuredAt {
            let source: String
            switch usage?.provenance {
            case .headerRescue?: source = "API headers"
            case .cliCache?: source = "CLI cache"
            default: source = "own endpoint"
            }
            reason = "new measurement (\(source))"
        } else if let reset = previous.sessionResetAt, reset <= now, (usage?.sessionResetTime ?? reset) != reset || !candidate.isSessionHit {
            reason = "session window reset"
        } else if let reset = previous.weeklyResetAt, reset <= now {
            reason = "weekly window reset"
        } else if candidate == .suspected {
            let since = suspectedSince[id] ?? now
            suspectedSince[id] = since
            if now.timeIntervalSince(since) >= Self.suspectedDebounce {
                reason = "inferred throttle persisted \(Int(now.timeIntervalSince(since))) s"
            }
        }
        guard let reason else {
            // Nothing server-affirmed changed: keep what the dot showed.
            return (previous.readiness, nil)
        }
        shown[id] = next
        suspectedSince[id] = nil
        return (candidate, Change(from: previous.readiness, to: candidate, reason: reason))
    }

    nonisolated mutating func forget(except keep: Set<UUID>) {
        shown = shown.filter { keep.contains($0.key) }
        suspectedSince = suspectedSince.filter { keep.contains($0.key) }
    }
}

/// The thresholds readiness is judged against. `session`/`weekly` are the
/// auto-switch's own switch thresholds, so "ready" on the bar means exactly
/// "the auto-switch would accept this account".
struct ReadinessThresholds: Hashable {
    var session: Double
    var weekly: Double
    /// Owner scheme 2026-09-04: a hit weekly / Fable window whose reset is
    /// within this reads BRIGHT red (relief is close); further away, light.
    var weeklyResetSoon: TimeInterval = 24 * 3600
    /// "More than half left": the cut-off between the bright and light
    /// shades of green (session available) and orange (session hit).
    var comfortableRemaining: Double = 50
    var staleAfter: TimeInterval = 180

    nonisolated init(
        session: Double,
        weekly: Double,
        weeklyResetSoon: TimeInterval = 24 * 3600,
        comfortableRemaining: Double = 50,
        staleAfter: TimeInterval = 180
    ) {
        self.session = session
        self.weekly = weekly
        self.weeklyResetSoon = weeklyResetSoon
        self.comfortableRemaining = comfortableRemaining
        self.staleAfter = staleAfter
    }
}

extension AccountReadiness {
    /// Classifies one account (first match wins, see the enum doc).
    nonisolated static func classify(
        usage: ClaudeUsage?,
        isLoginDead: Bool,
        isExcluded: Bool,
        thresholds: ReadinessThresholds,
        now: Date
    ) -> AccountReadiness {
        if isLoginDead { return .dead }
        if isExcluded { return .excluded }
        guard let usage else { return .unknown }

        let stampLive = usage.rateLimitedUntil.map { $0 > now } ?? false
        let affirmedStamp = stampLive && usage.rateLimitedInferred != true

        // A weekly or Fable limit hit blocks the account regardless of the
        // session window; the shade says how far the reset is.
        var hitResets: [Date] = []
        if usage.weeklyResetTime >= now, usage.weeklyPercentage >= thresholds.weekly {
            hitResets.append(usage.weeklyResetTime)
        }
        if let fable = usage.fableWeeklyPercentage,
           usage.fableWeeklyResetTime.map({ $0 >= now }) ?? true,
           fable >= thresholds.weekly {
            hitResets.append(usage.fableWeeklyResetTime ?? .distantFuture)
        }
        if let soonest = hitResets.min() {
            return soonest.timeIntervalSince(now) <= thresholds.weeklyResetSoon ? .weeklyHitSoon : .weeklyHit
        }

        // How much of the weekly windows is left decides the shade.
        let weeklyLeft = usage.weeklyResetTime >= now ? 100 - usage.weeklyPercentage : 100
        let fableLeft = usage.fableWeeklyPercentage.map {
            (usage.fableWeeklyResetTime.map { $0 >= now } ?? true) ? 100 - $0 : 100
        } ?? 100
        let comfortable = min(weeklyLeft, fableLeft) > thresholds.comfortableRemaining

        let sessionNow = usage.sessionResetTime > now ? usage.sessionPercentage : 0
        let sessionHit = affirmedStamp || (usage.providesSessionWindow && sessionNow >= thresholds.session)
        if sessionHit { return comfortable ? .sessionHit : .sessionHitLight }
        if stampLive, usage.rateLimitedInferred == true { return .suspected }
        return comfortable ? .ready : .readyLight
    }

    /// True when the last MEASURED reading is older than `thresholds.staleAfter`.
    nonisolated static func isStale(_ usage: ClaudeUsage?, thresholds: ReadinessThresholds, now: Date) -> Bool {
        guard let usage else { return false }
        return now.timeIntervalSince(usage.lastUpdated) > thresholds.staleAfter
    }
}

// MARK: - Next candidate

/// What the last preflight (or the auto-switch walk) learned about a
/// candidate's login. Published by `MenuBarManager`; consumed by the bar's
/// affix and the dashboard.
struct PreflightVerdict: Hashable {
    /// How the verdict was reached — only a PROVING kind earns a ✓.
    enum Kind: Hashable {
        /// The account's own usage endpoint answered 200 / 401 (Codex probe).
        case probed
        /// A refresh-token redemption succeeded (fresh access token banked).
        case refreshed
        /// The login is the provider's shared CLI login, kept fresh by the CLI.
        case ownsLogin
        /// A real switch onto this login succeeded / was refused.
        case switched
        /// Only the stored token's expiry was checked, or the probe was
        /// inconclusive (429/5xx/transport) — says nothing about an
        /// externally revoked login.
        case expiryOnly
    }

    var isLive: Bool
    var at: Date
    var kind: Kind

    /// A live verdict of a kind that actually proved the login.
    var provesLive: Bool {
        guard isLive else { return false }
        switch kind {
        case .probed, .refreshed, .ownsLogin, .switched: return true
        case .expiryOnly: return false
        }
    }
}

/// The bar's answer to "where is the switch going, and is that account known
/// good": the candidate the auto-switch would pick next for a provider.
struct NextCandidate: Hashable {
    enum Verdict: Hashable {
        /// Preflighted live recently by a proving check.
        case verified
        /// Never preflighted, expiry-only, inconclusive, or the last verdict
        /// is too old.
        case unverified
        /// Login known dead (flag, or a recent failed preflight / switch).
        case dead

        /// Suffix glyph on the bar.
        var glyph: String {
            switch self {
            case .verified: return "✓"
            case .unverified: return "?"
            case .dead: return "×"
            }
        }
    }

    var id: UUID
    /// The candidate's menu-bar display name (rendered as its first 3 chars).
    var label: String
    /// True when the candidate comes from the user's switch queue rather
    /// than the soonest-weekly-reset ranking.
    var queued: Bool
    /// True when the queue is non-empty but its head is not executable
    /// right now (blocked), so this candidate is the ranked fallback.
    var queueHeadBlocked: Bool
    /// The candidate's own readiness — tints the label (quota evidence),
    /// independently of the login verdict (the suffix).
    var readiness: AccountReadiness
    var verdict: Verdict

    /// Maps a raw preflight verdict onto the bar's three states. A dead
    /// readiness wins outright; a live verdict counts only while fresh AND
    /// only when the check proved something (expiry-only never earns a ✓).
    nonisolated static func verdict(
        readiness: AccountReadiness,
        preflight: PreflightVerdict?,
        now: Date,
        maxAge: TimeInterval = 1800
    ) -> Verdict {
        if readiness == .dead { return .dead }
        guard let preflight, now.timeIntervalSince(preflight.at) <= maxAge else { return .unverified }
        if !preflight.isLive { return .dead }
        return preflight.provesLive ? .verified : .unverified
    }
}

// MARK: - Provider summary

/// One alert per provider, highest precedence first. The bar draws none of
/// these (the affix already says `→—`, dead logins are fleet marks, and
/// cfprefsd has its banner); the dashboard names them.
enum FleetAlert: Hashable, Comparable {
    /// The active account is armed (near its threshold or a hand-off is
    /// queued) and no live candidate exists.
    case noCandidate
    /// At least one dead login in this provider group.
    case deadLogins
    /// cfprefsd degraded — every value on screen is cached.
    case degraded

    nonisolated static func < (lhs: FleetAlert, rhs: FleetAlert) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .noCandidate: return 0
        case .deadLogins: return 1
        case .degraded: return 2
        }
    }
}

/// One member of a provider group as the fleet block renders it.
struct FleetMember: Hashable {
    var id: UUID
    var readiness: AccountReadiness
    /// Reading older than the staleness threshold → drawn dimmed.
    var isStale: Bool = false
}

/// Everything one provider's summary tile is a pure function of.
struct ProviderSummary: Hashable {
    /// Keyed-window percentage at which the tile starts showing the active
    /// account's digits and the next candidate — the preflight's own 75 %
    /// milestone.
    nonisolated static let armThreshold: Double = 75
    /// Fleet dots hold at most this many OTHER accounts (2 rows × 10). Beyond
    /// that the last slot becomes a `+N` overflow mark — the representation
    /// never flips wholesale at account 21.
    nonisolated static let maxDotMembers = 20
    /// The active account's reading counts as stale after this long.
    nonisolated static let activeStaleAfter: TimeInterval = 600

    var provider: Profile.ProviderKind
    /// The provider-active account (owner of the shared CLI login), or nil
    /// when the provider has no active login right now.
    var activeId: UUID?
    var activeReadiness: AccountReadiness?
    /// The active account's keyed-window percentage, rounded, while armed.
    var activeDigits: Int?
    /// True when the active account's last measurement is older than
    /// `activeStaleAfter` — rendered as dimmed bars, never as a dot.
    var activeIsStale: Bool
    /// A profile switch is rewriting the shared logins right now.
    var isSwitching: Bool
    /// The OTHER accounts of the provider, left-to-right as painted.
    var members: [FleetMember]
    /// True while the digits + next-candidate affix are shown.
    var armed: Bool
    var next: NextCandidate?
    var alert: FleetAlert?

    /// How many members are in each readiness state (zero-count states omitted).
    var counts: [AccountReadiness: Int] {
        members.reduce(into: [:]) { $0[$1.readiness, default: 0] += 1 }
    }

    /// The label-row affix: `→XXX` towards the candidate, `→—` armed with
    /// nobody to go to, `⇄` mid-switch; nil while idle. The queue state is
    /// carried by the ARROW's colour (design round 1, B4: the `Q` letter was
    /// cryptic at 22 pt) — accent when queued, red when the queue head is
    /// blocked and this is the ranked fallback. Digits and the verdict glyph
    /// are separate so the renderer can tint each part by its own evidence.
    var affix: String? {
        if isSwitching { return "⇄" }
        guard armed else { return nil }
        guard let next else { return "→—" }
        return DesignGlyph.next + String(next.label.prefix(3))
    }

    /// The verdict glyph after the affix: ✓ proved live, × dead; nothing
    /// while unverified (round 1, B4: `?` read as an error, and the absence
    /// of the check is the information).
    var verdictGlyph: String? {
        guard armed, !isSwitching, let next else { return nil }
        switch next.verdict {
        case .verified: return DesignGlyph.verified
        case .dead: return DesignGlyph.dead
        case .unverified: return nil
        }
    }

    /// Dots the fleet block draws and the `+N` it prepends for the rest.
    /// The RIGHTMOST members (soonest weekly reset — "next to burn") are the
    /// ones kept; the overflow mark takes two reserved columns on the left.
    nonisolated func dotMembers() -> (shown: [FleetMember], overflow: Int) {
        guard members.count > Self.maxDotMembers else { return (members, 0) }
        let shown = Array(members.suffix(Self.maxDotMembers - 2))
        return (shown, members.count - shown.count)
    }

    /// The percentage the arming rule and the digits key off — the DISPLAY
    /// seam, never `effectiveSessionPercentage`: that property reports 100
    /// while any stamp is live, inferred ones included, and the auto-switch
    /// strips inferred stamps before deciding. Digits of 100 on a suspected
    /// account would be a synthetic 100 announcing a switch the walk will not
    /// make. Weekly-only providers key off their weekly window.
    nonisolated static func keyedDisplayPercentage(_ usage: ClaudeUsage) -> Double {
        guard usage.providesSessionWindow else { return usage.weeklyPercentage }
        return max(usage.displaySessionPercentage, usage.weeklyPercentage)
    }

    /// Builds one provider's summary.
    ///
    /// - Parameters:
    ///   - orderedMembers: every account of the provider (selected or not —
    ///     the switch walk considers them all), left-to-right as the bar
    ///     paints them (soonest weekly reset rightmost).
    ///   - readiness / stale: per-account classification (already computed).
    ///   - keyedPercentage: the active account's window percentage the
    ///     preflight milestones key off (`MenuBarManager.preflightMilestonePercentage`).
    ///   - next: the predicted next candidate, nil when none has headroom.
    ///   - activeLastMeasured: `lastUpdated` of the active account's usage.
    nonisolated static func build(
        provider: Profile.ProviderKind,
        orderedMembers: [UUID],
        activeId: UUID?,
        readiness: [UUID: AccountReadiness],
        stale: Set<UUID> = [],
        keyedPercentage: Double?,
        next: NextCandidate?,
        isSwitching: Bool = false,
        preferencesDegraded: Bool,
        activeLastMeasured: Date?,
        now: Date
    ) -> ProviderSummary {
        let others = orderedMembers
            .filter { $0 != activeId }
            .map { FleetMember(id: $0, readiness: readiness[$0] ?? .unknown, isStale: stale.contains($0)) }
        // Armed = the affix row is shown: the active account is past the
        // preflight milestone, a hand-off is queued, or — regardless of usage
        // — there is nobody to go to. "2 of 3 dead, no candidate" is the only
        // fact a group like that has; hiding it until 75 % would be silence.
        let armed = (keyedPercentage ?? 0) >= armThreshold
            || next?.queued == true
            || (next == nil && !others.isEmpty)
        let activeReadiness = activeId.flatMap { readiness[$0] }

        var alerts: [FleetAlert] = []
        if armed, next == nil || next?.verdict == .dead { alerts.append(.noCandidate) }
        if others.contains(where: { $0.readiness == .dead }) || activeReadiness == .dead {
            alerts.append(.deadLogins)
        }
        if preferencesDegraded { alerts.append(.degraded) }

        let activeIsStale = activeId != nil
            && now.timeIntervalSince(activeLastMeasured ?? .distantPast) > activeStaleAfter

        return ProviderSummary(
            provider: provider,
            activeId: activeId,
            activeReadiness: activeReadiness,
            activeDigits: armed ? keyedPercentage.map { Int($0.rounded()) } : nil,
            activeIsStale: activeIsStale,
            isSwitching: isSwitching,
            members: others,
            armed: armed,
            next: next,
            alert: alerts.min()
        )
    }
}

// MARK: - Geometry

/// Pixel budget of the summary tile, shared by the renderer and the tests.
/// Every width here is FIXED for a given roster and layout: arming, digits
/// ticking and verdicts flipping repaint pixels but never change the status
/// item's length (a length change relayouts the whole menu bar). Text
/// widths were MEASURED with the fonts the renderer draws with (SF, 7 pt
/// semibold monospaced-digit for the candidate row, 6 pt semibold for the
/// counts and the mark; `FleetSummaryTests.testReservedWidthsCoverTheRealFonts`
/// re-measures them on every run).
enum FleetBlockGeometry {
    /// 5 pt dots at a 7 pt pitch (owner round 2026-09-04, B1: 4 pt dots at
    /// 6 pt were illegible for 18 accounts); two rows of seven fill the
    /// 22 pt bar with the candidate row underneath (2 × 7 + 7 = 21).
    nonisolated static let dotDiameter: CGFloat = 5
    nonisolated static let dotPitch: CGFloat = 7
    nonisolated static let dotsPerRow = 10
    nonisolated static let rowPitch: CGFloat = 7
    /// Rosters of this many other accounts or more use two rows.
    nonisolated static let twoRowsFrom = 4
    /// Provider mark column at the block's left edge: the mark (Cl / Cx / Gk
    /// at 6 pt; `Gk` measures 8.5 pt) over the provider's TOTAL account
    /// count, so "5 accounts, 4 dots" reads as "the fifth is the tile".
    nonisolated static let markWidth: CGFloat = 10
    /// Gap between the active tile and the fleet block.
    nonisolated static let gap: CGFloat = 3
    /// Breathing room between the candidate row's segments (digits, arrow +
    /// name, verdict glyph): the ✓ used to touch the name (round 1, B2).
    nonisolated static let candidateGap: CGFloat = 1.5
    /// Gap between the `+N` overflow mark and the first dot column (B3).
    nonisolated static let overflowGap: CGFloat = 2
    /// Counts row: `●99 ◐99 ▲99 ×99` in one row at 6 pt semibold — 65.4 pt of
    /// glyphs plus three 2 pt gaps, measured.
    nonisolated static let countsWidth: CGFloat = 72
    /// The counts row for a roster under ten: `●9 ◐9 ▲9 ×9` plus three 2 pt
    /// gaps, measured.
    nonisolated static let countsWidthSingleDigit: CGFloat = 50
    nonisolated static func countsWidth(memberCount: Int) -> CGFloat {
        memberCount < 10 ? countsWidthSingleDigit : countsWidth
    }
    /// The FULL candidate row (`99 →WWW ✓` at its widest, 7 pt semibold with
    /// the two gaps: measured by `testReservedWidthsCoverTheRealFonts`). It
    /// is NOT a floor on the block's width any more (owner, 2026-09-04: a
    /// five-account Codex block padded to it looked as wide as Claude's);
    /// the block is exactly as wide as its dots or counts, and the row is
    /// drawn only when it fits — compressed to `→WWW` when only that fits,
    /// left to the ⇄ menu otherwise. Widths still never move with arming.
    nonisolated static let affixWidth: CGFloat = 52
    /// The compressed candidate row, `→WWW` at 7 pt semibold, measured.
    nonisolated static let affixCompressedWidth: CGFloat = 30
    /// Columns reserved at the LEFT of the matrix for the `+N` mark when the
    /// roster is larger than the grid (`+17` at 6 pt is 11 pt wide).
    nonisolated static let overflowColumns = 2

    /// Columns × rows for `count` dots: one row up to three accounts, else
    /// two rows balanced (4 → 2 × 2, 18 → 9 × 2), capped at `dotsPerRow`
    /// columns. The renderer fills COLUMN-major from the RIGHT edge, so the
    /// rightmost column always holds the soonest weekly resets — "rightmost
    /// = next to burn" survives the wrap.
    nonisolated static func dotGrid(count: Int) -> (columns: Int, rows: Int) {
        guard count > 0 else { return (0, 0) }
        let rows = count >= twoRowsFrom ? 2 : 1
        return ((count + rows - 1) / rows, rows)
    }

    /// Where dot `index` of `count` sits: ROW-major from the RIGHT edge
    /// (owner, 2026-09-04): index 0 is the soonest weekly reset, top row,
    /// rightmost; the top row runs right→left, then the bottom row. Column-
    /// major put the second-soonest UNDER the soonest, so a row read left→
    /// right skipped every other account.
    nonisolated static func dotPosition(index: Int, count: Int) -> (column: Int, row: Int) {
        let grid = dotGrid(count: count)
        guard grid.columns > 0 else { return (0, 0) }
        return (index % grid.columns, index / grid.columns)
    }

    /// Dots actually drawn for a roster of `memberCount` other accounts.
    nonisolated static func shownDotCount(memberCount: Int) -> Int {
        memberCount > ProviderSummary.maxDotMembers
            ? ProviderSummary.maxDotMembers - overflowColumns
            : memberCount
    }

    /// Width of the dot matrix for a roster of `memberCount` other accounts,
    /// INCLUDING the two `+N` columns when the roster overflows the grid.
    nonisolated static func dotMatrixWidth(memberCount: Int) -> CGFloat {
        guard memberCount > 0 else { return 0 }
        let shown = shownDotCount(memberCount: memberCount)
        var columns = dotGrid(count: shown).columns
        var extra: CGFloat = 0
        if memberCount > ProviderSummary.maxDotMembers {
            columns += overflowColumns
            extra = overflowGap
        }
        return CGFloat(columns - 1) * dotPitch + dotDiameter + extra
    }

    /// Width of the whole fleet block (mark + max(dots|counts, candidate
    /// row)) for `memberCount` other accounts in `layout`; zero when the
    /// provider has a single account (nothing to summarise, no candidate to
    /// show).
    nonisolated static func fleetWidth(memberCount: Int, layout: MenuBarLayout) -> CGFloat {
        guard memberCount > 0 else { return 0 }
        let matrix: CGFloat
        switch layout {
        case .everyAccount: return 0
        case .fleetCounts: matrix = countsWidth(memberCount: memberCount)
        case .fleetDots: matrix = dotMatrixWidth(memberCount: memberCount)
        }
        return markWidth + matrix
    }

    /// Height of the fleet block beside an active tile of `activeHeight`:
    /// always the full 22 pt bar height — the mark column carries the
    /// account count under the mark (two 7 pt rows) and two dot rows plus
    /// the candidate row need 21 pt.
    nonisolated static func blockHeight(activeHeight: CGFloat, memberCount: Int, layout: MenuBarLayout) -> CGFloat {
        max(activeHeight, 22)
    }

    /// Total summary-tile width: active tile + gap + fleet block.
    nonisolated static func tileWidth(activeWidth: CGFloat, memberCount: Int, layout: MenuBarLayout) -> CGFloat {
        let fleet = fleetWidth(memberCount: memberCount, layout: layout)
        return fleet > 0 ? activeWidth + gap + fleet : activeWidth
    }
}

// MARK: - Paint-time context

/// The auto-switch's prediction for one provider, resolved by `MenuBarManager`.
struct PredictedCandidate: Hashable {
    var id: UUID
    /// The candidate's menu-bar display name (the renderer truncates to 3).
    var label: String
    var queued: Bool
    var queueHeadBlocked: Bool
}

/// What `StatusBarUIManager` needs, beyond profiles and config, to paint the
/// fleet-summary layouts. Built by `MenuBarManager` per paint; nil for the
/// per-account layout.
struct FleetSummaryContext {
    var thresholds: ReadinessThresholds
    /// Dead-login predicate (flag, or expired with no refresh token).
    var isLoginDead: (Profile) -> Bool
    /// The auto-switch's own eligibility predicate, inverted (toggle off,
    /// free plan) — so "ready" on the bar is what the walk would accept.
    var isExcluded: (Profile) -> Bool
    var nextCandidates: [Profile.ProviderKind: PredictedCandidate]
    var preflightVerdicts: [UUID: PreflightVerdict]
    var preferencesDegraded: Bool
    var isSwitching: Bool
    var now: Date
}
