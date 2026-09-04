import Foundation

/// Main data model representing Claude Code usage statistics
struct ClaudeUsage: Codable, Equatable {
    // Session data (5-hour rolling window)
    var sessionTokensUsed: Int
    var sessionLimit: Int
    var sessionPercentage: Double
    var sessionResetTime: Date

    /// Returns 0% if the 5-hour session window has expired, otherwise the raw percentage.
    /// While the account is under an account-level API throttle (see
    /// `rateLimitedUntil`), reports 100%: the account has zero usable capacity
    /// right now REGARDLESS of what the last readable percentage said, and this
    /// property is the single seam through which the tiles, popover, auto-switch
    /// trigger, and candidate headroom checks all read session capacity.
    var effectiveSessionPercentage: Double {
        if let until = rateLimitedUntil, until > Date() {
            return max(sessionPercentage, 100.0)
        }
        return sessionResetTime < Date() ? 0.0 : sessionPercentage
    }

    /// Set when the usage API itself refused to answer for this ACCOUNT with a
    /// long Retry-After (HTTP 429). A heavily-used/exhausted account throttles
    /// its own oauth/usage endpoint — exactly when the number matters most —
    /// so the cached percentages silently freeze at their last readable values
    /// (a real incident: an account sat at a cached 16% while `/usage` showed
    /// 100%, and nothing flagged it). The throttle response IS the usage signal:
    /// until this stamp expires the account is treated as having no capacity.
    /// Optional with nil default so previously cached usage JSON still decodes.
    var rateLimitedUntil: Date? = nil

    /// True when `rateLimitedUntil` was INFERRED from a 429 streak plus
    /// cross-account control evidence rather than affirmed by the server (a
    /// long Retry-After). Display, scheduling, and switch-TARGET eligibility
    /// treat both stamps the same (100%, skip fetching, never switch INTO the
    /// account) — but an inferred stamp must never DISPLACE the active
    /// account: a profile switch invalidates every concurrent CLI session's
    /// prompt cache (~10-15% of quota re-reading context), far too costly to
    /// spend on circumstantial evidence (2026-08-11: an inferred stamp on
    /// 'BBR' auto-switched the fleet away at a real ~40% session). Optional
    /// with nil default so previously cached usage JSON still decodes.
    var rateLimitedInferred: Bool? = nil

    /// How this value was obtained. nil = measured through the account's OWN
    /// usage endpoint with its own credentials (the legacy default, so
    /// previously cached JSON decodes unchanged). The dashboard prints the
    /// provenance beside every number and never lets a value whose provenance
    /// is not the account's own credentials pose as a measurement — a manual
    /// refresh once stored the ACTIVE account's numbers into another profile
    /// through the system-Keychain fallback, and two accounts showed identical
    /// figures with nothing to say so. Stamped by the header rescue
    /// (`mergingHeaderMeasurement`) and the CLI-cache adoption.
    var provenance: MeasurementProvenance? = nil

    /// Windows whose percentage this value HELD from the previously cached
    /// reading because the fresh payload reported LESS utilization while the
    /// window's own reset boundary was still in the future — see
    /// `reconciledWithPrevious`. nil (or empty) means every window here is as
    /// measured. Optional with nil default so previously cached usage JSON
    /// still decodes (the synthesized decoder uses `decodeIfPresent` for
    /// optionals only, which is why this is not a non-optional `[String]`).
    var heldWindows: [String]? = nil

    /// The held window names, empty when nothing was held.
    var heldWindowNames: [String] { heldWindows ?? [] }

    /// True while an INFERRED (unverified) throttle stamp is live: the account
    /// is SUSPECTED to be rate-limited from behavioral evidence, but the server
    /// never affirmed it. Display surfaces render this as a distinct state
    /// instead of a hard 100%.
    var isSuspectedRateLimited: Bool {
        rateLimitedInferred == true && (rateLimitedUntil.map { $0 > Date() } ?? false)
    }

    /// While reads are failing (suspected state), the best-estimate session
    /// percentage projected forward from the recent MEASURED burn rate —
    /// written by the sweep, cleared automatically by the next successful
    /// fetch (fresh parses carry the nil default). Exists because a frozen
    /// last-measured value under-reports exactly when it matters: 'Commits'
    /// displayed 67% for 22 blind minutes while parallel sessions burned it
    /// to a real 100% (2026-08-12). An estimate from measured burn is honest
    /// where a synthetic 100 was not; the purple suspected marking stays on.
    var projectedSessionPercentage: Double? = nil

    /// What tiles, the popover, and usage notifications DISPLAY. A suspected
    /// (inferred) limit shows the burn-rate PROJECTION when one exists, else
    /// the last MEASURED percentage — never a synthetic 100: a fake 100 on
    /// the tile caused manual account switches costing ~10-15% of every
    /// concurrent session's quota (2026-08-12 incident; the account was
    /// measured at 89% during its own "100%" stamp). The suspected state is
    /// conveyed by COLOR/badge, not by faking certainty. Server-affirmed
    /// stamps still display 100 — the server said the account is out.
    /// Decision seams (auto-switch trigger, candidate gating, scheduler heat)
    /// keep reading `effectiveSessionPercentage`.
    var displaySessionPercentage: Double {
        if isSuspectedRateLimited {
            if let projected = projectedSessionPercentage { return projected }
            return sessionResetTime < Date() ? 0.0 : sessionPercentage
        }
        return effectiveSessionPercentage
    }

    /// False when the PROVIDER has no session-scale window at all — Grok has
    /// always been weekly-only, and Codex became weekly-only when OpenAI
    /// collapsed the old 5h primary / weekly secondary pair into a single
    /// 7-day window (observed live 2026-07-29: primary_window
    /// limit_window_seconds=604800, secondary_window=null). Distinct from
    /// "session at 0%": tiles and popover collapse to ONE gauge when false.
    /// Optional with nil default (nil = has a session window) so previously
    /// cached usage JSON still decodes.
    var hasSessionWindow: Bool? = nil

    /// Convenience: nil means legacy/Claude data — session window exists.
    var providesSessionWindow: Bool { hasSessionWindow ?? true }

    /// How many OpenAI "usage limit resets" (wire name: rate limit reset
    /// credits) the Codex account has available, read out of the SAME
    /// `wham/usage` payload the sweep already fetches — no extra request.
    ///
    /// **nil means UNKNOWN, never zero.** An account with no credits returns
    /// `"rate_limit_reset_credits": null` (verified live 2026-09-03 across all
    /// five local Codex homes), so "absent" and "zero" are indistinguishable
    /// from this endpoint — surfacing a measured "0" would be a claim the
    /// payload does not support. Display a badge only when this is > 0.
    /// Optional with nil default so previously cached usage JSON still decodes.
    var codexResetCreditsAvailable: Int? = nil

    /// When `codexResetCreditsAvailable` was measured. Stamped only alongside a
    /// non-nil count, so a stamp is never evidence about an unknown value.
    /// Optional with nil default so previously cached usage JSON still decodes.
    var codexResetCreditsMeasuredAt: Date? = nil

    // Weekly data (all models)
    var weeklyTokensUsed: Int
    var weeklyLimit: Int
    var weeklyPercentage: Double
    var weeklyResetTime: Date

    // Weekly data (Opus only)
    var opusWeeklyTokensUsed: Int
    var opusWeeklyPercentage: Double

    // Weekly data (Sonnet only)
    var sonnetWeeklyTokensUsed: Int
    var sonnetWeeklyPercentage: Double
    var sonnetWeeklyResetTime: Date?

    // Weekly data (Fable only) — reported via the scoped weekly limit in the
    // `limits` array, not a `seven_day_*` object. Optional with nil defaults so
    // previously cached usage JSON still decodes.
    var fableWeeklyPercentage: Double? = nil
    var fableWeeklyResetTime: Date? = nil

    // Extra usage data
    var costUsed: Double?
    var costLimit: Double?
    var costCurrency: String?

    // Overage credit grant balance
    var overageBalance: Double?
    var overageBalanceCurrency: String?

    // Metadata
    var lastUpdated: Date
    var userTimezone: TimeZone

    /// Remaining percentage (100 - used percentage)
    var remainingPercentage: Double {
        max(0, 100 - effectiveSessionPercentage)
    }

    /// Returns the status level based on remaining percentage (like Mac battery indicator)
    /// DEPRECATED: Use UsageStatusCalculator.calculateStatus() instead for display-aware logic
    /// This property remains for backwards compatibility only
    /// - > 20% remaining: safe (green)
    /// - 10-20% remaining: moderate (orange)
    /// - < 10% remaining: critical (red)
    @available(*, deprecated, message: "Use UsageStatusCalculator.calculateStatus() with showRemaining parameter")
    var statusLevel: UsageStatusLevel {
        switch remainingPercentage {
        case 20...:
            return .safe
        case 10..<20:
            return .moderate
        default:
            return .critical
        }
    }

    /// Empty usage data (used when no data is available)
    static var empty: ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: 0,
            sessionResetTime: Date().addingTimeInterval(5 * 60 * 60),
            weeklyTokensUsed: 0,
            weeklyLimit: 1_000_000,
            weeklyPercentage: 0,
            weeklyResetTime: Date().addingTimeInterval(7 * 24 * 3600),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
    }

    // MARK: - Header-measurement merge

    /// Folds a measurement taken from the Messages API's unified rate-limit
    /// HEADERS onto this (endpoint-derived) usage. The headers report only the
    /// 5-hour session window and the all-models weekly one — they carry no
    /// per-model windows — so a wholesale replace would silently zero the
    /// Fable/Opus/Sonnet weekly percentages that `isQuotaExhausted` and the
    /// candidate headroom checks read, turning a Fable-maxed account into an
    /// apparently healthy switch target. Session/weekly/throttle provenance
    /// come from the fresher header measurement; everything the headers do not
    /// speak to is carried forward from `self`.
    nonisolated func mergingHeaderMeasurement(_ headerUsage: ClaudeUsage) -> ClaudeUsage {
        var merged = self
        merged.sessionPercentage = headerUsage.sessionPercentage
        merged.sessionTokensUsed = headerUsage.sessionTokensUsed
        merged.sessionLimit = headerUsage.sessionLimit
        if headerUsage.sessionResetTime != Self.unknownResetSentinel {
            merged.sessionResetTime = headerUsage.sessionResetTime
        }
        merged.weeklyPercentage = headerUsage.weeklyPercentage
        merged.weeklyTokensUsed = headerUsage.weeklyTokensUsed
        if headerUsage.weeklyResetTime != Self.unknownResetSentinel {
            merged.weeklyResetTime = headerUsage.weeklyResetTime
        }
        // A real measurement supersedes suspicion and any stale projection —
        // same semantics as a successful oauth/usage fetch. A server-affirmed
        // stamp carried by the header response (5h window rejected) survives.
        merged.rateLimitedUntil = headerUsage.rateLimitedUntil
        merged.rateLimitedInferred = headerUsage.rateLimitedInferred
        merged.projectedSessionPercentage = nil
        merged.lastUpdated = headerUsage.lastUpdated
        // Still the account's own credentials, but a different bucket and no
        // per-model windows — the dashboard says so beside the number.
        merged.provenance = .headerRescue
        return merged
    }

    // MARK: - Reset-stamp healing

    /// Sentinel meaning "the API reported this window with no resets_at stamp".
    /// A usage window that rolled over while the account was idle has no active
    /// window, so the endpoint reports zero utilization and OMITS the timestamp.
    /// Parsers store this sentinel instead of inventing a boundary — the old code
    /// guessed "next Monday 12:59pm", which fabricated a phantom soonest-reset
    /// that mis-ranked auto-switch candidates and reshuffled the menu bar
    /// (a real incident: an idle account's weekly rollover made the auto-switch
    /// pick it over the correct candidate).
    nonisolated static let unknownResetSentinel = Date.distantPast

    /// Replaces sentinel reset stamps with values carried forward from the
    /// profile's previously cached usage. Idempotent — healing an already-healed
    /// value is a no-op. Call after every fetch, before display or persistence.
    nonisolated mutating func healMissingResetStamps(previous: ClaudeUsage?, now: Date = Date()) {
        if sessionResetTime == Self.unknownResetSentinel {
            if let prev = previous?.sessionResetTime, prev > now {
                sessionResetTime = prev
            } else {
                // No known active window. A window started by the next request
                // would end 5h out; display-only, replaced by the first fetch
                // that sees real usage.
                sessionResetTime = now.addingTimeInterval(5 * 3600)
            }
        }
        if weeklyResetTime == Self.unknownResetSentinel {
            if let prev = previous?.weeklyResetTime {
                weeklyResetTime = Self.projectedWeeklyBoundary(prev, after: now)
            } else {
                weeklyResetTime = now.addingTimeInterval(7 * 24 * 3600)
            }
        }
        if fableWeeklyPercentage != nil, fableWeeklyResetTime == nil,
           let prev = previous?.fableWeeklyResetTime {
            fableWeeklyResetTime = Self.projectedWeeklyBoundary(prev, after: now)
        }
    }

    /// An account's weekly boundary recurs every 7 days — project a stamp from a
    /// previous window forward to the first occurrence after `now` (same
    /// semantics as Profile.nextWeeklyReset).
    nonisolated static func projectedWeeklyBoundary(_ reset: Date, after now: Date) -> Date {
        var boundary = reset
        while boundary <= now {
            boundary = boundary.addingTimeInterval(7 * 24 * 3600)
        }
        return boundary
    }

    // MARK: - Monotonic windows

    /// Holds each window's percentage at the last server-affirmed value when a
    /// fresh reading claims LESS utilization before that window's reset
    /// boundary has passed.
    ///
    /// A quota window's utilization cannot decrease while the window is still
    /// open, so a sharp drop with the boundary still in the future is a bad
    /// payload, not a measurement. Live incident (2026-09-04 13:06 PDT): the
    /// active Claude owner 'dJormun' was measured at session 56 % / weekly 70 %
    /// / Fable 89 % (own endpoint 13:04:20, header rescue 13:05:21) and then
    /// `oauth/usage` answered HTTP 200 parsing to 0 / 0 / 0. The zeros were
    /// saved over the real numbers and became what `checkAutoSwitchIfNeeded`
    /// read, so the account could never reach the 95 % switch — and because the
    /// header rescue carries no Fable value, a Fable exhaustion would never
    /// have been seen at all.
    ///
    /// Each window is decided INDEPENDENTLY, and a hold requires all of:
    /// `previous` exists, was measured with the account's own credentials
    /// (`.ownEndpoint` / `.headerRescue`; a nil provenance is the legacy
    /// own-endpoint default), the window's previous reset stamp is known and
    /// still in the future at `now`, and the new percentage is lower than the
    /// previous one by more than `tolerance` points. Anything else accepts the
    /// new reading unchanged. A reading is never raised above what was
    /// measured, no reset stamp is invented, and `lastUpdated` always stays the
    /// new reading's.
    ///
    /// Two windows have no reset stamp of their own: the Opus weekly window is
    /// governed by the all-models `weeklyResetTime` (the account's weekly
    /// boundary, which every weekly window shares) and the Sonnet one by
    /// `sonnetWeeklyResetTime` when the payload carried it, else the same
    /// all-models boundary. A window that DISAPPEARS from the payload (Fable
    /// present before, nil now) is not a drop and is never held — an account
    /// that genuinely loses a scoped limit must not be pinned to a stale
    /// percentage for a week.
    nonisolated func reconciledWithPrevious(
        _ previous: ClaudeUsage?,
        now: Date = Date(),
        tolerance: Double = 5
    ) -> (usage: ClaudeUsage, suspectedLow: [String]) {
        var result = self
        result.heldWindows = nil
        guard let previous, Self.isServerAffirmed(previous) else { return (result, []) }

        /// A boundary that is known (not the sentinel) and has NOT passed.
        func boundaryStillOpen(_ stamp: Date?) -> Bool {
            guard let stamp, stamp != Self.unknownResetSentinel else { return false }
            return stamp > now
        }
        func droppedSuspiciously(_ new: Double, _ old: Double) -> Bool {
            old - new > tolerance
        }

        var held: [String] = []

        if boundaryStillOpen(previous.sessionResetTime),
           droppedSuspiciously(sessionPercentage, previous.sessionPercentage) {
            result.sessionPercentage = previous.sessionPercentage
            result.sessionTokensUsed = previous.sessionTokensUsed
            result.sessionResetTime = previous.sessionResetTime
            held.append("session")
        }

        if boundaryStillOpen(previous.weeklyResetTime),
           droppedSuspiciously(weeklyPercentage, previous.weeklyPercentage) {
            result.weeklyPercentage = previous.weeklyPercentage
            result.weeklyTokensUsed = previous.weeklyTokensUsed
            result.weeklyResetTime = previous.weeklyResetTime
            held.append("weekly")
        }

        if let previousFable = previous.fableWeeklyPercentage,
           let newFable = fableWeeklyPercentage,
           boundaryStillOpen(previous.fableWeeklyResetTime),
           droppedSuspiciously(newFable, previousFable) {
            result.fableWeeklyPercentage = previousFable
            result.fableWeeklyResetTime = previous.fableWeeklyResetTime
            held.append("fable")
        }

        // Opus has no reset stamp of its own — the account's weekly boundary is
        // the one its window rides.
        if boundaryStillOpen(previous.weeklyResetTime),
           droppedSuspiciously(opusWeeklyPercentage, previous.opusWeeklyPercentage) {
            result.opusWeeklyPercentage = previous.opusWeeklyPercentage
            result.opusWeeklyTokensUsed = previous.opusWeeklyTokensUsed
            held.append("opus")
        }

        if boundaryStillOpen(previous.sonnetWeeklyResetTime ?? previous.weeklyResetTime),
           droppedSuspiciously(sonnetWeeklyPercentage, previous.sonnetWeeklyPercentage) {
            result.sonnetWeeklyPercentage = previous.sonnetWeeklyPercentage
            result.sonnetWeeklyTokensUsed = previous.sonnetWeeklyTokensUsed
            result.sonnetWeeklyResetTime = previous.sonnetWeeklyResetTime ?? sonnetWeeklyResetTime
            held.append("sonnet")
        }

        result.heldWindows = held.isEmpty ? nil : held
        return (result, held)
    }

    /// True when the value was measured with the ACCOUNT'S OWN credentials, so
    /// it is fit to hold a fresh reading against. A nil provenance is the
    /// legacy own-endpoint default — nothing in the fetch path stamps
    /// `.ownEndpoint` explicitly, so treating nil as unaffirmed would make the
    /// guard above dead code in production.
    nonisolated static func isServerAffirmed(_ usage: ClaudeUsage) -> Bool {
        (usage.provenance ?? .ownEndpoint).isOwnMeasurement
    }

    /// The percentages this value reports for `windows`, rounded, in order —
    /// the "0/0/0" and "56/70/89" halves of the held-reading log line. A window
    /// this value does not report at all prints as "-".
    nonisolated func percentages(for windows: [String]) -> String {
        windows.map { name -> String in
            switch name {
            case "session": return String(Int(sessionPercentage.rounded()))
            case "weekly": return String(Int(weeklyPercentage.rounded()))
            case "fable": return fableWeeklyPercentage.map { String(Int($0.rounded())) } ?? "-"
            case "opus": return String(Int(opusWeeklyPercentage.rounded()))
            case "sonnet": return String(Int(sonnetWeeklyPercentage.rounded()))
            default: return "-"
            }
        }.joined(separator: "/")
    }

}

/// Where a `ClaudeUsage` value came from — the audit trail behind every
/// number the dashboard shows. Only the first two are measurements of THIS
/// account made with THIS account's credentials.
enum MeasurementProvenance: String, Codable, Hashable {
    /// The account's own usage endpoint, its own token.
    case ownEndpoint
    /// The Messages API's rate-limit headers, its own token (the blind-active-
    /// account rescue, #41). Session/weekly only — per-model windows are
    /// carried forward from the previous value.
    case headerRescue
    /// The CLI's own cached usage or transcript event, ATTRIBUTED to this
    /// account by the switch history — not read with its credentials.
    case cliCache

    /// True when the value was measured with the account's own credentials.
    var isOwnMeasurement: Bool {
        switch self {
        case .ownEndpoint, .headerRescue: return true
        case .cliCache: return false
        }
    }
}

/// Usage status level for color coding
/// Thresholds depend on display mode (used vs remaining percentage)
enum UsageStatusLevel: Hashable {
    case safe       // Used mode: 0-50% used | Remaining mode: >20% remaining
    case moderate   // Used mode: 50-80% used | Remaining mode: 10-20% remaining
    case critical   // Used mode: 80-100% used | Remaining mode: <10% remaining
}
