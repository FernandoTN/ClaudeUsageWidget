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

}

/// Usage status level for color coding
/// Thresholds depend on display mode (used vs remaining percentage)
enum UsageStatusLevel {
    case safe       // Used mode: 0-50% used | Remaining mode: >20% remaining
    case moderate   // Used mode: 50-80% used | Remaining mode: 10-20% remaining
    case critical   // Used mode: 80-100% used | Remaining mode: <10% remaining
}
