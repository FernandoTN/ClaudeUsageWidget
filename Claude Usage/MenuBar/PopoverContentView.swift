import SwiftUI

// MARK: - Always-active vibrancy background
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        // Base vibrancy layer
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effectView)

        // Solid tint overlay for more density
        let tintView = NSView()
        tintView.wantsLayer = true
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        } else {
            tintView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
        }
        tintView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tintView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: container.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Same guard as its SettingsView twins: this runs on EVERY
        // re-evaluation of the owning SwiftUI tree, and unconditionally
        // assigning a full-window layer color scheduled a whole-window
        // recomposite per publish. Keyed on the VIEW's effective appearance.
        guard let tintView = nsView.subviews.last else { return }
        let isDark = nsView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let desired = isDark
            ? NSColor.black.withAlphaComponent(0.25).cgColor
            : NSColor.white.withAlphaComponent(0.4).cgColor
        if tintView.layer?.backgroundColor != desired {
            tintView.wantsLayer = true
            tintView.layer?.backgroundColor = desired
        }
    }
}

/// Native macOS popover interface - minimal, flat, system-style
struct PopoverContentView: View {
    @ObservedObject var manager: MenuBarManager
    let onRefresh: () -> Void
    let onPreferences: () -> Void
    let onManageProfiles: () -> Void
    /// Open the token-usage window for the viewed account (nil = fleet).
    var onTokenUsage: (UUID?, Profile.ProviderKind?) -> Void = { _, _ in }
    /// Make an account active for its provider — the one activation seam
    /// (`activateProfileDetailed(_:userInitiated: true)`), outcome reported.
    var onMakeActive: (UUID) async -> ProfileManager.ActivationOutcome = { _ in .profileNotFound }

    @State private var isRefreshing = false
    @State private var pendingSwitch: UUID?
    @State private var switchNote: String?
    @State private var noteFor: UUID?
    @StateObject private var profileManager = ProfileManager.shared

    private func profileInitials(for name: String) -> String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        } else if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }

    /// Relative "Updated Xm ago" for multi-profile staleness (F3).
    /// Returns nil while fresh (≤90s) so the tag stays quiet on a just-fetched profile.
    /// <60m → "Updated Xm ago"; else "Updated Xh Ym ago".
    private func relativeUpdatedText(from date: Date) -> String? {
        let age = Date().timeIntervalSince(date)
        guard age > 90 else { return nil }
        let totalMinutes = max(1, Int(age / 60))
        if totalMinutes < 60 {
            return "Updated \(totalMinutes)m ago"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "Updated \(hours)h \(minutes)m ago"
    }

    // Computed properties for multi-profile mode support
    private var displayUsage: ClaudeUsage {
        manager.clickedProfileUsage ?? manager.usage
    }

    /// The account whose usage this popover is showing.
    private var viewedProfile: Profile? {
        manager.clickedProfileId.flatMap { id in
            profileManager.profiles.first(where: { $0.id == id })
        } ?? profileManager.activeProfile
    }

    /// The viewed account's provider group, LEFT-TO-RIGHT exactly as the menu
    /// bar paints the tiles (soonest weekly reset at the RIGHT edge).
    ///
    /// Read from the bar's PAINTED order, not recomputed: the ranking key is a
    /// weekly reset boundary, so it flips the instant that boundary passes
    /// while the tiles keep their painted order until the next rebuild.
    /// Recomputing here made chip N stop meaning tile N and sent the ‹ › walk
    /// down a different order than the bar shows. The static ranking remains
    /// the fallback for "nothing painted yet".
    private var groupMembers: [Profile] {
        guard profileManager.displayMode == .multi, let viewed = viewedProfile else { return [] }
        return StatusBarUIManager.onScreenGroupMembers(
            for: profileManager.profiles,
            provider: viewed.providerKind,
            paintedOrder: manager.paintedGroupMembers(for: viewed.providerKind)
        )
    }

    /// Accounts the menu bar marks ACTIVE — same definition the tiles' cyan
    /// label uses, so the bar and the popover can never disagree.
    private var activeAccountIds: Set<UUID> {
        profileManager.activeAccountIds(among: profileManager.profiles)
    }

    /// Move the viewed account `delta` tiles along its group, wrapping around.
    /// Backs the ‹ › buttons and the left/right arrow keys.
    private func cycleGroup(_ delta: Int) {
        let members = groupMembers
        guard members.count > 1 else { return }
        let current = members.firstIndex(where: { $0.id == manager.clickedProfileId }) ?? 0
        let next = ((current + delta) % members.count + members.count) % members.count
        manager.viewProfile(members[next].id)
    }

    private func makeActiveRow(_ profile: Profile) -> some View {
        MakeActiveRow(
            name: profile.name,
            provider: profile.providerKind,
            loginDead: ProfileCredentialStatusCache.hasDeadLogin(profile),
            isPending: pendingSwitch == profile.id,
            note: noteFor == profile.id ? switchNote : nil,
            onBegin: { pendingSwitch = profile.id; switchNote = nil },
            onConfirm: {
                let id = profile.id
                let name = profile.name
                pendingSwitch = nil
                Task { @MainActor in
                    let outcome = await onMakeActive(id)
                    switchNote = DashboardFormatting.outcome(outcome, name: name)
                    noteFor = id
                }
            },
            onCancel: { pendingSwitch = nil }
        )
    }

    /// Name of the VIEWED profile if its last fetch hit a credential error, nil
    /// otherwise. Keyed on per-profile membership in BOTH display modes — one
    /// dead login must not banner every popover, and a lingering global flag
    /// must not accuse whichever profile happens to be focused now.
    private var credentialErrorProfileName: String? {
        let viewedId = (profileManager.displayMode == .multi ? manager.clickedProfileId : nil)
            ?? profileManager.activeProfile?.id
        guard let id = viewedId, manager.credentialErrorProfileIds.contains(id) else { return nil }
        return profileManager.profiles.first { $0.id == id }?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            SmartHeader(
                usage: displayUsage,
                status: manager.status,
                isRefreshing: isRefreshing,
                onRefresh: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isRefreshing = true
                    }
                    onRefresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isRefreshing = false
                        }
                    }
                },
                onManageProfiles: onManageProfiles,
                onPreferences: onPreferences,
                clickedProfileId: manager.clickedProfileId,
                onTokenUsage: onTokenUsage
            )

            PopoverDivider()

            // Error / stale data banners. The preferences-daemon banner wins: while
            // cfprefsd is wedged every other symptom below is downstream of it, and
            // the user needs to know the values on screen are cached and unsaveable.
            if profileManager.preferencesDegraded {
                StatusBannerView(
                    icon: "externaldrive.badge.exclamationmark",
                    message: "popover.banner.preferences_degraded".localized,
                    color: .orange
                )
            } else if let errorProfileName = credentialErrorProfileName {
                StatusBannerView(
                    icon: "exclamationmark.triangle.fill",
                    message: String(format: "popover.banner.credentials_expired_profile".localized, errorProfileName),
                    color: .orange
                ) {
                    onManageProfiles()
                }
            } else if manager.consecutiveRefreshFailures >= 3 {
                StatusBannerView(
                    icon: "arrow.clockwise.circle.fill",
                    message: String(format: "popover.banner.refresh_failed".localized, manager.consecutiveRefreshFailures),
                    color: .yellow
                ) {
                    onRefresh()
                }
            } else if let lastRefresh = manager.lastSuccessfulRefreshTime,
                      Date().timeIntervalSince(lastRefresh) > 300 {
                let minutesAgo = Int(Date().timeIntervalSince(lastRefresh) / 60)
                StatusBannerView(
                    icon: "clock.fill",
                    message: String(format: "popover.banner.updated_ago".localized, minutesAgo),
                    color: .orange
                ) {
                    onRefresh()
                }
            }

            // Viewing usage tag (shown in multi-profile mode)
            if profileManager.displayMode == .multi,
               let viewingProfile = manager.clickedProfileId.flatMap({ id in
                   profileManager.profiles.first(where: { $0.id == id })
               }) ?? profileManager.activeProfile {
                HStack(spacing: 8) {
                    // Profile initials avatar
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 20, height: 20)

                        Text(profileInitials(for: viewingProfile.name))
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(.accentColor)
                    }

                    Text(viewingProfile.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if viewingProfile.hasCodexAccount {
                        Text("CODEX")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.purple.opacity(0.12))
                            )
                    }

                    Spacer()

                    // Per-profile staleness (F3): honest "Updated Xm ago" once
                    // the viewed profile's usage is older than 90s. Fresh data
                    // stays silent so the tag doesn't chatter on every open.
                    if let staleness = relativeUpdatedText(from: displayUsage.lastUpdated) {
                        Text(staleness)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if activeAccountIds.contains(viewingProfile.id) {
                        Text("Active")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Color(nsColor: .systemCyan))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color(nsColor: .systemCyan).opacity(0.14))
                            )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.03))
                )
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            // Group navigator — composite tiles put a whole provider group in
            // ONE status item, so the popover must be able to walk the group
            // itself instead of relying on precise per-tile clicks. Also the
            // one place the user can SEE which account of the group is active.
            if profileManager.displayMode == .multi, groupMembers.count > 1 {
                GroupNavigator(
                    members: groupMembers,
                    viewedId: viewedProfile?.id,
                    activeIds: activeAccountIds,
                    onSelect: { manager.viewProfile($0) },
                    onStep: { cycleGroup($0) }
                )
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }

            // Make the VIEWED account active for its provider: the classic
            // popover's one switch path now that the name menu only views
            // (docs/specs/ux-revamp.md D6 — focus is never authority). Two
            // steps with the cost stated, through the one activation seam;
            // the popover stays open (#71) so the outcome is read here.
            if let viewed = viewedProfile {
                if PopoverSwitchRule.canMakeActive(viewed, activeIds: activeAccountIds) {
                    makeActiveRow(viewed)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                } else if let note = switchNote, noteFor == viewed.id {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                }
            }

            // Grok account note — only the weekly bar is meaningful (SuperGrok
            // bills a weekly credit window; there is no 5-hour session concept,
            // so the session bar always reads 0%).
            if let viewingProfile = manager.clickedProfileId.flatMap({ id in
                   profileManager.profiles.first(where: { $0.id == id })
               }) ?? profileManager.activeProfile,
               viewingProfile.isGrokOnlyProfile {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.orange)

                    Text(viewingProfile.grokEmail.map {
                        String(format: "popover.grok_note_email".localized, $0)
                    } ?? "popover.grok_note".localized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()
                }
                .padding(.horizontal, 14)
            }

            // Codex account note — the session/weekly bars below show the OpenAI
            // Codex plan windows, not Claude usage
            if let viewingProfile = manager.clickedProfileId.flatMap({ id in
                   profileManager.profiles.first(where: { $0.id == id })
               }) ?? profileManager.activeProfile,
               viewingProfile.isCodexOnlyProfile {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.purple)

                    Text(viewingProfile.codexEmail.map {
                        String(format: "popover.codex_note_email".localized, $0)
                    } ?? "popover.codex_note".localized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.purple.opacity(0.06))
                )
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            // Usage
            SmartUsageDashboard(usage: displayUsage)

        }
        .padding(.bottom, 8)
        .frame(width: 280)
        .background(VisualEffectBackground())
        // Arrow keys walk the group too, when the popover holds focus. The ‹ ›
        // buttons are the guaranteed affordance; this is the shortcut on top.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            cycleGroup(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            cycleGroup(1)
            return .handled
        }
    }
}

// MARK: - Composite group navigator

/// Walk the accounts of one provider group without hunting for a ~20pt tile
/// segment in the menu bar.
///
/// Chips are ordered exactly as the tiles are painted — left to right, with the
/// SOONEST weekly reset at the right edge — so the strip is a map of the group
/// as it appears on the bar. The chip of the account that owns the provider's
/// shared CLI login carries the same cyan the tile's label uses; the viewed
/// account is the filled one.
struct GroupNavigator: View {
    let members: [Profile]
    let viewedId: UUID?
    let activeIds: Set<UUID>
    let onSelect: (UUID) -> Void
    let onStep: (Int) -> Void

    private func chipLabel(_ profile: Profile) -> String {
        String(profile.menuBarDisplayName.prefix(3)).uppercased()
    }

    var body: some View {
        HStack(spacing: 6) {
            stepButton("chevron.left", delta: -1)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(members) { member in
                            chip(for: member)
                                .id(member.id)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
                // A wide group overflows the strip (7 of 11 chips visible on a
                // 15-account bar): keep the VIEWED chip on screen, or ‹ ›
                // cycling walks into accounts the owner cannot see change.
                .onAppear {
                    if let viewedId { proxy.scrollTo(viewedId, anchor: .center) }
                }
                .onChange(of: viewedId) { _, newId in
                    guard let newId else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }

            stepButton("chevron.right", delta: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.03))
        )
    }

    @ViewBuilder
    private func chip(for member: Profile) -> some View {
        let isViewed = member.id == viewedId
        let isActive = activeIds.contains(member.id)
        Button {
            onSelect(member.id)
        } label: {
            VStack(spacing: 2) {
                Text(chipLabel(member))
                    .font(.system(size: 9, weight: isViewed ? .bold : .medium,
                                  design: .rounded))
                    .foregroundColor(
                        isActive ? Color(nsColor: .systemCyan)
                                 : (isViewed ? .primary : .secondary)
                    )
                // Active marker: matches the tile's cyan label.
                Circle()
                    .fill(isActive ? Color(nsColor: .systemCyan) : Color.clear)
                    .frame(width: 3, height: 3)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isViewed ? Color.primary.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isViewed ? Color.primary.opacity(0.25) : Color.clear,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(member.name)
    }

    private func stepButton(_ systemName: String, delta: Int) -> some View {
        Button {
            onStep(delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Native Divider

/// The classic popover's "Make active for <provider>…" control: the offer,
/// the two-step confirmation (cost stated, dead login warned), and the
/// outcome note. A pure function of its inputs — the state lives in the
/// popover — so the frame harness can render every step from fixtures.
struct MakeActiveRow: View {
    let name: String
    let provider: Profile.ProviderKind
    let loginDead: Bool
    let isPending: Bool
    let note: String?
    let onBegin: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isPending {
                // Frame harness, first finding: at popover width these
                // sentences truncated with an ellipsis. They wrap.
                Text("Switch the \(ActiveVocabulary.providerName(provider)) login to \(name)?")
                    .font(.system(size: 10, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(DashboardFormatting.switchCost(provider))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if loginDead {
                    Text("This login is dead; the switch will be refused. Log in again first.")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Switch", action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                    Button("common.cancel".localized, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            } else {
                Button(action: onBegin) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(ActiveVocabulary.makeActive(provider))
                            .font(.system(size: 10, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let note {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isPending ? Color.orange.opacity(0.10) : Color.primary.opacity(0.03))
        )
    }
}

/// When the classic popover offers "Make active for <provider>…" on the
/// viewed account: never for the provider's current owner, and only for an
/// account that carries a login the activation could apply.
enum PopoverSwitchRule {
    nonisolated static func canMakeActive(_ profile: Profile, activeIds: Set<UUID>) -> Bool {
        guard !activeIds.contains(profile.id) else { return false }
        switch profile.providerKind {
        case .claude: return profile.hasCliAccount
        case .codex: return profile.hasCodexAccount
        case .grok: return profile.isGrokOnlyProfile
        }
    }
}

struct PopoverDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 16)
    }
}

// MARK: - Profile Switcher Compact (for header)

/// The name menu VIEWS an account — it never switches a CLI (docs/specs/
/// ux-revamp.md D6: focus is never authority). Making a login active is the
/// ⇄ selector's and the dashboard's job, where the cost and the target's
/// verdict are spelled out first.
struct ProfileSwitcherCompact: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var isHovered = false
    let onManageProfiles: () -> Void
    var onTokenUsage: (UUID?, Profile.ProviderKind?) -> Void = { _, _ in }

    /// True when a provider login this profile carries is known dead (expired
    /// with a revoked refresh token). Selecting such a profile is refused by the
    /// activation gate, so say so IN the menu instead of leaving a button that
    /// appears to do nothing. Derived from the cached credential JSON and the
    /// services' persisted dead-login flags — no Keychain reads.
    private func hasDeadLogin(_ profile: Profile) -> Bool {
        ProfileCredentialStatusCache.hasDeadLogin(profile)
    }

    var body: some View {
        Menu {
            ForEach(profileManager.profiles) { profile in
                let loginDead = hasDeadLogin(profile)
                Button(action: {
                    _ = profileManager.viewProfile(profile.id)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: loginDead ? "exclamationmark.triangle.fill" : "person.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(loginDead ? .red : .primary)

                        Text(loginDead
                             ? String(format: "popover.profile_login_expired".localized, profile.name)
                             : profile.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(loginDead ? .secondary : .primary)

                        Spacer()

                        HStack(spacing: 4) {
                            // Auto-switch eligibility: filled green rotation = eligible,
                            // hollow gray = excluded from auto-switch
                            Image(systemName: profile.isAutoSwitchEnabled
                                  ? "arrow.triangle.2.circlepath.circle.fill"
                                  : "arrow.triangle.2.circlepath.circle")
                                .font(.system(size: 9))
                                .foregroundColor(profile.isAutoSwitchEnabled ? .adaptiveGreen : .secondary)

                            if profile.hasCodexAccount {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundColor(.purple)
                            }

                            if profile.hasCliAccount {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.adaptiveGreen)
                            }

                            if profile.id == profileManager.activeProfile?.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }

            Divider()

            Button(action: onManageProfiles) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("popover.manage_profiles".localized)
                        .font(.system(size: 12, weight: .medium))
                }
            }

            Button(action: {
                onTokenUsage(profileManager.activeProfile?.id, profileManager.activeProfile?.providerKind)
            }) {
                HStack {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 12))
                    Text("popover.token_usage".localized)
                        .font(.system(size: 12, weight: .medium))
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ActiveVocabulary.viewing)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                Text(profileManager.activeProfile?.name ?? "popover.no_profile".localized)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }
}

// MARK: - Smart Header Component
struct SmartHeader: View {
    let usage: ClaudeUsage
    let status: ClaudeStatus
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onManageProfiles: () -> Void
    let onPreferences: () -> Void
    var clickedProfileId: UUID? = nil
    var onTokenUsage: (UUID?, Profile.ProviderKind?) -> Void = { _, _ in }

    @StateObject private var profileManager = ProfileManager.shared

    private var statusColor: Color {
        switch status.indicator.color {
        case .green: return .adaptiveGreen
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        case .gray: return .gray
        }
    }

    private var isMultiProfileMode: Bool {
        profileManager.displayMode == .multi
    }

    private var clickedProfile: Profile? {
        guard let id = clickedProfileId else { return nil }
        return profileManager.profiles.first { $0.id == id }
    }

    private func profileInitials(for name: String) -> String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        } else if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                ProfileSwitcherCompact(onManageProfiles: onManageProfiles, onTokenUsage: onTokenUsage)

                // Status
                Button(action: {
                    if let url = URL(string: "https://status.claude.com") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)

                        Text(status.description)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to open status.claude.com")
            }

            Spacer()

            HStack(alignment: .center, spacing: 2) {
                // Refresh
                HeaderIconButton(
                    icon: "arrow.clockwise",
                    isRefreshing: isRefreshing,
                    action: onRefresh
                )
                .disabled(isRefreshing)

                // Settings
                HeaderIconButton(
                    icon: "gearshape.fill",
                    fontSize: 12,
                    action: onPreferences
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Header Icon Button
struct HeaderIconButton: View {
    let icon: String
    var fontSize: CGFloat = 10.5
    var isRefreshing: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: fontSize, weight: .medium))
                        .imageScale(.medium)
                }
            }
            .foregroundColor(isHovered ? .primary : .secondary)
            .frame(width: 24, height: 24, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Smart Usage Dashboard
struct SmartUsageDashboard: View {
    let usage: ClaudeUsage
    @StateObject private var profileManager = ProfileManager.shared

    private var showRemainingPercentage: Bool {
        profileManager.activeProfile?.iconConfig.showRemainingPercentage ?? false
    }

    private var showTimeMarker: Bool {
        if profileManager.displayMode == .multi {
            return profileManager.multiProfileConfig.showTimeMarker
        }
        return profileManager.activeProfile?.iconConfig.showTimeMarker ?? true
    }

    private var usePaceColoring: Bool {
        if profileManager.displayMode == .multi {
            return profileManager.multiProfileConfig.usePaceColoring
        }
        return profileManager.activeProfile?.iconConfig.usePaceColoring ?? true
    }

    private var showPaceMarker: Bool {
        if profileManager.displayMode == .multi {
            return profileManager.multiProfileConfig.showPaceMarker
        }
        return profileManager.activeProfile?.iconConfig.showPaceMarker ?? true
    }

    private var timeDisplay: PopoverTimeDisplay {
        SharedDataStore.shared.loadPopoverTimeDisplay()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Primary: Session Usage — omitted for weekly-only providers (Grok;
            // Codex since OpenAI collapsed to a single 7-day window): a
            // permanent-0% session row is noise, the weekly row IS their usage.
            if usage.providesSessionWindow {
                UsageRow(
                    title: "menubar.session_usage".localized,
                    subtitle: "menubar.5_hour_window".localized,
                    usedPercentage: usage.displaySessionPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: usage.sessionResetTime,
                    periodDuration: Constants.sessionWindow,
                    showTimeMarker: showTimeMarker,
                    showPaceMarker: showPaceMarker,
                    usePaceColoring: usePaceColoring,
                    timeDisplay: timeDisplay
                )
                // Data-quality caveat, not a usage level: the number above is
                // the last MEASURED value (or a burn-rate estimate) — the
                // endpoint is refusing reads, which MAY be a shared rate
                // limit rather than exhaustion.
                if usage.isSuspectedRateLimited {
                    Label {
                        Text(usage.projectedSessionPercentage != nil
                            ? "popover.suspected_projected".localized(
                                with: Int(usage.sessionPercentage.rounded()),
                                usage.lastUpdated.formatted(date: .omitted, time: .shortened)
                            )
                            : "popover.suspected_rate_limited".localized(
                                with: usage.lastUpdated.formatted(date: .omitted, time: .shortened)
                            ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.purple)
                    }
                }
            }

            // All Models (Weekly)
            UsageRow(
                title: "menubar.all_models".localized,
                tag: "menubar.weekly".localized,
                subtitle: nil,
                usedPercentage: usage.weeklyPercentage,
                showRemaining: showRemainingPercentage,
                resetTime: usage.weeklyResetTime,
                periodDuration: Constants.weeklyWindow,
                showTimeMarker: showTimeMarker,
                showPaceMarker: showPaceMarker,
                usePaceColoring: usePaceColoring,
                timeDisplay: timeDisplay
            )

            if usage.opusWeeklyTokensUsed > 0 {
                UsageRow(
                    title: "menubar.opus_usage".localized,
                    tag: "menubar.weekly".localized,
                    subtitle: nil,
                    usedPercentage: usage.opusWeeklyPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: nil,
                    periodDuration: nil
                )
            }

            if usage.sonnetWeeklyTokensUsed > 0 {
                UsageRow(
                    title: "menubar.sonnet_usage".localized,
                    subtitle: nil,
                    usedPercentage: usage.sonnetWeeklyPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: usage.sonnetWeeklyResetTime,
                    periodDuration: nil,
                    timeDisplay: timeDisplay
                )
            }

            if let fablePercentage = usage.fableWeeklyPercentage {
                UsageRow(
                    title: "menubar.fable_usage".localized,
                    tag: "menubar.weekly".localized,
                    subtitle: nil,
                    usedPercentage: fablePercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: usage.fableWeeklyResetTime,
                    periodDuration: Constants.weeklyWindow,
                    showTimeMarker: showTimeMarker,
                    showPaceMarker: showPaceMarker,
                    usePaceColoring: usePaceColoring,
                    timeDisplay: timeDisplay
                )
            }

            // Extra usage (cost-based)
            if let used = usage.costUsed, let limit = usage.costLimit, let currency = usage.costCurrency, limit > 0 {
                let usedPercentage = (used / limit) * 100.0
                UsageRow(
                    title: "menubar.extra_usage".localized,
                    subtitle: String(format: "%.2f / %.2f %@", used / 100.0, limit / 100.0, currency),
                    usedPercentage: usedPercentage,
                    showRemaining: showRemainingPercentage,
                    resetTime: nil,
                    periodDuration: nil
                )

                // Overage credit grant balance
                if let balance = usage.overageBalance, let balanceCurrency = usage.overageBalanceCurrency {
                    HStack {
                        Text("popover.overage_balance".localized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.2f %@", balance / 100.0, balanceCurrency.uppercased()))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.adaptiveGreen)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Usage Row (flat, native style)
struct UsageRow: View {
    let title: String
    var tag: String? = nil
    let subtitle: String?
    let usedPercentage: Double
    let showRemaining: Bool
    let resetTime: Date?
    let periodDuration: TimeInterval?
    var showTimeMarker: Bool = true
    var showPaceMarker: Bool = true
    var usePaceColoring: Bool = true
    var timeDisplay: PopoverTimeDisplay = .resetTime

    private var displayPercentage: Double {
        UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: usedPercentage,
            showRemaining: showRemaining
        )
    }

    private var rawElapsedFraction: Double? {
        UsageStatusCalculator.elapsedFraction(
            resetTime: resetTime,
            duration: periodDuration ?? 0,
            showRemaining: false
        )
    }

    private var timeMarkerFraction: CGFloat? {
        guard showTimeMarker, let f = rawElapsedFraction else { return nil }
        return CGFloat(showRemaining ? 1.0 - f : f)
    }

    private var paceStatus: PaceStatus? {
        guard showPaceMarker, let elapsed = rawElapsedFraction else { return nil }
        return PaceStatus.calculate(usedPercentage: usedPercentage, elapsedFraction: elapsed)
    }

    private var timeMarkerColor: Color {
        if let pace = paceStatus {
            return pace.swiftUIColor
        }
        return Color(nsColor: .labelColor)
    }

    private var statusLevel: UsageStatusLevel {
        UsageStatusCalculator.calculateStatus(
            usedPercentage: usedPercentage,
            showRemaining: showRemaining,
            elapsedFraction: usePaceColoring ? rawElapsedFraction : nil
        )
    }

    private var statusColor: Color {
        switch statusLevel {
        case .safe: return .adaptiveGreen
        case .moderate: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title row with percentage
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)

                        if let tag = tag {
                            Text(tag)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(Color.primary.opacity(0.08))
                                )
                        }
                    }

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text("\(Int(displayPercentage))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(statusColor)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.primary.opacity(0.08))

                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(statusColor)
                        .frame(width: geometry.size.width * min(displayPercentage / 100.0, 1.0))
                        .animation(.easeInOut(duration: 0.6), value: displayPercentage)
                }
                .overlay(alignment: .leading) {
                    if let fraction = timeMarkerFraction {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(timeMarkerColor)
                            .frame(width: 2.5, height: 8)
                            .offset(x: round(geometry.size.width * fraction) - 0.75)
                    }
                }
            }
            .frame(height: 4)

            // Reset time
            if let reset = resetTime {
                Text(resetTimeText(for: reset))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    private func resetTimeText(for reset: Date) -> String {
        switch timeDisplay {
        case .resetTime:
            return "menubar.resets_time".localized(with: reset.resetTimeString())
        case .remainingTime:
            return "menubar.resets_in".localized(with: reset.timeRemainingString())
        case .both:
            return "menubar.resets_both".localized(with: reset.timeRemainingString(), reset.resetTimeString())
        }
    }
}

// MARK: - Status Banner View
struct StatusBannerView: View {
    let icon: String
    let message: String
    let color: Color
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .cornerRadius(6)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .onTapGesture { onTap?() }
    }
}
