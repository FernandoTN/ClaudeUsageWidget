//
//  DesignFrameHarness.swift
//  Claude Usage
//
//  DEBUG-only: renders this endeavour's surfaces to PNG at 2x, light and dark,
//  for a fixture roster that covers every state, so the frame-by-frame design
//  pass (docs/specs/ux-revamp.md §12) can be reviewed without screenshots of a
//  live menu-bar agent. Honoured at launch when `CUW_RENDER_FRAMES=<dir>` is
//  set on a Debug build; never compiled into Release. Files:
//  `<surface>-<state>-<light|dark>@2x.png` plus `index.md`.
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum DesignFrameHarness {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["CUW_RENDER_FRAMES"], !dir.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { renderAll(to: URL(fileURLWithPath: dir)) }
    }

    static func renderAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var index = ["# Design frames", "", "Rendered by `CUW_RENDER_FRAMES` (Debug build) at 2x, light and dark.", ""]
        let now = Date()
        for (state, degraded, external) in [("healthy", false, [:]), ("degraded", true, [:]), ("changed-outside", false, [Profile.ProviderKind.claude: "dLeo"])] as [(String, Bool, [Profile.ProviderKind: String])] {
            let sel = Fixture.selections(degraded: degraded, now: now)
            let rows = ActiveSelectorMenuModel.rows(selections: sel, preferencesDegraded: degraded, externalChanges: external, switching: nil, now: now)
            emit(SelectorMenuFacsimile(rows: rows), width: 560, name: "selector-menu-\(state)", to: dir, index: &index)
        }
        for badge in [nil, ActiveSelectorMenuModel.Badge.red, .purple, .amber] {
            emit(SelectorItemFacsimile(badge: badge), width: 48, name: "selector-item-\(badge.map { "\($0)" } ?? "rest")", to: dir, index: &index)
        }
        let sel = Fixture.selections(degraded: false, now: now)
        let sections = AccountsRosterModel.sections(selections: sel, profiles: Fixture.profiles, sort: .bar, filter: "")
        emit(RosterFacsimile(sections: sections), width: 250, name: "accounts-roster-all-states", to: dir, index: &index)
        let largeSel = Fixture.selections(degraded: false, now: now, profiles: Fixture.largeProfiles)
        let largeSections = AccountsRosterModel.sections(selections: largeSel, profiles: Fixture.largeProfiles, sort: .bar, filter: "")
        emit(RosterFacsimile(sections: largeSections), width: 250, name: "accounts-roster-19", to: dir, index: &index)
        let largeInsights = FleetInsights.build(FleetInsights.Inputs(selections: largeSel, profiles: Fixture.largeProfiles, switchHistory: [], measured: [:],
                                                                     incidents: [], drift: [], backoffs: [:], counts: largeSel.map(\.counts), now: now))
        emit(DashboardInsightsView(insights: largeInsights, now: now).padding(14), width: 400, name: "dashboard-insights-19", to: dir, index: &index)
        var crowded = largeInsights
        crowded.resetTimeline = Array(repeating: largeInsights.resetTimeline, count: 2).flatMap { $0 }.enumerated().map { i, m in
            var m = m; m.resetAt = m.resetAt.addingTimeInterval(Double(i) * 1800); return m
        }
        emit(DashboardInsightsView(insights: crowded, now: now).padding(14), width: 400, name: "dashboard-insights-overflow", to: dir, index: &index)
        emit(ViewingPickerFacsimile(name: "dJormun"), width: 190, name: "settings-viewing-picker", to: dir, index: &index)
        for (state, name) in [("owner", "dRir"), ("viewed-non-owner", "dJormun"), ("dead", "Ai"), ("suspected", "Outlook"),
                              ("duplicate", "Google"), ("at-limit", "Commits"), ("never-measured", "Hotmail"), ("codex-owner", "xFernando")] {
            guard let profile = Fixture.profiles.first(where: { $0.name == name }),
                  let selection = sel.first(where: { $0.provider == profile.providerKind }) else { continue }
            let isOwner = selection.owner?.id == profile.id
            let candidate = selection.candidates.first { $0.id == profile.id }
            emit(AccountOverviewTab(profile: profile, selection: selection, isOwner: isOwner, candidate: candidate, onRepair: {}).padding(16),
                 width: 560, name: "accounts-overview-\(state)", to: dir, index: &index)
        }
        if let profile = Fixture.profiles.first {
            emit(AccountAlertsTab(profile: profile).padding(16), width: 560, name: "accounts-alerts-following", to: dir, index: &index)
            var own = profile
            own.usesFleetAlertDefaults = false
            own.notificationSettings = NotificationSettings(threshold75Enabled: false, soundName: "none", customThresholds: [50])
            emit(AccountAlertsTab(profile: own).padding(16), width: 560, name: "accounts-alerts-override", to: dir, index: &index)
            emit(AccountMonitoringTab(profile: profile).padding(16), width: 560, name: "accounts-monitoring", to: dir, index: &index)
        }
        emit(FleetAlertDefaultsCard(settings: .constant(NotificationSettings()), followers: 12, total: 14).padding(16),
             width: 560, name: "alerts-fleet-card", to: dir, index: &index)
        let overrideRows = [
            FleetAlerts.OverrideRow(id: UUID(), name: "Memori", summary: "50 · 90 % · no sound", differsFromFleet: true),
            FleetAlerts.OverrideRow(id: UUID(), name: "xFho", summary: "75 · 90 · 95 % · default sound", differsFromFleet: false),
        ]
        emit(AlertOverridesCard(rows: overrideRows, onOpen: { _ in }, onFollow: { _ in }, onFollowAll: {}).padding(16),
             width: 560, name: "alerts-overrides", to: dir, index: &index)
        emit(AlertOverridesCard(rows: [], onOpen: { _ in }, onFollow: { _ in }, onFollowAll: {}).padding(16),
             width: 560, name: "alerts-overrides-empty", to: dir, index: &index)
        emit(DisplayMenuBarCard().padding(16), width: 560, name: "display-menu-bar", to: dir, index: &index)
        emit(DisplayPopoverCard().padding(16), width: 560, name: "display-popover", to: dir, index: &index)
        emit(SingleAccountBarCards().padding(16), width: 560, name: "display-single-account", to: dir, index: &index)
        emit(AdvancedDiagnosticsCard().padding(16), width: 560, name: "advanced-diagnostics", to: dir, index: &index)
        emit(DeadLoginFlagsCard(rows: [DeadLoginFlagRow(id: UUID(), name: "Ai", provider: .claude),
                                       DeadLoginFlagRow(id: UUID(), name: "xFenrir(dev)", provider: .codex)]) { _ in }.padding(16),
             width: 560, name: "advanced-dead-logins", to: dir, index: &index)
        emit(StoredSettingsCard().padding(16), width: 560, name: "advanced-stored-settings", to: dir, index: &index)
        if let codex = Fixture.profiles.first(where: { $0.name == "xFernando(dev)" }) {
            let credits = CodexResetCredits(availableCount: 2, credits: [
                CodexResetCredit(id: "c1", resetType: nil, status: "available", grantedAt: nil, expiresAt: now.addingTimeInterval(3 * 86400), title: "Welcome reset", description: nil),
                CodexResetCredit(id: "c2", resetType: nil, status: "available", grantedAt: nil, expiresAt: nil, title: nil, description: nil),
            ], totalEarnedCount: 3, immediateResetPurchaseEligible: nil, fetchedAt: now.addingTimeInterval(-120))
            emit(CodexResetsCard(profile: codex, measurement: UsageMeasurement(provenance: .ownEndpoint, measuredAt: now.addingTimeInterval(-30)), readiness: .weeklyHit, preloaded: credits).padding(16),
                 width: 560, name: "codex-resets-at-limit", to: dir, index: &index)
            emit(CodexResetsCard(profile: codex, measurement: UsageMeasurement(provenance: .ownEndpoint, measuredAt: now.addingTimeInterval(-30)), readiness: .readyLight).padding(16),
                 width: 560, name: "codex-resets-headroom", to: dir, index: &index)
        }
        emit(DashboardInsightsView(insights: .fixture(now: now), now: now).padding(14), width: 400, name: "dashboard-insights", to: dir, index: &index)
        emit(DashboardInsightsView(insights: FleetInsights(resetTimeline: [], blindness: [], drift: [], switchLog: [], burn: [], incidents: [], capacity: [:], whyNotOthers: []), now: now).padding(14),
             width: 400, name: "dashboard-insights-empty", to: dir, index: &index)
        for selection in sel {
            emit(ActiveProviderCard(selection: selection, isEnabled: true) { _ in }.padding(16), width: 560,
                 name: "active-card-\(ActiveVocabulary.providerName(selection.provider).lowercased())", to: dir, index: &index)
        }
        for (state, name) in [("claude", "dRir"), ("codex", "xFernando(dev)"), ("grok", "Grok")] {
            if let profile = Fixture.profiles.first(where: { $0.name == name }) {
                emit(AccountLoginTab(profile: profile).padding(16), width: 560, name: "accounts-login-\(state)", to: dir, index: &index)
            }
        }
        // Shared directory convention with the menu-bar redesign's harness:
        // append a section rather than overwrite its index.
        let indexURL = dir.appendingPathComponent("index.md")
        var existing = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
        if let range = existing.range(of: "\n## UX revamp surfaces") { existing = String(existing[..<range.lowerBound]) }
        let section = ["", "## UX revamp surfaces (selector, Settings, Accounts inspector)", ""] + index.dropFirst(4)
        try? (existing.isEmpty ? index.prefix(4).joined(separator: "\n") : existing).appending(section.joined(separator: "\n"))
            .write(to: indexURL, atomically: true, encoding: .utf8)
        LoggingService.shared.log("DesignFrameHarness: wrote frames to \(dir.path)")
    }

    private static func emit<V: View>(_ view: V, width: CGFloat, name: String, to dir: URL, index: inout [String]) {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            let file = "\(name)-\(suffix)@2x.png"
            let renderer = ImageRenderer(content: view.frame(width: width).background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white).environment(\.colorScheme, scheme))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(file))
                index.append("- `\(file)`")
            }
        }
    }

    // MARK: - Fixture roster (every state the design pass names)

    enum Fixture {
        static let now = Date()
        static func usage(session: Double = 0, weekly: Double = 0, fable: Double? = nil, sessionWindow: Bool = true,
                          age: TimeInterval = 30, suspected: Bool = false, projected: Double? = nil, resets: Int? = nil) -> ClaudeUsage {
            var u = ClaudeUsage.empty
            u.sessionPercentage = session; u.sessionResetTime = now.addingTimeInterval(4 * 3600 + 120)
            u.weeklyPercentage = weekly; u.weeklyResetTime = now.addingTimeInterval(3 * 86400)
            u.fableWeeklyPercentage = fable; u.fableWeeklyResetTime = fable == nil ? nil : now.addingTimeInterval(3 * 86400)
            u.hasSessionWindow = sessionWindow ? nil : false
            u.lastUpdated = now.addingTimeInterval(-age)
            if suspected { u.rateLimitedUntil = now.addingTimeInterval(300); u.rateLimitedInferred = true; u.projectedSessionPercentage = projected }
            u.codexResetCreditsAvailable = resets
            return u
        }
        static func claude(_ name: String, _ u: ClaudeUsage?, email: String, account: String? = nil, autoSwitch: Bool = true) -> Profile {
            Profile(name: name, claudeSessionKey: "sk-ant-sid01-fixture", organizationId: "org", claudeAccountUUID: account,
                    claudeAccountEmail: email, claudeUsage: u, includeInAutoSwitch: autoSwitch)
        }
        static let profiles: [Profile] = [
            claude("dRir", usage(session: 78, weekly: 16, fable: 16), email: "owner@example.com", account: "acct-1"),
            claude("dJormun", usage(session: 12, weekly: 70, fable: 90, age: 180), email: "jormun@example.com"),
            claude("Memori", usage(session: 40, weekly: 55), email: "memori@example.com"),
            claude("Commits", usage(session: 10, weekly: 99.5), email: "commits@example.com"),
            claude("BBR", usage(session: 99, weekly: 40), email: "bbr@example.com"),
            claude("Ai", usage(session: 20), email: "ai@example.com"),
            claude("Google", usage(session: 78, weekly: 16, fable: 16), email: "owner@example.com", account: "acct-1"),
            claude("Outlook", usage(session: 74, weekly: 30, age: 720, suspected: true, projected: 81), email: "outlook@example.com"),
            claude("Hotmail", nil, email: "hotmail@example.com"),
            claude("Stanford", usage(session: 93, weekly: 20), email: "edu@example.com"),
            Profile(name: "xFernando(dev)", codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}", codexEmail: "codex-a@example.com", codexAccountId: "c-1",
                    claudeUsage: usage(weekly: 95, sessionWindow: false, resets: 2)),
            Profile(name: "xFenrir(dev)", codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}", codexEmail: "codex-b@example.com", codexAccountId: "c-2",
                    claudeUsage: usage(weekly: 10, sessionWindow: false)),
            Profile(name: "xFho", codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}", codexEmail: "codex@example.com", codexAccountId: "c-3",
                    claudeUsage: usage(weekly: 10, sessionWindow: false)),
            Profile(name: "Grok", grokCredentialsJSON: "{\"k\":{\"key\":\"x\"}}", grokEmail: "grok@x.ai",
                    claudeUsage: usage(weekly: 12, sessionWindow: false)),
        ]
        /// The owner's scale: the ten Claude profiles above plus nine more, mostly
        /// unstamped, with weekly resets that crowd the first two days of the strip.
        static let largeProfiles: [Profile] = profiles + [
            ("2026", 5.0, 30.0, 2.0), ("Alpha", 55.0, 88.0, 9.0), ("Beta", 61.0, 100.0, 9.5), ("Gamma", 8.0, 100.0, 10.0),
            ("Delta", 15.0, 42.0, 26.0), ("Echo", 90.0, 100.0, 27.0), ("Foxtrot", 33.0, 12.0, 27.5), ("Golf", 70.0, 64.0, 60.0), ("Hotel", 2.0, 9.0, 150.0),
        ].map { name, session, weekly, hours -> Profile in
            var u = usage(session: session, weekly: weekly)
            u.weeklyResetTime = now.addingTimeInterval(hours * 3600)
            return claude(name, u, email: "\(name.lowercased())@example.com")
        }
        static func selections(degraded: Bool, now: Date, profiles roster: [Profile] = profiles) -> [ProviderActiveSelection] {
            let profiles = roster
            let byName = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })
            let dead: Set<UUID> = [byName["Ai"]!.id, byName["xFenrir(dev)"]!.id]
            let free: Set<UUID> = [byName["Stanford"]!.id]
            let next = byName["dJormun"]!
            let context = FleetSummaryContext(
                thresholds: ReadinessThresholds(session: 95, weekly: 99),
                isLoginDead: { dead.contains($0.id) }, isExcluded: { !$0.isAutoSwitchEnabled || free.contains($0.id) },
                nextCandidates: [.claude: PredictedCandidate(id: next.id, label: "dJo", queued: false, queueHeadBlocked: false)],
                preflightVerdicts: [next.id: PreflightVerdict(isLive: true, at: now.addingTimeInterval(-720), kind: .probed)],
                preferencesDegraded: degraded, isSwitching: false, now: now)
            return ProviderActiveSelection.build(ProviderActiveSelection.Inputs(
                profiles: profiles, activeIds: [byName["dRir"]!.id, byName["xFernando(dev)"]!.id, byName["Grok"]!.id],
                focusedId: next.id, context: context, queue: [byName["Memori"]!.id],
                duplicateGroups: FleetCounts.duplicateGroups(in: profiles, published: []),
                manuallyPinned: [byName["dRir"]!.id], needsRelogin: [byName["Google"]!.id]))
        }
    }
}

// MARK: - Facsimiles of AppKit surfaces the renderer cannot capture

/// The ⇄ menu drawn as a SwiftUI list with the same rows, typography and tints.
struct SelectorMenuFacsimile: View {
    let rows: [ActiveSelectorMenuModel.Row]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row.kind {
                case .separator: Divider().padding(.vertical, 4)
                case .header: Text(row.title).font(.system(size: 10.5, weight: .bold)).tracking(0.6).foregroundColor(.secondary).padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 2)
                default:
                    HStack(spacing: 8) {
                        Text(row.glyph ?? " ").font(.system(size: 12, weight: .semibold)).foregroundColor(color(row.glyphTint) ?? .secondary).frame(width: 12)
                        if row.checked { Text("✓").font(.system(size: 12, weight: .semibold)) }
                        Text(row.title).font(.system(size: 13, weight: (row.detail != nil && row.glyph != nil && row.glyph != "→") || row.isPrimary ? .semibold : .regular))
                            .foregroundColor(color(row.titleTint) ?? (row.enabled && row.action != nil ? .primary : .secondary))
                        if let detail = row.detail { Text(detail).font(.system(size: 12, design: .monospaced)).foregroundColor(row.titleTint == .purple ? .purple : .secondary).lineLimit(1) }
                        Spacer(minLength: 0)
                        if !row.submenu.isEmpty { Text("▸").foregroundColor(.secondary) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 3)
                }
            }
        }
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 8))
    }
    private func color(_ tint: ActiveSelectorMenuModel.Tint?) -> Color? {
        switch tint {
        case .cyan: return DesignRole.active.color
        case .green: return DesignRole.ready.color
        case .orange: return DesignRole.caution.color
        case .red: return DesignRole.blocking.color
        case .purple: return DesignRole.suspected.color
        case .secondary: return DesignRole.informational.color
        case nil: return nil
        }
    }
}

/// The 24 × 22 pt item as the bar shows it, with its attention badge.
struct SelectorItemFacsimile: View {
    let badge: ActiveSelectorMenuModel.Badge?
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: ActiveSelectorItem.symbolName).font(.system(size: 15, weight: .medium)).frame(width: 24, height: 22)
            if let badge { Circle().fill(Color(nsColor: ActiveSelectorItem.badgeColor(badge))).frame(width: 5, height: 5).offset(x: -1, y: -1) }
        }
        .padding(12)
    }
}

struct RosterFacsimile: View {
    let sections: [AccountsRosterModel.Section]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sections, id: \.provider) { section in
                AccountsSectionHeader(section: section).padding(.horizontal, 8).padding(.top, 8)
                ForEach(section.rows, id: \.id) { row in AccountsRosterRow(row: row).padding(.horizontal, 8) }
            }
        }
        .padding(.vertical, 8)
    }
}

/// The Settings sidebar's Viewing picker (frame: stage 1a).
struct ViewingPickerFacsimile: View {
    let name: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ActiveVocabulary.viewing).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            HStack { Text(name).font(.system(size: 12)); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundColor(.secondary) }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        }
        .padding(8)
    }
}
#endif
