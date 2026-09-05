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
    /// row is never read as the session's. Empty for a never-measured row.
    static func resetCountdown(_ reset: ResetCountdown?, now: Date = Date()) -> String {
        guard let reset else { return "" }
        let label = gaugeTitle(reset.window == .fable ? .fable : .weekly, compact: true) + " "
        guard let at = reset.resetAt else { return label + "dashboard.reset_unknown".localized }
        if at <= now { return label + "dashboard.reset_now".localized }
        let clock = (reset.projected ? "~" : "") + at.timeRemainingString(from: now)
        return label + "accounts.resets_in".localized(with: clock)
    }

    /// The tooltip: the absolute boundary, and the provenance of a projected
    /// or unknown one spelled out.
    static func resetHelp(_ reset: ResetCountdown, now: Date = Date()) -> String {
        let window = reset.window == .fable
            ? "dashboard.reset_window_fable".localized : "dashboard.reset_window_weekly".localized
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

/// A row's weekly countdown in the row's small type, monospaced digits, the
/// absolute boundary on hover. Emphasised (primary, medium) on an exhausted
/// row, where the reset is the fact; an unreported boundary is a
/// data-quality notice and takes the caution colour, like a CLI-cache reading.
struct RosterResetText: View {
    let reset: ResetCountdown
    var emphasized = false
    var now = Date()

    var body: some View {
        Text(DashboardFormatting.resetCountdown(reset, now: now))
            .font(.system(size: 8.5, weight: emphasized ? .medium : .regular))
            .monospacedDigit()
            .foregroundColor(reset.resetAt == nil ? DesignRole.caution.color : (emphasized ? .primary : .secondary))
            .lineLimit(1)
            .fixedSize()
            .help(DashboardFormatting.resetHelp(reset, now: now))
    }
}
