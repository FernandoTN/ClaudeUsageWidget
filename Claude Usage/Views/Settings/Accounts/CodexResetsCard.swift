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

import SwiftUI
import AppKit

struct CodexResetsCard: View {
    let profile: Profile
    /// The shown number's measurement (for the at-limit gate).
    let measurement: UsageMeasurement?
    let readiness: AccountReadiness
    /// Preloaded details (frames / previews); the live card fetches on demand.
    var preloaded: CodexResetCredits? = nil

    @State private var details: CodexResetCredits?
    @State private var note: String?
    @State private var busy = false

    init(profile: Profile, measurement: UsageMeasurement?, readiness: AccountReadiness, preloaded: CodexResetCredits? = nil) {
        self.profile = profile
        self.measurement = measurement
        self.readiness = readiness
        self.preloaded = preloaded
        // The last on-demand answer this process holds, without a fetch.
        _details = State(initialValue: preloaded ?? CodexUsageService.shared.cachedResetCredits(for: profile.id))
    }

    private var count: Int? { details?.availableCount ?? profile.claudeUsage?.codexResetCreditsAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CodexResetsFormatting.countLine(count)).font(DesignTokens.Typography.body).monospacedDigit()
                Spacer()
                Button("resets.details".localized) { Task { await loadDetails(force: details != nil) } }
                    .buttonStyle(.link).disabled(busy)
                Button("resets.use_one".localized) { Task { await redeem() } }
                    .controlSize(.small)
                    .disabled(busy || !CodexResetsFormatting.canRedeem(count: count, readiness: readiness, measurement: measurement))
                    .help(CodexResetsFormatting.redeemHelp(count: count, readiness: readiness, measurement: measurement))
            }
            // F1: the unmet gate in plain sight, not only on hover.
            if !CodexResetsFormatting.canRedeem(count: count, readiness: readiness, measurement: measurement) {
                Text(CodexResetsFormatting.redeemHelp(count: count, readiness: readiness, measurement: measurement))
                    .font(DesignTokens.Typography.caption).foregroundColor(DesignRole.caution.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let details {
                ForEach(details.availableCreditsByExpiry) { credit in
                    Text(CodexResetsFormatting.creditLine(credit)).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                }
                if details.availableCreditsByExpiry.isEmpty {
                    Text("resets.none_listed".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                }
                Text("resets.fetched".localized(with: DashboardFormatting.age(details.fetchedAt))).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
            }
            if let note { Text(note).font(DesignTokens.Typography.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("resets.rule".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadDetails(force: Bool) async {
        busy = true; defer { busy = false }
        do {
            details = try await CodexUsageService.shared.fetchResetCredits(for: profile.id, force: force)
            note = nil
        } catch let error as CodexResetCreditsError {
            note = CodexResetsFormatting.errorText(error)
        } catch {
            note = error.localizedDescription
        }
    }

    private func redeem() async {
        guard let measurement else { return }
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        let alert = NSAlert()
        alert.messageText = "resets.confirm_title".localized(with: profile.name)
        alert.informativeText = "resets.confirm_body".localized(with: count ?? 0, DashboardFormatting.age(measurement.measuredAt))
        alert.addButton(withTitle: "common.cancel".localized)
        alert.addButton(withTitle: "resets.confirm_button".localized)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true; defer { busy = false }
        let evidence = CodexResetActivationEvidence(measuredAtLimit: readiness == .exhausted, measuredAt: measurement.measuredAt,
                                                    source: String(describing: measurement.provenance))
        do {
            let outcome = try await CodexUsageService.shared.activateReset(for: profile.id, evidence: evidence)
            note = CodexResetsFormatting.outcomeText(outcome)
            details = try? await CodexUsageService.shared.fetchResetCredits(for: profile.id, force: true)
        } catch let error as CodexResetCreditsError {
            note = CodexResetsFormatting.errorText(error)
        } catch {
            note = error.localizedDescription
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

    /// Redeem is offered only with a grant in hand and a measurement that says
    /// the account is AT its limit — spending a grant on headroom is waste.
    static func canRedeem(count: Int?, readiness: AccountReadiness, measurement: UsageMeasurement?) -> Bool {
        guard let count, count > 0, readiness == .exhausted, let measurement, measurement.isOwn else { return false }
        return true
    }

    static func redeemHelp(count: Int?, readiness: AccountReadiness, measurement: UsageMeasurement?) -> String {
        if (count ?? 0) == 0 { return "resets.help_none".localized }
        if readiness != .exhausted { return "resets.help_headroom".localized }
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
