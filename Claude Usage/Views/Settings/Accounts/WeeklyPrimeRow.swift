//
//  WeeklyPrimeRow.swift
//  Claude Usage
//
//  The inspector Overview's "Weekly prime" fact on a Codex account
//  (docs/specs/weekly-window-priming.md): the same line the dashboard row
//  prints — "primed 08:12 · resets Sep 16", "prime pending 08:15" — the
//  last attempt's detail, and "Prime now", the owner's explicit ask: it
//  bypasses the schedule, the toggle and the never-prime list, and is
//  refused only by no credentials, a dead login or a switch in flight.
//

import SwiftUI

struct WeeklyPrimeRow: View {
    let profile: Profile

    @State private var note: String?
    @State private var busy = false
    @State private var repaint = 0

    private var primer: WeeklyWindowPrimer { WeeklyWindowPrimer.shared }

    private var status: WeeklyPrimeStatus? {
        _ = repaint
        return WeeklyPrimeStatus.make(record: primer.record(for: profile.id), verdict: primer.verdict(for: profile.id), now: Date())
    }

    var body: some View {
        let status = self.status
        let line = status.map { DashboardFormatting.primeLine($0) }.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line ?? "prime.status_none".localized)
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(status.flatMap { DashboardFormatting.primeRole($0) }?.color ?? .primary)
                    .monospacedDigit()
                    .help("prime.status_help".localized)
                Spacer()
                Button("prime.now".localized) { Task { await primeNow() } }
                    .controlSize(.small)
                    .disabled(busy || primer.inFlight != nil || MenuBarManager.current == nil)
                    .help("prime.now_help".localized)
            }
            if line != nil, let detail = primer.record(for: profile.id)?.lastDetail, note == nil {
                Text(detail).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .weeklyPrimeStateChanged)) { _ in repaint += 1 }
    }

    private func primeNow() async {
        guard let manager = MenuBarManager.current else { return }
        busy = true
        defer { busy = false }
        note = await primer.primeNow(profile.id, context: manager.makeWeeklyPrimeContext())
        repaint += 1
    }
}
