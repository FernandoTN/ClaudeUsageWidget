//
//  CodexResetCredits.swift
//  Claude Usage
//
//  OpenAI Codex "usage limit resets" — rate limit reset credits in the wire
//  vocabulary. Three seams, deliberately separated by cost:
//
//  1. COUNT — free. It rides along in the `wham/usage` payload the sweep
//     already fetches (`ClaudeUsage.codexResetCreditsAvailable`, parsed in
//     `CodexUsageService.parseUsageResponse`). No extra request, no new
//     failure mode. `null`/absent is UNKNOWN, never zero: a zero-credit
//     account returns `"rate_limit_reset_credits": null`, so the two are
//     indistinguishable from this endpoint.
//  2. DETAIL — on demand only. `GET wham/rate-limit-reset-credits` carries the
//     per-credit expiry the usage payload does not. It is aggressively rate
//     limited PER IP: probing five accounts back to back, the first two
//     returned 200 and the remaining three returned 429 (measured 2026-09-03),
//     while `wham/usage` answered all five. Hence the cache, the process-wide
//     spacing, and the hard rule that no timer may call it.
//  3. CONSUME — `POST wham/rate-limit-reset-credits/consume` SPENDS a scarce,
//     non-refundable credit. Gated on evidence that the account is actually at
//     its limit, and idempotent per (profile, reset window).
//
//  Endpoint/field provenance: docs/research/2026-09-03-codex-bank-resets-local-evidence.md.
//  Live-verified there: the usage payload's `rate_limit_reset_credits` key
//  (null on all five local accounts) and the detail endpoint's 200 shape.
//  Source-verified only (codex-rs `backend-client/src/types.rs`,
//  `client/rate_limit_resets.rs`): the non-null count shape, a populated
//  `credits[]`, and every consume response — the consume endpoint has never
//  been called.
//

import Foundation

// MARK: - Models

/// One earned usage-limit reset.
nonisolated struct CodexResetCredit: Codable, Equatable, Identifiable {
    /// Opaque id — the value passed back to redeem this specific credit.
    let id: String
    /// `"codex_rate_limits"` today; anything else is a shape the app does not know.
    let resetType: String?
    /// `available` | `redeeming` | `redeemed`, or something newer.
    let status: String?
    let grantedAt: Date?
    /// RFC 3339 on the wire. **nil means the credit never expires** — not
    /// "unknown" — so it sorts last, exactly as the CLI's picker does.
    let expiresAt: Date?
    /// Backend-authored display copy, nullable (the CLI falls back to
    /// "Full reset" / "Reset your current usage limits.").
    let title: String?
    let description: String?

    var isAvailable: Bool {
        status.map { $0.caseInsensitiveCompare("available") == .orderedSame } ?? false
    }
}

/// The detail endpoint's answer, plus the local stamp that makes the cache
/// decidable. `fetchedAt` is not on the wire.
nonisolated struct CodexResetCredits: Equatable {
    /// Authoritative count. It can EXCEED `credits.count` — the backend may cap
    /// the list it returns, so never render `credits.count` as the balance.
    let availableCount: Int
    let credits: [CodexResetCredit]
    /// Lifetime earned. Undocumented in the open-source client (serde drops it)
    /// but present live; absent → nil.
    let totalEarnedCount: Int?
    /// Present live, semantics inferred from the name only — treat as a hint,
    /// never as a purchase affordance.
    let immediateResetPurchaseEligible: Bool?
    let fetchedAt: Date

    /// Available credits, soonest expiry first, never-expiring ones last —
    /// the CLI's own ordering (`reset_credits.rs:28`).
    var availableCreditsByExpiry: [CodexResetCredit] {
        credits.filter(\.isAvailable).sorted { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (left?, right?): return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }
    }

    /// Decodes the endpoint payload. Unknown top-level keys are ignored, and a
    /// single malformed element never blanks the whole list — the count is the
    /// number that matters and it lives outside the array.
    nonisolated static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> CodexResetCredits {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = rfc3339Date(raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "not RFC 3339: \(raw)")
                )
            }
            return date
        }

        guard let wire = try? decoder.decode(Wire.self, from: data) else {
            throw CodexResetCreditsError.invalidResponse
        }
        let credits = (wire.credits ?? []).compactMap(\.value)
        return CodexResetCredits(
            availableCount: wire.availableCount ?? credits.filter(\.isAvailable).count,
            credits: credits,
            totalEarnedCount: wire.totalEarnedCount,
            immediateResetPurchaseEligible: wire.immediateResetPurchaseEligible,
            fetchedAt: fetchedAt
        )
    }

    private nonisolated struct Wire: Decodable {
        let availableCount: Int?
        let credits: [Failable<CodexResetCredit>]?
        let totalEarnedCount: Int?
        let immediateResetPurchaseEligible: Bool?
    }

    /// Decodes an element, or nothing — so one unparseable credit costs that
    /// credit's row rather than the whole response.
    private nonisolated struct Failable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// `credits[]` timestamps are RFC 3339 STRINGS, unlike the Unix seconds the
    /// usage windows carry — two formats in one feature. Fractional seconds are
    /// accepted because nothing promises they are absent.
    nonisolated static func rfc3339Date(_ raw: String) -> Date? {
        // Built per call rather than cached: ISO8601DateFormatter is not
        // Sendable, and a shared instance would either be main-actor-bound
        // (unusable from this nonisolated decode) or a data race waiting to
        // happen. The endpoint is user-initiated and returns a handful of
        // credits, so the allocation is not on any hot path.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}

/// What the consume endpoint did. All four `code` values are distinct because
/// they mean different things to the user: only `.reset` SPENT a credit.
nonisolated enum CodexResetActivationOutcome: Equatable {
    /// A credit was consumed and eligible windows were cleared.
    ///
    /// `windowsReset` is HOW MANY windows the backend cleared — the wire field
    /// is a count (`"windows_reset": 2`), and it never names them.
    case reset(windowsReset: Int)
    /// No current window is eligible. **The credit was NOT spent** — the user
    /// can try again later.
    case nothingToReset
    /// The account has no credits available.
    case noCredit
    /// This idempotency key already succeeded.
    case alreadyRedeemed
    /// A `code` this build does not know.
    case unknown(code: String)

    /// Log-safe label — no ids, no tokens.
    var logLabel: String {
        switch self {
        case .reset(let windows): return "reset (\(windows) window(s))"
        case .nothingToReset: return "nothing_to_reset"
        case .noCredit: return "no_credit"
        case .alreadyRedeemed: return "already_redeemed"
        case .unknown(let code): return "unknown(\(code))"
        }
    }
}

/// Why the caller believes spending a credit is warranted. Activation is
/// refused without it: a reset applied to an account that is not at its limit
/// burns a non-refundable credit for nothing, and `nothing_to_reset` exists
/// precisely because the backend sees that case too.
nonisolated struct CodexResetActivationEvidence: Equatable {
    /// The account was MEASURED at its limit — not projected, not suspected.
    let measuredAtLimit: Bool
    /// When that measurement was taken.
    let measuredAt: Date
    /// Where it came from, for the log line (e.g. "wham/usage").
    let source: String
}

nonisolated enum CodexResetCreditsError: LocalizedError, Equatable {
    /// The endpoint refused (429). Callers render this as **unknown**, never as
    /// zero credits — the refusal says nothing about the balance.
    case resetCreditsUnavailable(retryAfter: TimeInterval?)
    case noProfileCredentials
    /// The profile's Codex login is an API key, not a ChatGPT login. Reset
    /// credits are a ChatGPT-auth feature and the backend answers
    /// "api key auth is not supported" — so this is refused locally rather
    /// than spent on a request that cannot succeed.
    case unsupportedForAPIKeyAuth
    /// Activation asked for while the account is not measured at its limit.
    case notMeasuredAtLimit(source: String)
    /// Activation asked for on a measurement older than the evidence window
    /// (or stamped in the future).
    case staleEvidence(age: TimeInterval)
    case requestFailed(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .resetCreditsUnavailable(let retryAfter):
            let when = retryAfter.map { " Try again in \(Int($0.rounded()))s." } ?? ""
            return "Codex usage-limit resets are temporarily unavailable — the count is unknown, not zero.\(when)"
        case .noProfileCredentials:
            return "This profile has no synced Codex account."
        case .unsupportedForAPIKeyAuth:
            return "Usage-limit resets need a ChatGPT login — an API-key Codex account has none."
        case .notMeasuredAtLimit:
            return "A usage-limit reset is only offered when the account is measured at its limit."
        case .staleEvidence:
            return "The usage measurement is too old to spend a reset on — refresh and try again."
        case .requestFailed(let status):
            return "Codex reset-credit request failed (HTTP \(status))."
        case .invalidResponse:
            return "Could not read the Codex reset-credit response."
        }
    }
}

// MARK: - Process state

/// Cache, spacing clock and idempotency memo for the reset-credit seams.
/// A separate object because a Swift extension cannot add stored properties,
/// and all of this is per-process (a relaunch re-fetches, the safe direction).
final class CodexResetCreditsState {
    static let shared = CodexResetCreditsState()

    /// Last detail response per profile.
    var cache: [UUID: CodexResetCredits] = [:]
    /// When the detail endpoint was last called for ANY profile — the limit is
    /// per IP, so the spacing has to be process-wide, not per account.
    var lastDetailFetchAt: Date?
    /// `"<profile>|<window key>"` → redeem_request_id. A retry inside the same
    /// reset window must re-send the SAME id or a second credit gets spent.
    var redeemRequestIds: [String: String] = [:]

    private init() {}

    /// Test seam — a fresh process starts empty, so a test must be able to say so.
    func reset() {
        cache.removeAll()
        lastDetailFetchAt = nil
        redeemRequestIds.removeAll()
    }
}

// MARK: - Service seams

extension CodexUsageService {

    nonisolated static let resetCreditsDetailEndpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    nonisolated static let resetCreditsConsumeEndpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume"

    /// How long a detail response stands. Long, because the endpoint 429s
    /// across accounts and the data moves only when a credit is earned or spent.
    nonisolated static let resetCreditsCacheTTL: TimeInterval = 600
    /// Minimum gap between detail calls for ANY profile (per-IP limit).
    nonisolated static let resetCreditsMinimumSpacing: TimeInterval = 5
    /// How recent a limit measurement must be to justify spending a credit.
    nonisolated static let resetActivationEvidenceMaxAge: TimeInterval = 300
    /// Tolerated clock skew on evidence stamped slightly in the future. A
    /// future stamp would otherwise never age out of the window above.
    nonisolated static let resetActivationEvidenceMaxSkew: TimeInterval = 60

    // MARK: Auth mode

    /// True when a stored `auth.json` holds an API key and no ChatGPT login.
    ///
    /// Reset credits are ChatGPT-auth only — the CLI's own client refuses with
    /// "chatgpt authentication required for rate limit reset credits" /
    /// "api key auth is not supported" — so both seams below refuse locally
    /// rather than spend a request that cannot succeed. Reads shapes only; the
    /// key's VALUE is never read, returned or logged.
    nonisolated static func usesAPIKeyAuth(credentialsJSON: String) -> Bool {
        guard let data = credentialsJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let tokens = root["tokens"] as? [String: Any]
        let hasChatGPTLogin = ((tokens?["access_token"] as? String) ?? "").isEmpty == false
        guard !hasChatGPTLogin else { return false }
        return ((root["OPENAI_API_KEY"] as? String) ?? "").isEmpty == false
    }

    /// The stored credentials for a profile, with the ChatGPT-auth
    /// precondition already checked. Both seams start here so neither can
    /// reach the network on an account the feature does not exist for.
    private func chatGPTCredentials(for profileId: UUID) throws -> String {
        guard let json = ProfileStore.shared.loadProfiles()
            .first(where: { $0.id == profileId })?.codexCredentialsJSON else {
            throw CodexResetCreditsError.noProfileCredentials
        }
        guard !Self.usesAPIKeyAuth(credentialsJSON: json) else {
            throw CodexResetCreditsError.unsupportedForAPIKeyAuth
        }
        return json
    }

    // MARK: Count (free — from the usage payload)

    /// Reads `rate_limit_reset_credits.available_count` out of a `wham/usage`
    /// payload. Returns nil — UNKNOWN — for absent, `null`, a non-object, a
    /// missing/nonsense count, or a negative one. Never returns 0 for a payload
    /// that did not state 0.
    nonisolated static func resetCreditCount(inUsagePayload json: [String: Any]) -> Int? {
        guard let summary = json["rate_limit_reset_credits"] as? [String: Any],
              let raw = summary["available_count"] else { return nil }
        let count: Int?
        if let intValue = raw as? Int {
            count = intValue
        } else if let doubleValue = raw as? Double, doubleValue.isFinite,
                  doubleValue >= 0, doubleValue <= Double(Int.max) {
            count = Int(doubleValue)
        } else {
            count = nil
        }
        guard let count, count >= 0 else { return nil }
        return count
    }

    // MARK: Detail (on demand only)

    /// The last detail answer this process fetched for one profile, or nil —
    /// no network, no spacing wait, and possibly stale (read `fetchedAt`).
    /// For surfaces that must never trigger the per-IP-limited endpoint
    /// themselves (the ⇄ menu's "expires" row, list captions): they show what
    /// the account view already fetched, or nothing.
    func cachedResetCredits(for profileId: UUID) -> CodexResetCredits? {
        CodexResetCreditsState.shared.cache[profileId]
    }

    /// Per-credit detail, including expiry, for one profile.
    ///
    /// **Never call this from the sweep timer, and never from a loop over
    /// profiles.** The endpoint rate-limits per IP: five back-to-back account
    /// probes produced two 200s and three 429s (2026-09-03) while `wham/usage`
    /// answered all five. It is a user-initiated read — opening a Codex account
    /// detail view — and nothing else. Cached for `resetCreditsCacheTTL` per
    /// profile unless `force`, and every call waits out a process-wide
    /// `resetCreditsMinimumSpacing` gap shared by all profiles.
    ///
    /// A 429 throws `.resetCreditsUnavailable`; render that as **unknown**,
    /// never as zero. Any failure here — 429, timeout, transport — leaves the
    /// free count from the usage payload standing, which is what the CLI falls
    /// back to when this endpoint times out on it.
    func fetchResetCredits(for profileId: UUID, force: Bool = false) async throws -> CodexResetCredits {
        let state = CodexResetCreditsState.shared

        if let cached = state.cache[profileId],
           Self.resetCreditsCacheIsFresh(fetchedAt: cached.fetchedAt, now: Date(), force: force) {
            return cached
        }

        // Before anything that costs time or a request: this feature exists
        // only for ChatGPT-auth accounts.
        _ = try chatGPTCredentials(for: profileId)

        let delay = Self.resetCreditsSpacingDelay(lastFetchAt: state.lastDetailFetchAt, now: Date())
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        _ = await ensureFreshCredentials(for: profileId)

        guard let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
              let json = profile.codexCredentialsJSON,
              let accessToken = extractAccessToken(from: json) else {
            throw CodexResetCreditsError.noProfileCredentials
        }
        guard let url = URL(string: Self.resetCreditsDetailEndpoint) else {
            throw CodexResetCreditsError.invalidResponse
        }

        let request = Self.resetCreditsRequest(
            url: url,
            accessToken: accessToken,
            accountId: extractAccountId(from: json),
            method: "GET",
            body: nil,
            timeout: 5
        )
        // Stamped before the call, so two concurrent callers space out rather
        // than racing into the same 429.
        state.lastDetailFetchAt = Date()

        LoggingService.shared.logAPIRequest("codex/wham/rate-limit-reset-credits")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexResetCreditsError.invalidResponse
        }
        LoggingService.shared.logAPIResponse("codex/wham/rate-limit-reset-credits", statusCode: http.statusCode)
        guard http.statusCode == 200 else { throw Self.resetCreditsError(for: http) }

        let credits = try CodexResetCredits.decode(data, fetchedAt: Date())
        state.cache[profileId] = credits
        LoggingService.shared.log(
            "Codex: reset credits for '\(profile.name)' — \(credits.availableCount) available, \(credits.credits.count) listed"
        )
        return credits
    }

    /// Whether a cached detail response may be served: inside its TTL, not
    /// stamped in the future, and not overridden by `force`. `force` is part of
    /// the decision rather than a branch at the call site so the bypass is
    /// assertable without a network call.
    nonisolated static func resetCreditsCacheIsFresh(fetchedAt: Date, now: Date, force: Bool = false) -> Bool {
        guard !force else { return false }
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < resetCreditsCacheTTL
    }

    /// How long to wait before the next detail call, given the last one.
    nonisolated static func resetCreditsSpacingDelay(lastFetchAt: Date?, now: Date) -> TimeInterval {
        guard let lastFetchAt else { return 0 }
        let elapsed = now.timeIntervalSince(lastFetchAt)
        guard elapsed >= 0 else { return resetCreditsMinimumSpacing }
        return max(0, resetCreditsMinimumSpacing - elapsed)
    }

    /// Classifies a non-200 from either reset-credit endpoint. A 429 becomes
    /// `.resetCreditsUnavailable`, carrying whatever `Retry-After` said —
    /// unknown, never zero.
    nonisolated static func resetCreditsError(for response: HTTPURLResponse, now: Date = Date()) -> CodexResetCreditsError {
        if response.statusCode == 429 {
            return .resetCreditsUnavailable(
                retryAfter: parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now)
            )
        }
        return .requestFailed(status: response.statusCode)
    }

    // MARK: Activation (spends a credit)

    /// Redeems one usage-limit reset for a profile.
    ///
    /// Refuses unless `evidence` says the account was MEASURED at its limit
    /// within `resetActivationEvidenceMaxAge` — a credit is scarce and
    /// non-refundable, and the backend's own `nothing_to_reset` shows the
    /// no-eligible-window case is real. `creditId` picks a specific credit;
    /// nil lets the backend choose the next one (the key is then omitted from
    /// the body entirely, not sent as null).
    ///
    /// Idempotency: one `redeem_request_id` per (profile, reset window), so a
    /// retry inside the same window re-sends the same id and cannot spend a
    /// second credit. It is cleared on a successful `.reset`, which starts a
    /// new window anyway.
    ///
    /// Never sends `x-openai-codex-luna-reserve` — that header opts a client
    /// into Luna Reserve and records experiment exposure, and this app is a
    /// passive reader.
    @discardableResult
    func activateReset(
        for profileId: UUID,
        creditId: String? = nil,
        evidence: CodexResetActivationEvidence
    ) async throws -> CodexResetActivationOutcome {
        if let refusal = Self.activationRefusal(evidence, now: Date()) { throw refusal }
        _ = try chatGPTCredentials(for: profileId)

        _ = await ensureFreshCredentials(for: profileId)

        guard let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
              let json = profile.codexCredentialsJSON,
              let accessToken = extractAccessToken(from: json) else {
            throw CodexResetCreditsError.noProfileCredentials
        }
        guard let url = URL(string: Self.resetCreditsConsumeEndpoint) else {
            throw CodexResetCreditsError.invalidResponse
        }

        let windowKey = Self.resetWindowKey(for: profile.claudeUsage)
        let redeemRequestId = redeemRequestId(for: profileId, windowKey: windowKey)
        let body = try? JSONSerialization.data(
            withJSONObject: Self.consumeRequestBody(redeemRequestId: redeemRequestId, creditId: creditId)
        )
        guard let body else { throw CodexResetCreditsError.invalidResponse }

        let request = Self.resetCreditsRequest(
            url: url,
            accessToken: accessToken,
            accountId: extractAccountId(from: json),
            method: "POST",
            body: body,
            timeout: 10
        )

        LoggingService.shared.logAPIRequest("codex/wham/rate-limit-reset-credits/consume")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexResetCreditsError.invalidResponse
        }
        LoggingService.shared.logAPIResponse("codex/wham/rate-limit-reset-credits/consume", statusCode: http.statusCode)
        guard http.statusCode == 200 else { throw Self.resetCreditsError(for: http) }

        let outcome = Self.activationOutcome(fromConsumePayload: data)
        // Ids are truncated to 8 chars: enough to correlate two log lines from
        // one retry, not enough to be a credential or a credit handle.
        LoggingService.shared.log(
            "Codex: reset activation for '\(profile.name)' → \(outcome.logLabel) "
            + "[req \(redeemRequestId.prefix(8)), credit \(creditId?.prefix(8).description ?? "backend-choice"), "
            + "evidence \(evidence.source)]"
        )

        if case .reset = outcome {
            invalidateAfterReset(profileId: profileId, windowKey: windowKey)
        }
        return outcome
    }

    /// Why an activation may not proceed, or nil when it may. Pure, so the gate
    /// is assertable without a network call.
    nonisolated static func activationRefusal(
        _ evidence: CodexResetActivationEvidence,
        now: Date
    ) -> CodexResetCreditsError? {
        guard evidence.measuredAtLimit else {
            return .notMeasuredAtLimit(source: evidence.source)
        }
        let age = now.timeIntervalSince(evidence.measuredAt)
        guard age <= resetActivationEvidenceMaxAge, age >= -resetActivationEvidenceMaxSkew else {
            return .staleEvidence(age: age)
        }
        return nil
    }

    /// The consume body. `credit_id` is OMITTED when nil (the CLI's
    /// `skip_serializing_if`), never sent as null — the backend reads an absent
    /// key as "you pick".
    nonisolated static func consumeRequestBody(redeemRequestId: String, creditId: String?) -> [String: String] {
        var body = ["redeem_request_id": redeemRequestId]
        if let creditId, !creditId.isEmpty { body["credit_id"] = creditId }
        return body
    }

    /// Maps the consume response onto the outcome. An unreadable body is
    /// `.unknown`, never an optimistic `.reset` — the credit's fate is then
    /// genuinely unknown and the UI must say so.
    nonisolated static func activationOutcome(fromConsumePayload data: Data) -> CodexResetActivationOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String else {
            return .unknown(code: "unreadable")
        }
        switch code {
        case "reset": return .reset(windowsReset: windowsResetCount(json["windows_reset"]))
        case "nothing_to_reset": return .nothingToReset
        case "no_credit": return .noCredit
        case "already_redeemed": return .alreadyRedeemed
        default: return .unknown(code: code)
        }
    }

    /// How many windows `windows_reset` says were cleared. An integer on the
    /// wire; a list is counted rather than rejected, and anything else — absent,
    /// null, unparseable — is 0, which reads as "reset applied, count unknown"
    /// and never as a claim about a number the payload did not carry.
    nonisolated static func windowsResetCount(_ raw: Any?) -> Int {
        if let count = raw as? Int { return max(0, count) }
        if let list = raw as? [Any] { return list.count }
        if let number = raw as? Double, number.isFinite, number >= 0, number <= Double(Int.max) {
            return Int(number)
        }
        return 0
    }

    // MARK: Idempotency

    /// The redeem id for this profile's CURRENT reset window, minting one on
    /// first use. Same window ⇒ same id ⇒ a retry cannot spend a second credit.
    func redeemRequestId(for profileId: UUID, windowKey: String) -> String {
        let key = "\(profileId.uuidString)|\(windowKey)"
        if let existing = CodexResetCreditsState.shared.redeemRequestIds[key] { return existing }
        let minted = UUID().uuidString
        CodexResetCreditsState.shared.redeemRequestIds[key] = minted
        return minted
    }

    /// Identifies the account's current rate-limit window from its usage
    /// boundaries, quantized to the minute — the API reports the same boundary
    /// with ±1s jitter across fetches, and an unquantized key would mint a new
    /// redeem id on every sweep, defeating the idempotency it exists to provide.
    nonisolated static func resetWindowKey(for usage: ClaudeUsage?) -> String {
        resetWindowKey(sessionReset: usage?.sessionResetTime, weeklyReset: usage?.weeklyResetTime)
    }

    nonisolated static func resetWindowKey(sessionReset: Date?, weeklyReset: Date?) -> String {
        func stamp(_ date: Date?) -> String {
            guard let date, date != ClaudeUsage.unknownResetSentinel else { return "-" }
            // ROUNDED, not truncated — the same quantization the menu-bar
            // ranking uses (`StatusBarUIManager`). Truncation flips the bucket
            // for a boundary reported 1s BELOW an exact minute, and a weekly
            // boundary lands on an exact minute almost every time.
            return String(Int((date.timeIntervalSince1970 / 60).rounded()))
        }
        return "s\(stamp(sessionReset))/w\(stamp(weeklyReset))"
    }

    // MARK: Post-reset invalidation

    /// After a credit is spent the account's windows are different: drop the
    /// cached credit list, retire the redeem id for the window that just ended,
    /// and clear the throttle stamps that would otherwise keep the sweep from
    /// re-reading this account (a live `rateLimitedUntil` makes sweeps SKIP the
    /// profile — exactly the state a reset is redeemed from). Percentages are
    /// left alone: the next fetch replaces them with measured values, and
    /// zeroing them here would be a claim no measurement supports.
    private func invalidateAfterReset(profileId: UUID, windowKey: String) {
        let state = CodexResetCreditsState.shared
        state.cache[profileId] = nil
        state.redeemRequestIds["\(profileId.uuidString)|\(windowKey)"] = nil

        if let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
           var usage = profile.claudeUsage {
            usage.rateLimitedUntil = nil
            usage.rateLimitedInferred = nil
            usage.projectedSessionPercentage = nil
            // The count is stale by exactly the credit just spent, and this
            // payload cannot say what the new one is — unknown, not a guess.
            usage.codexResetCreditsAvailable = nil
            usage.codexResetCreditsMeasuredAt = nil
            ProfileStore.shared.applyUsagePatches([profileId: .init(claudeUsage: usage)])
        }

        NotificationCenter.default.post(
            name: .codexResetActivated,
            object: nil,
            userInfo: ["profileId": profileId]
        )
    }

    // MARK: Requests

    /// Shared request shape for both reset-credit endpoints: the same identity
    /// headers the usage fetch presents, and **never**
    /// `x-openai-codex-luna-reserve` — that header opts a client into Luna
    /// Reserve and lets the backend record experiment exposure. This app is a
    /// passive reader.
    nonisolated static func resetCreditsRequest(
        url: URL,
        accessToken: String,
        accountId: String?,
        method: String,
        body: Data?,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        request.setValue("ClaudeUsageWidget/\(version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        return request
    }
}
