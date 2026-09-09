//
//  WeeklyWindowPriming.swift
//  Claude Usage
//
//  The pure half of weekly-window priming (docs/specs/weekly-window-priming.md).
//
//  A Codex account's weekly window is ROLLING: it opens on the first real
//  request after the previous window ended, and an idle account has no window
//  at all — its next reset is 7 days after whenever the rotation happens to
//  reach it. Priming sends one tiny request the moment the window is seen
//  closed, so the 7-day clock runs while the account idles and its capacity
//  comes back as early as it can. The quota per window is unchanged; only the
//  clock moves earlier.
//
//  Everything here takes `now` and touches no process, network or store:
//  the settings record, the per-profile ledger, the window-state reading of a
//  cached usage, the schedule (jitter, once per window, one retry) and the
//  verification rule. `WeeklyWindowPrimer` runs it; `CodexPrimeCommand` (in
//  the same service file) builds and runs the CLI command.
//
//  Scope: Codex only, by owner decision (2026-09-09). Claude is not primed.
//

import Foundation

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
/// opens when a fetch first shows no window and ends when a fetch shows one
/// again (primed or used by somebody). Attempts count within the episode.
struct WeeklyPrimeRecord: Codable, Equatable {
    enum Outcome: String, Codable {
        /// The verifying fetch reported a window: the reset moved to ≈ now + 7 d.
        case moved
        /// The request ran, the verifying fetch still showed no window.
        case noMovement
        /// `codex exec` did not run to a clean exit.
        case failed
    }

    /// When the closed window was first seen this episode; nil = no episode.
    var episodeObservedAt: Date?
    var attempts: Int
    var lastAttemptAt: Date?
    var lastOutcome: Outcome?
    /// The last attempt's log line ("window reset moved … → …, used 1%").
    var lastDetail: String?
    /// The last prime that opened a window: when it ran, the reset the
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
}

// MARK: - Window state

/// What the last fetch said about a profile's weekly window.
enum WeeklyWindowState: Equatable {
    /// The provider reported a window ending at `resetAt`.
    case open(resetAt: Date)
    /// The provider reported NO window (`ClaudeUsage.weeklyWindowOpen == false`):
    /// the account idled past its reset. Only a request opens the next one.
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
        /// The open window is the one the last prime opened.
        case alreadyPrimed(resetAt: Date)
        case awaitingFetch(resetAt: Date)
        case unknownWindow
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
    /// Returns true when the record changed (the caller persists it).
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

/// What the fetch after a prime proved. "Moved" means the provider now reports
/// a window it did not report before (or a different one): the clock started.
enum WeeklyPrimeVerification {
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
        case .closed: return "no window"
        case .expired(let reset): return "stamp passed \(clock.string(from: reset))"
        case .unknown: return "unknown"
        }
    }

    static func compare(before: ClaudeUsage?, after: ClaudeUsage, provider: Profile.ProviderKind,
                        now: Date, clock: DateFormatter = clock) -> Result {
        let old = WeeklyWindowState.of(before, provider: provider, now: now)
        let new = WeeklyWindowState.of(after, provider: provider, now: now)
        let used = Int(after.weeklyPercentage.rounded())
        guard case .open(let reset) = new else {
            return Result(outcome: .noMovement,
                          detail: "no window movement (\(describe(new, clock: clock)) — semantics differ?)",
                          resetAt: nil, usedPercent: after.weeklyPercentage)
        }
        if case .open(let previous) = old, abs(previous.timeIntervalSince(reset)) <= WeeklyPrimeSchedule.sameWindowTolerance {
            return Result(outcome: .noMovement,
                          detail: "window already open (\(describe(new, clock: clock)), used \(used)%)",
                          resetAt: reset, usedPercent: after.weeklyPercentage)
        }
        let from: String
        switch old {
        case .open(let previous): from = clock.string(from: previous)
        case .closed: from = "none"
        case .expired(let previous): from = clock.string(from: previous) + " (passed)"
        case .unknown: from = "unknown"
        }
        return Result(outcome: .moved,
                      detail: "window reset moved \(from) → \(clock.string(from: reset)), used \(used)%",
                      resetAt: reset, usedPercent: after.weeklyPercentage)
    }

    /// Books one attempt. A move also records the window it opened, which is
    /// what keeps the next tick from priming it again (`alreadyPrimed`).
    static func record(_ result: Result, into record: inout WeeklyPrimeRecord, now: Date) {
        record.attempts += 1
        record.lastAttemptAt = now
        record.lastOutcome = result.outcome
        record.lastDetail = result.detail
        guard result.outcome == .moved else { return }
        record.lastPrimedAt = now
        record.primedForWindowEndingAt = result.resetAt
        record.lastVerifiedUsedPercent = result.usedPercent
    }
}
