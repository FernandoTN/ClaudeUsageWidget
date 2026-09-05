import Foundation

/// The quota window a Claude Code rate-limit message names. A running
/// session dies on the API's 429 for ONE window, and the widget's answer —
/// whose event it is, whether a live read contradicts it, which number to
/// stamp — must be that window's, not the session's (2026-09-05 15:47: four
/// transcripts said "You've reached your Fable limit" while 'Memori' sat at
/// session 89 % / Fable 100 %, and the session read "contradicted" a genuine
/// Fable hit).
///
/// Shapes in 21 days of transcripts and the CLI 2.1.261 string table:
///
///     You've hit your session limit · resets 2:50am (Zone)            session
///     You've hit your weekly limit · resets Aug 22 at 3pm (Zone)      weekly
///     You've reached your Fable 5 limit. Run /usage-credits …         fableWeekly (no reset in the text)
///     You've hit your Fable 5 limit · resets Sep 5 at 9pm (Zone)      fableWeekly
///
/// Anything else — including the other named-model limits the catalogue
/// carries ("Sonnet limit") for which the widget tracks no decision-grade
/// window — is `unknown`, handled exactly as every event was before the
/// window existed: matched against the session stamp, else by the clock.
///
/// `nonisolated` for the same reason as `LocalLimitSignalService`: read off
/// the main actor by the transcript scan.
nonisolated enum LimitWindow: String, Codable, Hashable, Sendable {
    case session
    case weekly
    case fableWeekly
    case unknown

    /// The word in log lines: "transcript says FABLE limit".
    var logLabel: String {
        switch self {
        case .session: return "SESSION"
        case .weekly: return "WEEKLY"
        case .fableWeekly: return "FABLE"
        case .unknown: return "UNKNOWN"
        }
    }

    /// The word in a dashboard row: "Fable 429 contradicted". An unknown
    /// window says so rather than posing as the session it is handled as.
    var rowWord: String {
        switch self {
        case .session: return "session"
        case .weekly: return "weekly"
        case .fableWeekly: return "Fable"
        case .unknown: return "unknown-window"
        }
    }

    /// Weekly-scale windows are gated by the weekly threshold (default 99 %,
    /// tighter because forfeited weekly quota is gone until the reset).
    var isWeeklyScale: Bool { self == .weekly || self == .fableWeekly }

    func threshold(_ thresholds: ReadinessThresholds) -> Double {
        isWeeklyScale ? thresholds.weekly : thresholds.session
    }
}

extension ClaudeUsage {
    /// The window's percentage as the decision seams read it: the session's
    /// through the affirmed-stamp seam and 0 once its window rolled over, a
    /// weekly one 0 once its boundary passed, nil when the account reports no
    /// such window at all (Fable) — no number is not a low number.
    nonisolated func percentage(of window: LimitWindow, now: Date = Date()) -> Double? {
        switch window {
        case .session, .unknown:
            if let until = rateLimitedUntil, until > now { return max(sessionPercentage, 100) }
            return sessionResetTime < now ? 0 : sessionPercentage
        case .weekly:
            return weeklyResetTime >= now ? weeklyPercentage : 0
        case .fableWeekly:
            guard let fable = fableWeeklyPercentage else { return nil }
            return (fableWeeklyResetTime.map { $0 >= now } ?? true) ? fable : 0
        }
    }

    /// The window's cached boundary; nil for an unreported one.
    nonisolated func resetTime(of window: LimitWindow) -> Date? {
        switch window {
        case .session, .unknown: return sessionResetTime
        case .weekly: return weeklyResetTime == Self.unknownResetSentinel ? nil : weeklyResetTime
        case .fableWeekly: return fableWeeklyResetTime
        }
    }

    /// Records a server-affirmed hit of ONE window — a running session died
    /// on the API's 429 naming it. Only that window moves: it reads 100 (the
    /// server's own statement, the value the affirmed session stamp has
    /// always reported) and takes the text's reset when the text carried one.
    /// No reset is recorded as no reset: the old 30-minute session placeholder
    /// was a synthetic boundary that fed stamp matching and "capacity returns"
    /// with a time nobody measured. Readiness, the dot colour, the dashboard
    /// bands and `isQuotaExhausted` all read these fields, so a Fable hit now
    /// blocks the account as a Fable hit, with the Fable reset as its relief.
    nonisolated mutating func stampLimitHit(_ window: LimitWindow, at eventTime: Date, resetsAt: Date?) {
        switch window {
        case .session, .unknown:
            rateLimitedUntil = resetsAt
            rateLimitedInferred = nil
            projectedSessionPercentage = nil
            if let resetsAt {
                sessionResetTime = resetsAt
            } else {
                sessionPercentage = max(sessionPercentage, 100)
            }
        case .weekly:
            weeklyPercentage = max(weeklyPercentage, 100)
            if let resetsAt {
                weeklyResetTime = resetsAt
                weeklyResetProjected = nil
            }
        case .fableWeekly:
            fableWeeklyPercentage = max(fableWeeklyPercentage ?? 0, 100)
            if let resetsAt {
                fableWeeklyResetTime = resetsAt
                fableWeeklyResetProjected = nil
            }
        }
        lastUpdated = eventTime
    }
}
