//
//  DashboardNextSwitch.swift
//  Claude Usage
//
//  The dashboard header's "switch to the next account now" button. Its
//  target is the Claude section's predicted next candidate as the snapshot
//  already carries it (`MenuBarManager.predictedNextCandidate` → the bar's
//  `→XXX` suffix → `ProviderSection.next`) — never a second ranking — and
//  the click is the same user-initiated activation the roster row runs,
//  without the confirmation step. Everything the button shows is a pure
//  function of the snapshot, so its four states are tested without a view.
//

import Foundation

/// What the header's next-switch button shows and whether it can be clicked.
struct NextSwitchAction: Hashable {
    enum State: Hashable {
        /// A Claude next candidate exists and the auto-switch would accept it.
        case ready
        /// The candidate exists but its login is dead or it has no headroom.
        case blocked
        /// No Claude section, or nobody to switch to.
        case noCandidate
        /// A switch — this button's or any other — is rewriting the logins.
        case switching
    }

    /// The button only ever moves the Claude login (owner, 2026-09-23: "it
    /// immediately switches the Claude account"), whichever sections exist.
    static let provider: Profile.ProviderKind = .claude

    /// The candidate's profile id; nil when there is no Claude candidate.
    var target: UUID?
    /// The candidate's full profile name (not the bar's 3-letter label).
    var name: String?
    var state: State
    var help: String

    var isEnabled: Bool { state == .ready && target != nil }
    var showsProgress: Bool { state == .switching }

    /// `switchingTo` is the name of the account this button is switching to
    /// right now (the view's in-flight task), nil when it is idle.
    static func make(snapshot: DashboardSnapshot?, switchingTo: String? = nil) -> NextSwitchAction {
        let section = snapshot?.sections.first { $0.provider == provider }
        let next = section?.next
        let target = next?.candidateId
        let name = next?.name

        if let switchingTo {
            return NextSwitchAction(target: target, name: name, state: .switching,
                                    help: "Switching \(DashboardFormatting.title(provider)) to \(switchingTo)…")
        }
        // The flag is global (`ProfileManager.isSwitchingProfile`): a Codex or
        // Grok switch in flight would refuse this one too.
        if snapshot?.sections.contains(where: { $0.summary.isSwitching }) == true {
            return NextSwitchAction(target: target, name: name, state: .switching,
                                    help: "A switch is in progress — try again in a moment")
        }
        guard let next else {
            return NextSwitchAction(target: nil, name: nil, state: .noCandidate,
                                    help: "No \(DashboardFormatting.title(provider)) account to switch to right now")
        }
        if next.readiness == .dead || next.verdict == .dead {
            return NextSwitchAction(target: target, name: name, state: .blocked,
                                    help: "\(next.name) is next in line, but its login is dead — the switch would be refused. Log in again first (/login, then Sync).")
        }
        if next.readiness.blocksSwitchTarget {
            return NextSwitchAction(target: target, name: name, state: .blocked,
                                    help: "\(next.name) is next in line, but \(blockedReason(next.readiness)) — not switching to it")
        }
        let source: String
        switch next.source {
        case .queued: source = "next in your queue"
        case .ranked: source = "next in line"
        case .rankedBehindBlockedQueueHead: source = "next in line (your queue head is blocked)"
        }
        return NextSwitchAction(target: target, name: name, state: .ready,
                                help: "Switch \(DashboardFormatting.title(provider)) now to \(next.name) — \(source)")
    }

    private static func blockedReason(_ readiness: AccountReadiness) -> String {
        switch readiness {
        case .suspected: return "it may be throttled (suspected)"
        case .sessionHit, .sessionHitLight: return "its session limit is hit"
        case .weeklyHit, .weeklyHitSoon: return "its weekly or Fable limit is hit"
        case .excluded: return "it is excluded from switching"
        case .dead: return "its login is dead"
        case .ready, .readyLight, .unknown: return "it cannot take the switch right now"
        }
    }
}

/// The one-line result under the header after a header-initiated switch.
/// Separate from the roster row's note: after a successful switch the target
/// becomes the ACTIVE card and leaves the roster, so a row-keyed note would
/// vanish exactly when it needs to be read.
struct HeaderSwitchNote: Hashable {
    let id = UUID()
    var text: String
    var role: DesignRole
    var icon: String
    /// How long the note stays before it clears itself; a failure is the
    /// user's next action, so it stays longer than a success.
    var lifetime: TimeInterval

    init(outcome: ProfileManager.ActivationOutcome, name: String) {
        text = DashboardFormatting.outcome(outcome, name: name, provider: NextSwitchAction.provider)
        switch outcome {
        case .activated:
            role = .ready; icon = "checkmark.circle"; lifetime = 6
        case .alreadyActive, .switchInFlight:
            role = .informational; icon = "info.circle"; lifetime = 6
        case .profileNotFound:
            role = .caution; icon = "exclamationmark.triangle"; lifetime = 12
        case .credentialsRefused, .focusedWithoutApplying, .credentialWriteFailed:
            role = .blocking; icon = "exclamationmark.triangle"; lifetime = 12
        }
    }
}
