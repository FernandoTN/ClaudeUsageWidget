import Foundation

/// Attributes a transcript rate-limit event ("You've hit your session limit ·
/// resets 3:40am", "You've reached your Fable limit") to the account whose
/// window it names, and decides whether the auto-switch may act on it.
///
/// Why the wall clock is not enough (2026-09-04, 22:53): running Claude Code
/// sessions keep the PREVIOUS owner's token in memory for a while after a
/// switch — their in-flight and immediately following requests still hit the
/// old account — so for a window after every switch, transcript 429s belong to
/// the OUTGOING owner. The widget switched 'dFr(fermin-dev)' → 'dJormun' at
/// 22:52:45; three of dFr's sessions died at 22:53:35–40 on "resets 3:40am";
/// the widget blamed dJormun (measured at 22% in the same second), switched
/// again one minute later, abandoned a fresh window and landed the whole
/// fleet's context re-read on 'Google' (0→58% in 4 min).
///
/// The evidence the event carries is its reset time: the 5-hour window end,
/// which the usage endpoint reports per account as `sessionResetTime`
/// (03:39:59 for dFr, 03:49:59 for dJormun — the transcript text rounds it to
/// the minute). Matching that stamp is attribution by evidence; the wall clock
/// is only the fallback when nobody has a stamp, and even then the current
/// owner is re-measured live before a switch is allowed.
///
/// Every step is WINDOW-AWARE (2026-09-05 15:47): 'Memori' at session 89 % /
/// Fable 100 % had four sessions die on "You've reached your Fable limit";
/// the session read "contradicted" a genuine Fable hit, and the fallback
/// stamped it as a session limit with a 30-minute placeholder reset. The
/// window the text names (`LimitWindow`) picks the stamp compared
/// (`weeklyResetTime`, `fableWeeklyResetTime`), and the Fable text carries no
/// reset at all, so there the evidence is the window's STATE: the owner whose
/// Fable window already reads at the limit.
///
/// `nonisolated` for the same reason as `LocalLimitSignalService`: pure
/// functions, callable from anywhere, testable without a main actor.
nonisolated enum TranscriptLimitAttribution {

    /// Reset stamps within this distance of the event's parsed reset time name
    /// the same window. The endpoint reports xx:x9:59.889 where the transcript
    /// says "xx:(x+1)0" — one second — but the widget's stamp may also be a
    /// header-derived or CLI-cached boundary a few seconds off, and two
    /// accounts' windows are never this close by accident.
    static let resetMatchTolerance: TimeInterval = 180

    /// How far back a former owner still counts as a candidate. A session
    /// holding a stale token for longer than this is not the pattern seen.
    static let previousOwnerLookback: TimeInterval = 15 * 60

    /// Belt and braces: for this long after a switch, a transcript event whose
    /// reset does not match the NEW owner's window is never actionable, even
    /// when no stamp says whose it is.
    static let postSwitchGrace: TimeInterval = 120

    /// Attribution by window state reads "at the limit" as the window's
    /// auto-switch threshold, capped here: the weekly default is 99 %, and a
    /// Fable window measured at 97 % a sweep ago is the owner a Fable 429
    /// names far more plausibly than one at 40 %. Attribution only — whether
    /// the account really is out is the live corroboration's call.
    static let windowStateFloor: Double = 95

    /// One owner as the attribution sees it: the cached windows the event
    /// may name.
    struct Candidate: Equatable, Sendable {
        let id: UUID
        let name: String
        /// The account's cached 5-hour window end; nil when never measured.
        let sessionResetTime: Date?
        /// The cached session percentage that came with the stamp.
        let sessionPercentage: Double
        /// The all-models weekly window (nil boundary = unreported).
        var weeklyResetTime: Date? = nil
        var weeklyPercentage: Double = 0
        /// The Fable weekly window; nil percentage = the account reports none.
        var fableWeeklyResetTime: Date? = nil
        var fableWeeklyPercentage: Double? = nil

        /// The window's raw cached boundary, for log lines.
        func resetTime(of window: LimitWindow) -> Date? {
            switch window {
            case .session, .unknown: return sessionResetTime
            case .weekly: return weeklyResetTime
            case .fableWeekly: return fableWeeklyResetTime
            }
        }

        /// The window's cached percentage while its boundary is still ahead
        /// of the event (a Fable window with no boundary counts, as readiness
        /// reads it); nil when there is no such window or it rolled over.
        func percentage(of window: LimitWindow, at eventTime: Date) -> Double? {
            switch window {
            case .session, .unknown:
                return (sessionResetTime.map { $0 > eventTime } ?? false) ? sessionPercentage : nil
            case .weekly:
                return (weeklyResetTime.map { $0 > eventTime } ?? false) ? weeklyPercentage : nil
            case .fableWeekly:
                guard let fable = fableWeeklyPercentage else { return nil }
                return (fableWeeklyResetTime.map { $0 > eventTime } ?? true) ? fable : nil
            }
        }

        /// The stamp as EVIDENCE: only a window still open at the event with
        /// measured usage in it. A stamp in the past belongs to a window that
        /// has since rolled over (the account may be in a new, unmeasured one),
        /// and a healed boundary pairs with 0 % (`ClaudeUsage.
        /// healMissingResetStamps`) — neither says which account a 429 hit.
        func measuredWindowEnd(of window: LimitWindow, at eventTime: Date) -> Date? {
            guard let stamp = resetTime(of: window), stamp > eventTime,
                  (percentage(of: window, at: eventTime) ?? 0) > 0 else { return nil }
            return stamp
        }
    }

    enum Basis: String, Sendable {
        case resetMatch = "reset match"
        /// The text carried no reset; the owner's matching window already
        /// read at the limit.
        case windowState = "window state"
        case clock = "clock"
    }

    enum Verdict: Equatable, Sendable {
        /// The window names a former owner's: record the hit against it and
        /// never switch — the current owner was not the account refused.
        case previousOwner(Candidate)
        /// The current owner's — by reset match, by window state, or by the
        /// clock when nothing identifies the window. Corroborate live before
        /// switching.
        case currentOwner(Candidate, basis: Basis)
        /// Within `postSwitchGrace` of the switch and not the new owner's
        /// window: never actionable.
        case postSwitchGrace(newOwner: Candidate)
        /// The current owner's measured window disagrees and no recent former
        /// owner matches: the 429 hit an account the widget does not track as
        /// an owner — not actionable.
        case unmatched(currentOwner: Candidate)
    }

    /// Resolves whose window the event names. `window` picks the stamps and
    /// percentages compared (`.unknown` reads the session's, as every event
    /// did before the window existed); `previousOwners` are the outgoing
    /// owners of the recent switches, most recent first
    /// (`previousOwnerNames`); `lastSwitchAt` is the grace clock
    /// (`lastClaudeSwitchAt`); `thresholds` only matter when the text
    /// carried no reset.
    static func resolve(
        eventAt: Date,
        eventResetsAt: Date?,
        window: LimitWindow,
        currentOwner: Candidate,
        previousOwners: [Candidate],
        lastSwitchAt: Date?,
        thresholds: ReadinessThresholds
    ) -> Verdict {
        func matches(_ candidate: Candidate) -> Bool {
            guard let reset = eventResetsAt,
                  let windowEnd = candidate.measuredWindowEnd(of: window, at: eventAt) else { return false }
            return abs(windowEnd.timeIntervalSince(reset)) <= resetMatchTolerance
        }
        // The current owner first: when both windows match (two accounts
        // whose windows opened within minutes of each other), the live
        // corroboration on the current owner is the tie-breaker — it switches
        // only if that account really is out.
        if matches(currentOwner) {
            return .currentOwner(currentOwner, basis: .resetMatch)
        }
        if let previous = previousOwners.first(where: matches) {
            return .previousOwner(previous)
        }
        // No reset in the text (the Fable message never carries one): the
        // named window's STATE is the evidence — whichever owner's matching
        // window already reads at the limit. Same order as the reset match.
        if eventResetsAt == nil, window != .unknown {
            let limit = min(window.threshold(thresholds), windowStateFloor)
            func atLimit(_ candidate: Candidate) -> Bool {
                (candidate.percentage(of: window, at: eventAt) ?? -1) >= limit
            }
            if atLimit(currentOwner) {
                return .currentOwner(currentOwner, basis: .windowState)
            }
            if let previous = previousOwners.first(where: atLimit) {
                return .previousOwner(previous)
            }
        }
        let inGrace = lastSwitchAt.map {
            eventAt >= $0 && eventAt.timeIntervalSince($0) < postSwitchGrace
        } ?? false
        if inGrace {
            return .postSwitchGrace(newOwner: currentOwner)
        }
        if eventResetsAt != nil, currentOwner.measuredWindowEnd(of: window, at: eventAt) != nil {
            return .unmatched(currentOwner: currentOwner)
        }
        return .currentOwner(currentOwner, basis: .clock)
    }

    // MARK: - Live corroboration

    /// What a live re-measure of the blamed current owner said about the
    /// window the event named.
    enum Corroboration: Equatable, Sendable {
        /// At or over the window's threshold (or server-stamped): the event
        /// may drive a switch.
        case confirmed(percent: Double)
        /// Headroom in THAT window: the event is not this account's — no
        /// switch.
        case contradicted(percent: Double)
        /// Neither the endpoint nor the header probe answered for that
        /// window: the transcript 429 stands as the only evidence, as it did
        /// before this rule.
        case unavailable
    }

    /// Compares the live reading's MATCHING window with its threshold. A
    /// header-rescued reading carries no per-model windows — its Fable number
    /// is the stored one carried forward (`mergingHeaderMeasurement`), so for
    /// a Fable event it is no reading at all; contradicting on it is exactly
    /// the 15:47 dismissal.
    static func corroborate(
        live: ClaudeUsage?,
        window: LimitWindow,
        thresholds: ReadinessThresholds,
        now: Date = Date()
    ) -> Corroboration {
        guard let live else { return .unavailable }
        if window == .fableWeekly, live.provenance == .headerRescue { return .unavailable }
        guard let percent = live.percentage(of: window, now: now) else { return .unavailable }
        return percent >= window.threshold(thresholds)
            ? .confirmed(percent: percent)
            : .contradicted(percent: percent)
    }

    // MARK: - Switch-history helpers

    /// Outgoing owners of the Claude switches in the `previousOwnerLookback`
    /// before the event, most recent first, without duplicates and without
    /// the owner at event time. Codex and Grok rows share the ring and are
    /// skipped by the name filter.
    static func previousOwnerNames(
        history: [SwitchEvent],
        eventTime: Date,
        claudeProfileNames: Set<String>,
        excluding ownerName: String
    ) -> [String] {
        var seen: Set<String> = [ownerName]
        var names: [String] = []
        let recent = history
            .filter { $0.at <= eventTime && eventTime.timeIntervalSince($0.at) <= previousOwnerLookback }
            .sorted { $0.at > $1.at }
        for row in recent where claudeProfileNames.contains(row.from) && !seen.contains(row.from) {
            seen.insert(row.from)
            names.append(row.from)
        }
        return names
    }

    /// The most recent Claude switch at or before the event — the grace clock.
    static func lastClaudeSwitchAt(
        history: [SwitchEvent],
        before eventTime: Date,
        claudeProfileNames: Set<String>
    ) -> Date? {
        history
            .filter { $0.at <= eventTime && claudeProfileNames.contains($0.to) }
            .map(\.at)
            .max()
    }
}
