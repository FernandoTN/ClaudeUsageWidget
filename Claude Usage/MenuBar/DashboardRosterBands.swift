//
//  DashboardRosterBands.swift
//  Claude Usage
//
//  The roster's three bands and the weekly countdown every row prints
//  (owner ask 2026-09-04: the three rows under a provider must be the
//  accounts coming next AND say when their weekly limit resets, so the
//  block answers "who is next, and how soon does capacity come back"). The
//  countdown reuses the ⇄ selector's vocabulary (`accounts.resets_in`) and
//  clock (`timeRemainingString`); a projected boundary wears a "~" and its
//  tooltip says so; an unreported one reads "reset unknown". Pure
//  formatting lives on `DashboardFormatting` so it is tested without AppKit.
//

import SwiftUI

extension DashboardFormatting {
    /// "W resets in 2d 1h" / "F resets in 2d 1h" (Fable is the exhausted
    /// window) / "W resets in ~2d 1h" (projected) / "W reset unknown"; the
    /// letter is the legend's, so the weekly reset on a session-exhausted
    /// row is never read as the session's. `short` drops the verb ("W in
    /// 2d 1h") for the second half of a line. Empty for a never-measured row.
    static func resetCountdown(_ reset: ResetCountdown?, now: Date = Date(), short: Bool = false) -> String {
        guard let reset else { return "" }
        let label = gaugeTitle(reset.window == .fable ? .fable : .weekly, compact: true) + " "
        // A closed Codex window: "W no window (idle)" — a fact, not a
        // missing stamp, and nothing to count down to.
        if reset.idle { return label + "dashboard.reset_idle".localized }
        guard let at = reset.resetAt else { return label + "dashboard.reset_unknown".localized }
        if at <= now { return label + "dashboard.reset_now".localized }
        let clock = (reset.projected ? "~" : "") + at.timeRemainingString(from: now)
        return label + (short ? "dashboard.reset_in_short" : "accounts.resets_in").localized(with: clock)
    }

    /// The row's third line. A session-exhausted row leads with the reset
    /// the band sorted on — "S resets in 2h 10m · W in 2 days" — so the
    /// binding window and the weekly one are both there, in that order.
    static func resetLine(_ row: RosterRow, now: Date = Date()) -> String {
        let weekly = resetCountdown(row.weeklyReset, now: now, short: row.sessionReturnsAt != nil)
        guard let session = row.sessionReturnsAt else { return weekly }
        let lead = gaugeTitle(.session, compact: true) + " "
            + (session > now ? "accounts.resets_in".localized(with: session.timeRemainingString(from: now))
                             : "dashboard.reset_now".localized)
        return weekly.isEmpty ? lead : lead + " · " + weekly
    }

    /// The tooltip for a row's third line: the binding session boundary
    /// first when there is one, then the weekly's.
    static func resetHelp(_ row: RosterRow, now: Date = Date()) -> String {
        var parts: [String] = []
        if let session = row.sessionReturnsAt {
            parts.append("dashboard.reset_help_at".localized(with: "dashboard.reset_window_session".localized,
                                                             session.resetTimeString(from: now)))
        }
        if let weekly = row.weeklyReset { parts.append(resetHelp(weekly, now: now)) }
        return parts.joined(separator: " ")
    }

    /// The tooltip: the absolute boundary, and the provenance of a projected
    /// or unknown one spelled out.
    static func resetHelp(_ reset: ResetCountdown, now: Date = Date()) -> String {
        let window = reset.window == .fable
            ? "dashboard.reset_window_fable".localized : "dashboard.reset_window_weekly".localized
        if reset.idle { return "dashboard.reset_help_idle".localized(with: window) }
        guard let at = reset.resetAt else { return "dashboard.reset_help_unknown".localized(with: window) }
        var text = "dashboard.reset_help_at".localized(with: window, at.resetTimeString(from: now))
        if reset.projected { text += " " + "dashboard.reset_help_projected".localized }
        return text
    }

    static func bandLabel(_ group: RosterGroup) -> String {
        switch group {
        case .nextUp: return "dashboard.band.next_up".localized
        case .capacityReturns: return "dashboard.band.capacity_returns".localized
        case .notSwitchable: return "dashboard.band.not_switchable".localized
        }
    }
}

/// The word and hairline that open each band of the roster, so the three
/// questions the block answers read as three blocks without a header each.
struct RosterBandLabel: View {
    let group: RosterGroup

    var body: some View {
        HStack(spacing: 6) {
            Text(DashboardFormatting.bandLabel(group))
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
                .fixedSize()
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }
}

/// A row's reset line in the row's small type, monospaced digits, the
/// absolute boundaries on hover. Emphasised (primary, medium) on an
/// exhausted row, where the reset is the fact; an unreported weekly
/// boundary is a data-quality notice and takes the caution colour, like a
/// CLI-cache reading.
struct RosterResetText: View {
    let row: RosterRow
    var emphasized = false
    var now = Date()

    var body: some View {
        Text(DashboardFormatting.resetLine(row, now: now))
            .font(.system(size: 8.5, weight: emphasized ? .medium : .regular))
            .monospacedDigit()
            .foregroundColor(row.weeklyReset?.resetAt == nil && row.weeklyReset?.idle != true
                             ? DesignRole.caution.color : (emphasized ? .primary : .secondary))
            .lineLimit(1)
            .fixedSize()
            .help(DashboardFormatting.resetHelp(row, now: now))
    }
}

// MARK: - Weekly-window priming line (docs/specs/weekly-window-priming.md)

extension DashboardFormatting {
    /// The row's fourth line on a Codex account: "primed 08:12 · resets Sep 16"
    /// (both measured — the prime's time and the reset the verifying fetch
    /// reported), "prime pending 08:15", "prime retry 08:45", "prime failed
    /// 08:12", or the exclusion word. Empty when there is nothing to say.
    static func primeLine(_ status: WeeklyPrimeStatus, now: Date = Date()) -> String {
        switch status {
        case .primed(let at, let resetsAt):
            return "prime.status_primed".localized(with: clockTime(at), resetsAt.resetTimeString(from: now))
        case .pending(let at): return "prime.status_pending".localized(with: clockTime(at))
        case .retry(let at): return "prime.status_retry".localized(with: clockTime(at))
        case .verifying(let at): return "prime.status_verifying".localized(with: clockTime(at))
        case .failed(_, let spent) where spent: return "prime.status_spent".localized
        case .failed(let at, _): return "prime.status_failed".localized(with: clockTime(at))
        case .noMovement(let at): return "prime.status_no_movement".localized(with: clockTime(at))
        case .excluded(.providerOff): return "prime.status_off".localized
        case .excluded(.neverPrime): return "prime.status_never".localized
        case .excluded(.owner): return "prime.status_owner".localized
        case .excluded(.deadLogin), .excluded(.noCredentials), .excluded(.providerUnsupported): return ""
        }
    }

    /// The role the line is drawn in: a spent or failed episode is a caution,
    /// a pending prime informational; nil (secondary text) for the rest.
    static func primeRole(_ status: WeeklyPrimeStatus) -> DesignRole? {
        switch status {
        case .failed, .noMovement: return .caution
        case .pending, .retry, .verifying: return .informational
        case .primed, .excluded: return nil
        }
    }

    /// "08:12" in the user's locale — the same short clock the reset tooltips use.
    static func clockTime(_ date: Date) -> String {
        shortClock.string(from: date)
    }

    private static let shortClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

/// The priming line under a Codex row's reset countdown.
struct RosterPrimeText: View {
    let status: WeeklyPrimeStatus
    var now = Date()

    var body: some View {
        let text = DashboardFormatting.primeLine(status, now: now)
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 8.5))
                .monospacedDigit()
                .foregroundColor(DashboardFormatting.primeRole(status)?.color ?? .secondary)
                .lineLimit(1)
                .fixedSize()
                .help("prime.status_help".localized)
        }
    }
}
