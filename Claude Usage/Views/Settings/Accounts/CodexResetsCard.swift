//
//  CodexResetsCard.swift
//  Claude Usage
//
//  Codex usage limit resets (docs/specs/ux-revamp.md §4.1, stage 4.1): the
//  count the sweep already carries, the details fetched ON DEMAND (the endpoint
//  is rate-limited per IP), and "Use one usage limit reset…" — the CLI's Redeem,
//  strictly user-initiated, gated on a measurement that says the account is at
//  its limit, never automatic. A null count reads "none or unknown", never "0".
//
//  Everything this card remembers is stamped with the profile it was learned
//  for and resolved against the VIEWED profile on every render (`Resolution`).
//  The inspector pane is re-identified per account, so a change of viewed
//  profile normally discards this state outright; the stamps are the second
//  line of defence — before either existed, one Details click showed that
//  account's grants on every other Codex account (owner report 2026-09-09).
//

import SwiftUI
import AppKit

/// A value remembered for one profile, so a later render for another profile
/// can tell it is not theirs.
struct AccountKeyed<Value> {
    let profileId: UUID
    let value: Value

    /// The value if it belongs to `profileId`, else nothing.
    func value(for profileId: UUID) -> Value? { self.profileId == profileId ? value : nil }
}

struct CodexResetsCard: View {
    let profile: Profile
    /// The shown number's measurement (for the at-limit gate).
    let measurement: UsageMeasurement?
    let readiness: AccountReadiness
    /// Preloaded details (frames / previews); the live card fetches on demand.
    var preloaded: CodexResetCredits? = nil

    @State private var fetched: AccountKeyed<CodexResetCredits>?
    @State private var note: AccountKeyed<String>?
    @State private var busy = false

    /// What this render shows for the viewed account: the pure decision, with
    /// the service's per-profile cache read for the VIEWED profile each time
    /// rather than seeded once at construction.
    private var resolution: Resolution {
        Resolution.resolve(viewed: profile.id,
                           fetched: fetched.map { ($0.profileId, $0.value) } ?? preloaded.map { (profile.id, $0) },
                           cached: CodexUsageService.shared.cachedResetCredits(for: profile.id),
                           sweepCount: profile.claudeUsage?.codexResetCreditsAvailable)
    }

    var body: some View {
        let resolved = resolution
        let count = resolved.count
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CodexResetsFormatting.countLine(count)).font(DesignTokens.Typography.body).monospacedDigit()
                Spacer()
                Button("resets.details".localized) { Task { await loadDetails(force: resolved.details != nil) } }
                    .buttonStyle(.link).disabled(busy)
                Button("resets.use_one".localized) { Task { await redeem(count: count) } }
                    .controlSize(.small)
                    .disabled(busy || !CodexResetsFormatting.canRedeem(count: count, readiness: readiness, measurement: measurement))
                    .help(CodexResetsFormatting.redeemHelp(count: count, readiness: readiness, measurement: measurement))
            }
            // The server's own "applicable right now" count, on its own line:
            // the header row has ~370 pt for text plus two buttons at the
            // Settings window's 760 pt minimum, and a longer count line wraps.
            if let usableNow = CodexResetsFormatting.usableNowLine(profile.claudeUsage?.codexResetCreditsApplicable) {
                Text(usableNow).font(DesignTokens.Typography.caption).foregroundColor(.secondary).monospacedDigit()
            }
            // F1: the unmet gate in plain sight, not only on hover.
            if !CodexResetsFormatting.canRedeem(count: count, readiness: readiness, measurement: measurement) {
                Text(CodexResetsFormatting.redeemHelp(count: count, readiness: readiness, measurement: measurement))
                    .font(DesignTokens.Typography.caption).foregroundColor(DesignRole.caution.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let details = resolved.details {
                ForEach(details.availableCreditsByExpiry) { credit in
                    Text(CodexResetsFormatting.creditLine(credit)).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                }
                if details.availableCreditsByExpiry.isEmpty {
                    Text("resets.none_listed".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                }
                Text("resets.fetched".localized(with: DashboardFormatting.age(details.fetchedAt))).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
            }
            if let note = note?.value(for: profile.id) {
                Text(note).font(DesignTokens.Typography.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("resets.rule".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadDetails(force: Bool) async {
        let target = profile.id
        busy = true; defer { busy = false }
        do {
            fetched = AccountKeyed(profileId: target, value: try await CodexUsageService.shared.fetchResetCredits(for: target, force: force))
            note = nil
        } catch let error as CodexResetCreditsError {
            note = AccountKeyed(profileId: target, value: CodexResetsFormatting.errorText(error))
        } catch {
            note = AccountKeyed(profileId: target, value: error.localizedDescription)
        }
    }

    private func redeem(count: Int?) async {
        guard let measurement else { return }
        let target = profile.id
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        let alert = NSAlert()
        alert.messageText = "resets.confirm_title".localized(with: profile.name)
        alert.informativeText = "resets.confirm_body".localized(with: count ?? 0, DashboardFormatting.age(measurement.measuredAt))
        alert.addButton(withTitle: "common.cancel".localized)
        alert.addButton(withTitle: "resets.confirm_button".localized)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true; defer { busy = false }
        let evidence = CodexResetActivationEvidence(measuredAtLimit: readiness.isAtLimit, measuredAt: measurement.measuredAt,
                                                    source: String(describing: measurement.provenance))
        do {
            let outcome = try await CodexUsageService.shared.activateReset(for: target, evidence: evidence)
            note = AccountKeyed(profileId: target, value: CodexResetsFormatting.outcomeText(outcome))
            fetched = (try? await CodexUsageService.shared.fetchResetCredits(for: target, force: true))
                .map { AccountKeyed(profileId: target, value: $0) }
        } catch let error as CodexResetCreditsError {
            note = AccountKeyed(profileId: target, value: CodexResetsFormatting.errorText(error))
        } catch {
            note = AccountKeyed(profileId: target, value: error.localizedDescription)
        }
    }
}

extension CodexResetsCard {
    /// What the card shows for the viewed profile. Pure so the identity rule is
    /// assertable without a view: details fetched for ANOTHER profile are
    /// discarded (never shown, never counted), then the viewed profile's own
    /// cached details, then the sweep's count with no details at all.
    struct Resolution: Equatable {
        let count: Int?
        let details: CodexResetCredits?

        static func resolve(viewed: UUID, fetched: (profileId: UUID, credits: CodexResetCredits)?,
                            cached: CodexResetCredits?, sweepCount: Int?) -> Resolution {
            let own = fetched.flatMap { $0.profileId == viewed ? $0.credits : nil } ?? cached
            return Resolution(count: own?.availableCount ?? sweepCount, details: own)
        }
    }
}

enum CodexResetsFormatting {
    /// "Usage limit resets: 2 available" — or "none or unknown": the payload's
    /// null cannot tell the two apart, so the copy never claims zero.
    static func countLine(_ count: Int?) -> String {
        guard let count else { return "resets.count_unknown".localized }
        return "selector.resets_available".localized(with: count)
    }

    /// "Usable now: 2" — the server's applicable count, a stated 0 included
    /// (xFme read 3 available / 0 usable while idle, 2026-09-09); nil, the
    /// unknown, prints nothing rather than a zero the payload never stated.
    static func usableNowLine(_ usableNow: Int?) -> String? {
        usableNow.map { "resets.usable_now".localized(with: $0) }
    }

    /// Redeem is offered only with a grant in hand and a measurement that says
    /// the account is AT its limit — spending a grant on headroom is waste.
    static func canRedeem(count: Int?, readiness: AccountReadiness, measurement: UsageMeasurement?) -> Bool {
        guard let count, count > 0, readiness.isAtLimit, let measurement, measurement.isOwn else { return false }
        return true
    }

    static func redeemHelp(count: Int?, readiness: AccountReadiness, measurement: UsageMeasurement?) -> String {
        if (count ?? 0) == 0 { return "resets.help_none".localized }
        if !readiness.isAtLimit { return "resets.help_headroom".localized }
        if measurement?.isOwn != true { return "resets.help_unmeasured".localized }
        return "resets.help_ready".localized
    }

    static func creditLine(_ credit: CodexResetCredit, now: Date = Date()) -> String {
        let title = credit.title ?? "resets.credit".localized
        guard let expires = credit.expiresAt else { return "resets.credit_never".localized(with: title) }
        return "resets.credit_expires".localized(with: title, expiry(expires.timeIntervalSince(now)))
    }

    /// "3 d" from two days out, the dashboard's short duration under that.
    static func expiry(_ interval: TimeInterval) -> String {
        let clamped = max(0, interval)
        if clamped >= 2 * 86400 { return "resets.days".localized(with: Int((clamped / 86400).rounded(.down))) }
        return DashboardFormatting.duration(clamped)
    }

    static func outcomeText(_ outcome: CodexResetActivationOutcome) -> String {
        switch outcome {
        case .reset(let windows): return "resets.outcome_reset".localized(with: windows)
        case .nothingToReset: return "resets.outcome_nothing".localized
        case .noCredit: return "resets.outcome_no_credit".localized
        case .alreadyRedeemed: return "resets.outcome_already".localized
        case .unknown(let code): return "resets.outcome_unknown".localized(with: code)
        }
    }

    static func errorText(_ error: CodexResetCreditsError) -> String {
        switch error {
        case .resetCreditsUnavailable: return "resets.error_unavailable".localized
        case .unsupportedForAPIKeyAuth: return "resets.error_api_key".localized
        case .notMeasuredAtLimit: return "resets.help_headroom".localized
        case .staleEvidence: return "resets.error_stale".localized
        default: return error.localizedDescription
        }
    }
}
