//
//  WeeklyWindowPriming.swift
//  Claude Usage
//
//  The pure half of weekly-window priming (docs/specs/weekly-window-priming.md).
//
//  A Codex account's weekly window is ROLLING: it opens on the first real
//  request after the previous window ended. An idle account is reported with
//  a PLACEHOLDER window — 0 %, reset_after == limit_window_seconds, reset_at
//  exactly now + 7 d and advancing with every poll — so its next reset lands
//  7 days after whenever the rotation happens to reach it. Priming sends one
//  tiny request the moment the window is seen closed, so the 7-day clock runs
//  while the account idles and its capacity comes back as early as it can.
//  The quota per window is unchanged; only the clock moves earlier.
//
//  Everything here takes `now` and touches no process, network or store:
//  the placeholder rule, the settings record, the per-profile ledger, the
//  window-state reading of a cached usage, the schedule (jitter, once per
//  window, one retry) and the verification rule. `WeeklyWindowPrimer` runs
//  it; `CodexPrimeCommand` (in the same service file) builds and runs the CLI
//  command.
//
//  Scope: Codex only, by owner decision (2026-09-09). Claude is not primed.
//

import Foundation

// MARK: - The placeholder rule

/// How an idle Codex account tells itself apart from one whose window runs.
/// Verified with each account's own token, 2026-09-09 09:12: idle
/// `used_percent 0, reset_after_seconds 604800 == limit_window_seconds,
/// reset_at = now + 604800` (advancing every poll); active `28 %,
/// reset_after 582757`; exhausted `100 %, reset_after 466209,
/// limit_reached`. A running window's `reset_after` counts down and its
/// `reset_at` never moves; a placeholder's `reset_after` stays at the window
/// length and its `reset_at` follows the clock.
nonisolated enum CodexWindowPlaceholder {
    /// How far below the window length `reset_after` may sit and still read
    /// as a placeholder (server-side rounding); past it the clock is running.
    static let tolerance: TimeInterval = 120
    /// A reported reset that moved this much between polls is a placeholder's.
    static let driftTolerance: TimeInterval = 60
    /// The window length assumed when the payload carries none.
    static let defaultWindowSeconds: TimeInterval = 7 * 24 * 3600

    /// The parser-level rule: nothing used AND `reset_after` (or `reset_at −
    /// now`) within `tolerance` of the window length.
    static func isPlaceholder(usedPercent: Double, resetAfter: TimeInterval?, resetAt: Date?,
                              windowSeconds: TimeInterval?, now: Date) -> Bool {
        guard usedPercent <= 0 else { return false }
        let window = windowSeconds ?? defaultWindowSeconds
        let remaining = resetAfter ?? resetAt?.timeIntervalSince(now)
        guard let remaining else { return false }
        return remaining >= window - tolerance
    }

    /// The poll-to-poll cross-check: nothing used AND the reported reset
    /// advanced by at least `driftTolerance` since the previous REPORTED one.
    static func advanced(previousReset: Date, previousReported: Bool, reset: Date, usedPercent: Double) -> Bool {
        guard usedPercent <= 0, previousReported, previousReset != ClaudeUsage.unknownResetSentinel,
              reset != ClaudeUsage.unknownResetSentinel else { return false }
        return reset.timeIntervalSince(previousReset) >= driftTolerance
    }

    /// Seconds until the reported reset as of the fetch — `reset_after`
    /// reconstructed from the stored stamps.
    static func resetAfter(of usage: ClaudeUsage) -> TimeInterval {
        usage.weeklyResetTime.timeIntervalSince(usage.lastUpdated)
    }
}

// MARK: - Settings (`weeklyPrimePolicy_v1`)

/// What the owner allows. An absent key decodes to this default — Codex
/// priming ON, nobody excluded — so an install that never opened the toggle
/// primes. `neverPrime` is the per-account exclusion list ("Never prime").
struct WeeklyPrimePolicy: Codable, Equatable {
    var codexEnabled: Bool
    var neverPrime: [UUID]

    /// The providers priming exists for. Claude is out of scope by owner
    /// decision; Grok's window semantics are unknown. Neither has a toggle.
    static let supportedProviders: Set<Profile.ProviderKind> = [.codex]

    static func supports(_ provider: Profile.ProviderKind) -> Bool {
        supportedProviders.contains(provider)
    }

    func isEnabled(for provider: Profile.ProviderKind) -> Bool {
        switch provider {
        case .codex: return codexEnabled
        case .claude, .grok: return false
        }
    }

    init(codexEnabled: Bool = true, neverPrime: [UUID] = []) {
        self.codexEnabled = codexEnabled
        self.neverPrime = neverPrime
    }

    private enum CodingKeys: String, CodingKey { case codexEnabled, neverPrime }

    /// Field by field with defaults: a key an older build never wrote must not
    /// fail the whole record back to the default and drop the exclusions.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codexEnabled = try container.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? true
        neverPrime = try container.decodeIfPresent([UUID].self, forKey: .neverPrime) ?? []
    }
}

// MARK: - Ledger (`weeklyPrimeLedger_v1`)

/// One profile's priming bookkeeping. An EPISODE is one closed window: it
/// opens when a fetch first shows the window closed and ends when a fetch
/// shows it running (primed, or used by somebody). Attempts count within the
/// episode.
struct WeeklyPrimeRecord: Codable, Equatable {
    enum Outcome: String, Codable {
        /// `codex exec` exited cleanly; the next fetches decide whether the
        /// clock started (a fetch inside the placeholder tolerance still reads
        /// closed, so verification cannot be immediate).
        case sent
        /// A later fetch showed the window running: the clock started.
        case moved
        /// The request ran and the window still read closed after the grace.
        case noMovement
        /// `codex exec` did not run to a clean exit.
        case failed
    }

    /// When the closed window was first seen this episode; nil = no episode.
    var episodeObservedAt: Date?
    var attempts: Int
    var lastAttemptAt: Date?
    var lastOutcome: Outcome?
    /// The last attempt's log line ("window started: reset_after 604800 → 604650 s").
    var lastDetail: String?
    /// The last prime that started a window: when it ran, the reset the
    /// verifying fetch reported — the window it is "primed for" — and the used
    /// percentage that fetch read. Measured values, never synthetic.
    var lastPrimedAt: Date?
    var primedForWindowEndingAt: Date?
    var lastVerifiedUsedPercent: Double?

    init(episodeObservedAt: Date? = nil, attempts: Int = 0, lastAttemptAt: Date? = nil,
         lastOutcome: Outcome? = nil, lastDetail: String? = nil, lastPrimedAt: Date? = nil,
         primedForWindowEndingAt: Date? = nil, lastVerifiedUsedPercent: Double? = nil) {
        self.episodeObservedAt = episodeObservedAt
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.lastOutcome = lastOutcome
        self.lastDetail = lastDetail
        self.lastPrimedAt = lastPrimedAt
        self.primedForWindowEndingAt = primedForWindowEndingAt
        self.lastVerifiedUsedPercent = lastVerifiedUsedPercent
    }

    private enum CodingKeys: String, CodingKey {
        case episodeObservedAt, attempts, lastAttemptAt, lastOutcome, lastDetail
        case lastPrimedAt, primedForWindowEndingAt, lastVerifiedUsedPercent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeObservedAt = try c.decodeIfPresent(Date.self, forKey: .episodeObservedAt)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastOutcome = try c.decodeIfPresent(Outcome.self, forKey: .lastOutcome)
        lastDetail = try c.decodeIfPresent(String.self, forKey: .lastDetail)
        lastPrimedAt = try c.decodeIfPresent(Date.self, forKey: .lastPrimedAt)
        primedForWindowEndingAt = try c.decodeIfPresent(Date.self, forKey: .primedForWindowEndingAt)
        lastVerifiedUsedPercent = try c.decodeIfPresent(Double.self, forKey: .lastVerifiedUsedPercent)
    }

    /// A prime whose verification is still riding the fetches.
    var isAwaitingVerification: Bool { lastOutcome == .sent }
}

// MARK: - Window state

/// What the last fetch said about a profile's weekly window.
enum WeeklyWindowState: Equatable {
    /// The provider reported a running window ending at `resetAt`.
    case open(resetAt: Date)
    /// The window is CLOSED (`ClaudeUsage.weeklyWindowOpen == false`): the
    /// account idled past its reset. Only a request opens the next one.
    case closed
    /// The cached stamp has passed and nothing has been fetched since — the
    /// next fetch says whether the window closed or a new one opened.
    case expired(resetAt: Date)
    /// Never measured, no stamp, a projected stamp, or an unsupported provider.
    case unknown

    static func of(_ usage: ClaudeUsage?, provider: Profile.ProviderKind, now: Date) -> WeeklyWindowState {
        guard WeeklyPrimePolicy.supports(provider), let usage else { return .unknown }
        if usage.weeklyWindowOpen == false { return .closed }
        let reset = usage.weeklyResetTime
        // A boundary the healer projected is not a window the provider
        // reported — never a reason to do, or skip, anything.
        guard reset != ClaudeUsage.unknownResetSentinel, usage.weeklyResetProjected != true else { return .unknown }
        return reset > now ? .open(resetAt: reset) : .expired(resetAt: reset)
    }
}

// MARK: - Schedule

/// The facts the schedule reads for one profile.
struct WeeklyPrimeCandidate: Equatable {
    var id: UUID
    var name: String
    var provider: Profile.ProviderKind
    var hasCredentials: Bool
    /// The provider's active owner — being used anyway, never primed.
    var isOwner: Bool
    var isDead: Bool
    var usage: ClaudeUsage?
}

enum WeeklyPrimeVerdict: Equatable {
    enum Wait: Equatable {
        case windowOpen(resetAt: Date)
        /// The running window is the one the last prime started.
        case alreadyPrimed(resetAt: Date)
        case awaitingFetch(resetAt: Date)
        case unknownWindow
        /// A request was sent; the next fetches decide whether the clock started.
        case verifying(since: Date)
        /// Both attempts of this episode are spent; the next window gets two more.
        case attemptsExhausted
    }

    enum Exclusion: Equatable {
        case providerUnsupported, providerOff, neverPrime, owner, deadLogin, noCredentials
    }

    /// Prime once `now >= at` ("prime pending" until then).
    case due(at: Date)
    case waiting(Wait)
    case excluded(Exclusion)

    var isPending: Bool {
        if case .due = self { return true }
        return false
    }
}

enum WeeklyPrimeSchedule {
    /// A prime lands 2–10 minutes after the window is first seen closed — soon
    /// enough that the clock runs while the account idles, spread enough that
    /// a fleet whose windows all closed together never fires as one burst.
    static let minDelay: TimeInterval = 2 * 60
    static let maxDelay: TimeInterval = 10 * 60
    /// One retry per episode, half an hour after the failure.
    static let retryDelay: TimeInterval = 30 * 60
    static let maxAttemptsPerEpisode = 2
    /// Two stamps this close are the same window (the API jitters by ±1 s).
    static let sameWindowTolerance: TimeInterval = 2 * 60

    /// Deterministic jitter in [minDelay, maxDelay] from the profile id and the
    /// episode start, so the due time is the same on every tick and after a
    /// relaunch without being stored. FNV-1a over the id's bytes and the
    /// episode's epoch second — `Hasher` is seeded per process and would not do.
    static func jitter(profileId: UUID, episodeObservedAt: Date) -> TimeInterval {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        withUnsafeBytes(of: profileId.uuid) { $0.forEach(mix) }
        withUnsafeBytes(of: Int64(episodeObservedAt.timeIntervalSince1970).bigEndian) { $0.forEach(mix) }
        let span = UInt64(maxDelay - minDelay) + 1
        return minDelay + TimeInterval(hash % span)
    }

    /// Opens or ends the record's episode from what the last fetch showed.
    /// Returns true when the record changed (the caller persists it). A sent
    /// prime keeps its episode: the window reads closed until the clock has
    /// run past the placeholder tolerance, and that is not a new window.
    static func observe(_ state: WeeklyWindowState, record: inout WeeklyPrimeRecord, now: Date) -> Bool {
        switch state {
        case .closed:
            guard record.episodeObservedAt == nil else { return false }
            record.episodeObservedAt = now
            record.attempts = 0
            record.lastAttemptAt = nil
            return true
        case .open:
            guard record.episodeObservedAt != nil else { return false }
            record.episodeObservedAt = nil
            record.attempts = 0
            record.lastAttemptAt = nil
            return true
        case .expired, .unknown:
            return false
        }
    }

    static func verdict(_ candidate: WeeklyPrimeCandidate, policy: WeeklyPrimePolicy,
                        record: WeeklyPrimeRecord, now: Date) -> WeeklyPrimeVerdict {
        guard WeeklyPrimePolicy.supports(candidate.provider) else { return .excluded(.providerUnsupported) }
        guard candidate.hasCredentials else { return .excluded(.noCredentials) }
        if candidate.isDead { return .excluded(.deadLogin) }
        if candidate.isOwner { return .excluded(.owner) }
        guard policy.isEnabled(for: candidate.provider) else { return .excluded(.providerOff) }
        if policy.neverPrime.contains(candidate.id) { return .excluded(.neverPrime) }
        if record.isAwaitingVerification, let since = record.lastAttemptAt { return .waiting(.verifying(since: since)) }

        switch WeeklyWindowState.of(candidate.usage, provider: candidate.provider, now: now) {
        case .open(let reset):
            if let primed = record.primedForWindowEndingAt,
               abs(primed.timeIntervalSince(reset)) <= sameWindowTolerance {
                return .waiting(.alreadyPrimed(resetAt: reset))
            }
            return .waiting(.windowOpen(resetAt: reset))
        case .expired(let reset):
            return .waiting(.awaitingFetch(resetAt: reset))
        case .unknown:
            return .waiting(.unknownWindow)
        case .closed:
            if record.attempts >= maxAttemptsPerEpisode { return .waiting(.attemptsExhausted) }
            if record.attempts > 0, let last = record.lastAttemptAt {
                return .due(at: last.addingTimeInterval(retryDelay))
            }
            let episode = record.episodeObservedAt ?? now
            return .due(at: episode.addingTimeInterval(jitter(profileId: candidate.id, episodeObservedAt: episode)))
        }
    }
}

// MARK: - Verification

/// What the fetches after a prime prove. A fetch inside the placeholder
/// tolerance still reads the window as closed (reset_after has only dropped
/// by the seconds since the request), so a sent prime is booked as `sent`
/// and resolved by a LATER fetch: "moved" when the window reads running —
/// `reset_after` below the window length by more than the tolerance, or a
/// non-zero used percentage — "no movement" when it still reads closed after
/// `grace`.
enum WeeklyPrimeVerification {
    /// How long a sent prime may keep reading closed before it counts as no
    /// movement. Codex profiles are fetched every sweep, so the clock shows
    /// within ~3 minutes when it started at all.
    static let grace: TimeInterval = 10 * 60

    struct Result: Equatable {
        var outcome: WeeklyPrimeRecord.Outcome
        var detail: String
        var resetAt: Date?
        var usedPercent: Double?
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    static func describe(_ state: WeeklyWindowState, clock: DateFormatter = clock) -> String {
        switch state {
        case .open(let reset): return "resets \(clock.string(from: reset))"
        case .closed: return "no window (idle)"
        case .expired(let reset): return "stamp passed \(clock.string(from: reset))"
        case .unknown: return "unknown"
        }
    }

    /// Books a clean `codex exec` exit: one attempt, outcome `sent`.
    static func recordSent(into record: inout WeeklyPrimeRecord, now: Date) {
        record.attempts += 1
        record.lastAttemptAt = now
        record.lastOutcome = .sent
        record.lastDetail = "request sent; the next fetches verify the clock started"
    }

    /// Books a run that did not exit cleanly: one attempt, outcome `failed`.
    static func recordFailure(_ detail: String, into record: inout WeeklyPrimeRecord, now: Date) {
        record.attempts += 1
        record.lastAttemptAt = now
        record.lastOutcome = .failed
        record.lastDetail = detail
    }

    /// Reads a later fetch against a sent prime. nil = nothing to conclude
    /// yet (no fetch since the request, or still inside the grace).
    static func resolve(sent record: WeeklyPrimeRecord, usage: ClaudeUsage?, provider: Profile.ProviderKind,
                        now: Date, clock: DateFormatter = clock) -> Result? {
        guard record.isAwaitingVerification, let sentAt = record.lastAttemptAt,
              let usage, usage.lastUpdated > sentAt else { return nil }
        let state = WeeklyWindowState.of(usage, provider: provider, now: now)
        let used = Int(usage.weeklyPercentage.rounded())
        switch state {
        case .open(let reset):
            let window = Int(usage.weeklyWindowSeconds ?? CodexWindowPlaceholder.defaultWindowSeconds)
            let after = Int(CodexWindowPlaceholder.resetAfter(of: usage).rounded())
            return Result(outcome: .moved,
                          detail: "window started: reset_after \(window) → \(after) s, resets \(clock.string(from: reset)), used \(used)%",
                          resetAt: reset, usedPercent: usage.weeklyPercentage)
        case .closed, .expired, .unknown:
            guard now.timeIntervalSince(sentAt) >= grace else { return nil }
            return Result(outcome: .noMovement,
                          detail: "no window movement \(Int(grace / 60)) min after the request (\(describe(state, clock: clock)) — semantics differ?)",
                          resetAt: nil, usedPercent: usage.weeklyPercentage)
        }
    }

    /// Books a resolution. The attempt was counted when the request was sent;
    /// a move also records the window it started, which is what keeps the
    /// next tick from priming it again (`alreadyPrimed`).
    static func record(_ result: Result, into record: inout WeeklyPrimeRecord) {
        record.lastOutcome = result.outcome
        record.lastDetail = result.detail
        guard result.outcome == .moved else { return }
        record.lastPrimedAt = record.lastAttemptAt
        record.primedForWindowEndingAt = result.resetAt
        record.lastVerifiedUsedPercent = result.usedPercent
    }
}
