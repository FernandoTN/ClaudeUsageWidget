//
//  ClaudeLimitResetsCard.swift
//  Claude Usage
//
//  Claude limit resets in the Accounts inspector, beside where Codex shows its
//  usage limit resets. Display only: the grants ride in the sweep's own usage
//  payload (`ClaudeLimitResets`), so there is nothing to fetch, and there is
//  deliberately no button — claiming a reset is irreversible and the app never
//  does it. A count appears only when grants arrived; otherwise the card says
//  "unknown" and gives the server's reason, never "0".
//

import SwiftUI

struct ClaudeLimitResetsCard: View {
    let usage: ClaudeUsage?
    var now: Date = Date()

    var body: some View {
        let resets = usage?.claudeLimitResets
        let count = usage?.claudeLimitResetsAvailable
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text(ClaudeLimitResetsFormatting.countLine(count)).font(DesignTokens.Typography.body).monospacedDigit()
            if count != nil {
                if let usableNow = usage?.claudeLimitResetsUsableNow {
                    Text("resets.usable_now".localized(with: usableNow))
                        .font(DesignTokens.Typography.caption).foregroundColor(.secondary).monospacedDigit()
                }
                ForEach(resets?.bank?.liveGrants(at: now) ?? []) { grant in
                    Text(ClaudeLimitResetsFormatting.grantLine(grant))
                        .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let measuredAt = usage?.claudeLimitResetsMeasuredAt {
                    Text("limit_resets.measured".localized(with: DashboardFormatting.age(measuredAt)))
                        .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                }
            } else {
                Text(ClaudeLimitResetsFormatting.unknownExplanation(resets))
                    .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let weekly = ClaudeLimitResetsFormatting.weeklySessionResetLine(resets?.weeklySessionReset) {
                Text(weekly).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
            }
            if count != nil {
                Text("limit_resets.rule".localized)
                    .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum ClaudeLimitResetsFormatting {
    /// "Limit resets: 2 left" — or "unknown". Never a "0" the server did not
    /// state through grants.
    static func countLine(_ count: Int?) -> String {
        guard let count else { return "limit_resets.count_unknown".localized }
        return "limit_resets.count_left".localized(with: count)
    }

    /// Why there is no count, in plain words, from the server's own reason.
    static func unknownExplanation(_ resets: ClaudeLimitResets?) -> String {
        guard let bank = resets?.bank else { return "limit_resets.reason.not_reported".localized }
        if bank.hasUnreadableGrant { return "limit_resets.reason.unreadable".localized }
        switch resets?.unknownReason {
        case "surface": return "limit_resets.reason.surface".localized
        case "tier": return "limit_resets.reason.tier".localized
        case "seat": return "limit_resets.reason.seat".localized
        case "no_grant": return "limit_resets.reason.no_grant".localized
        case let reason?: return "limit_resets.reason.other".localized(with: reason)
        case nil: return "limit_resets.reason.no_grants".localized
        }
    }

    /// "Welcome reset · 1 of 2 left · refills session + weekly · use by Oct 3, 2026 at 9:00 AM".
    static func grantLine(_ grant: ClaudeLimitResetGrant) -> String {
        var parts = [grant.label ?? "limit_resets.grant".localized]
        if let total = grant.resetsTotal {
            parts.append("limit_resets.left_of".localized(with: grant.resetsLeft, total))
        } else {
            parts.append("limit_resets.left".localized(with: grant.resetsLeft))
        }
        if !grant.clears.isEmpty {
            parts.append("limit_resets.refills".localized(with: windowsText(grant.clears)))
        }
        if let endsAt = grant.endsAt {
            parts.append("limit_resets.use_by".localized(with: ActiveSelectorMenuModel.expiryFormatter.string(from: endsAt)))
        }
        if !grant.useRequiresLimit {
            parts.append("limit_resets.before_limit".localized)
        }
        return parts.joined(separator: " · ")
    }

    /// "session + weekly" — the windows a grant refills, in the app's words;
    /// a limit type it does not know is shown as the server named it.
    static func windowsText(_ limitTypes: [String]) -> String {
        limitTypes.map { type in
            switch type {
            case "five_hour": return "limit_resets.window.session".localized
            case "seven_day", "seven_day_overage_included": return "limit_resets.window.weekly".localized
            case "seven_day_opus": return "limit_resets.window.opus".localized
            case "seven_day_sonnet": return "limit_resets.window.sonnet".localized
            default: return type
            }
        }
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        .joined(separator: " + ")
    }

    /// The weekly session reset (`juniper_tide`), only when the server says
    /// the account is eligible — otherwise nothing, like the count.
    static func weeklySessionResetLine(_ weekly: ClaudeWeeklySessionReset?) -> String? {
        guard let weekly, weekly.eligible == true else { return nil }
        if weekly.available == true { return "limit_resets.weekly_session_available".localized }
        guard let next = weekly.nextAvailableAt else { return nil }
        return "limit_resets.weekly_session_next".localized(with: ActiveSelectorMenuModel.expiryFormatter.string(from: next))
    }

    /// "Limit resets: Atlas 2 · Cedar 1" for the Claude segment's tooltip —
    /// accounts with a known count above zero only, or nil.
    static func tooltipLine(profiles: [Profile]) -> String? {
        let entries = profiles
            .filter { $0.providerKind == .claude }
            .compactMap { profile -> (String, Int)? in
                guard let count = profile.claudeUsage?.claudeLimitResetsAvailable, count > 0 else { return nil }
                return (profile.name, count)
            }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        guard !entries.isEmpty else { return nil }
        return "limit_resets.tooltip".localized(with: entries.map { "\($0.0) \($0.1)" }.joined(separator: " · "))
    }
}
