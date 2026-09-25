//
//  ObservedDeadLogins.swift
//  Claude Usage
//
//  Claude logins the SERVER has refused, kept apart from the structural
//  dead-login rule. CLAUDE.md "Server-rejected Claude logins" has the story.
//

import Foundation

/// Claude logins the server has refused, as opposed to logins whose stored
/// token merely LOOKS dead.
///
/// `ProfileCredentialStatusCache.hasDeadLogin` judges a login by its structure
/// (is the access token expired, is there a refresh token) and never asks the
/// server. A token the server has invalidated is structurally perfect, so that
/// rule never called it dead; and because a refused login generates no usage,
/// it never crossed an auto-switch threshold either. It was a permanent trap.
/// Twice on 2026-09-24 (03:31 and 20:31) the fleet sat on such a login until
/// the owner ran `/login` by hand. The first time lasted three hours: 161
/// "Login expired" errors across 41 sessions, while the preflight called the
/// login "live and fresh" 4.5 s before the first of them.
///
/// Two detectors feed this registry:
/// - **A, the widget's own reads** (`recordFailedRead`): two refused (401/403)
///   usage reads of the same stored login with no success between them, AND
///   another account's read succeeding after the run began. That last part
///   proves the endpoint accepted this app while it refused this login.
///   Without it a systemic refusal (an endpoint change, a blocked surface)
///   would condemn every account in turn and rotate the fleet through all
///   24 of them.
/// - **B, the fleet's verdict** (`evaluateFleetMarkers`): `authentication_failed`
///   markers from N distinct sessions inside a short window condemn the
///   ACTIVE login. B exists because A is blind in exactly the incident window:
///   the widget's reads of the affected account were 429'd throughout both
///   incidents (~170 × "Rate limit exceeded").
///
/// A verdict is OR-ed into `hasDeadLogin`. It is never written into that
/// fingerprint-keyed memo, which would recompute it away. A condemned account
/// is not a switch candidate, and an ACTIVE condemned account counts as
/// exhausted (`MenuBarManager.isQuotaExhausted`'s `loginCondemned` arm), so the
/// ordinary candidate walk moves the fleet off it. The verdict lifts on the
/// next successful usage read, which is also how a login the owner repaired
/// with `/login` returns to rotation. It is held in memory only: a relaunch
/// re-derives it from fresh evidence rather than trusting an old one.
///
/// Recovery never re-authenticates: condemn, switch away, tell the owner.
@MainActor
final class ObservedDeadLogins {

    static let shared = ObservedDeadLogins()

    /// Why a login was condemned. Logged and shown by NAME and count only.
    enum Evidence: Equatable {
        /// Consecutive refused (401/403) usage reads of the profile's own login.
        case unauthorizedReads(Int)
        /// Distinct CLI sessions whose turns ended on `authentication_failed`.
        case fleetAuthFailures(sessions: Int)

        var summary: String {
            switch self {
            case .unauthorizedReads(let count):
                return "\(count) usage reads refused as unauthorized"
            case .fleetAuthFailures(let sessions):
                return "\(sessions) sessions failed authentication"
            }
        }
    }

    struct Verdict: Equatable {
        let evidence: Evidence
        let at: Date
    }

    /// One profile's run of refused reads.
    struct Streak: Equatable {
        var count: Int
        var startedAt: Date
        /// `ProfileStore.credentialRevision` when the run began. A login that
        /// changed underneath it (a refresh, an adoption, a re-sync) starts a
        /// new run: a refusal of the old token says nothing about the new one,
        /// and a refusal that races a token refresh is exactly the blip two
        /// consecutive reads exist to absorb.
        var credentialRevision: Int
    }

    // MARK: - Detector A: the widget's own reads

    nonisolated static let unauthorizedReadsToCondemn = 2

    /// Only a 401/403 (`.apiUnauthorized`) is evidence about a login. A 429 is
    /// capacity, and it is what masked both incidents. A network, DNS or
    /// timeout failure belongs to the machine. Condemning on any of those would
    /// be far worse than the bug, so this is the only door in.
    nonisolated static func isLoginRefusal(_ error: Error) -> Bool {
        AppError.wrap(error).code == .apiUnauthorized
    }

    /// The run after one more refused read. Pure.
    nonisolated static func advance(_ streak: Streak?, credentialRevision: Int, now: Date) -> Streak {
        guard var streak, streak.credentialRevision == credentialRevision else {
            return Streak(count: 1, startedAt: now, credentialRevision: credentialRevision)
        }
        streak.count += 1
        return streak
    }

    /// Whether a run condemns. `otherAccountSuccessAt` is the latest successful
    /// `oauth/usage` read of a DIFFERENT Claude account. It must postdate the
    /// run's start: that is the control showing the refusal follows this login
    /// and not the endpoint. Pure.
    nonisolated static func condemns(_ streak: Streak, otherAccountSuccessAt: Date?) -> Bool {
        guard streak.count >= unauthorizedReadsToCondemn else { return false }
        guard let control = otherAccountSuccessAt, control > streak.startedAt else { return false }
        return true
    }

    // MARK: - Detector B: the fleet's verdict

    /// How far back fleet markers count.
    nonisolated static let fleetWindow: TimeInterval = 120
    /// Distinct sessions (never lines) that condemn. One crash-looping session
    /// must not be able to condemn a login alone.
    nonisolated static let fleetDistinctSessions = 3
    /// After the active login changes (another owner, or a new token for the
    /// same one), markers are not counted for this long. Running sessions keep
    /// the previous login for a while and end their in-flight turns on it, so
    /// those failures belong to the login that was just replaced. The same
    /// reasoning gives the transcript tripwire its 120 s post-switch rule.
    nonisolated static let fleetOwnerGrace: TimeInterval = 120
    /// Circuit breaker: at most this many fleet condemnations inside the
    /// window. Past that, the failures are not following any one login (an
    /// auth outage, a proxy, a CLI bug). Rotating further would only burn every
    /// running session's prompt cache once per account, so recovery pauses
    /// and the owner is told once.
    nonisolated static let fleetBreakerLimit = 3
    nonisolated static let fleetBreakerWindow: TimeInterval = 1800
    /// A marker stamped slightly in the future (another process's clock read)
    /// still counts; one far in the future is junk.
    nonisolated static let clockSkewTolerance: TimeInterval = 5

    /// The distinct sessions reporting inside the window, never earlier than
    /// `notBefore`. Pure.
    nonisolated static func reportingSessions(
        _ markers: [FleetAuthFailureMarker],
        now: Date,
        notBefore: Date
    ) -> Set<String> {
        let floor = max(now.addingTimeInterval(-fleetWindow), notBefore)
        let ceiling = now.addingTimeInterval(clockSkewTolerance)
        return Set(markers
            .filter { $0.at >= floor && $0.at <= ceiling && !$0.sessionId.isEmpty }
            .map(\.sessionId))
    }

    enum FleetOutcome: Equatable {
        /// Nothing to act on.
        case none
        /// The active login was condemned just now.
        case condemned(Verdict)
        /// The breaker opened on this evaluation. Tell the owner once.
        case breakerTripped
        /// The breaker is open and was already announced.
        case suppressed
    }

    /// The active login this registry last saw, and since when. Reset whenever
    /// the owner or its stored credentials change.
    private struct OwnerEpoch: Equatable {
        let ownerId: UUID
        let credentialRevision: Int
        let since: Date
    }

    // MARK: - State

    private(set) var verdicts: [UUID: Verdict] = [:]
    private var streaks: [UUID: Streak] = [:]
    private var ownerEpoch: OwnerEpoch?
    /// Markers at or before this instant were already acted on. A re-condemnation
    /// needs NEW sessions, never the same lines read again.
    private var fleetWatermark: Date = .distantPast
    private var fleetCondemnations: [Date] = []
    private var breakerAnnounced = false

    init() {}

    func isCondemned(_ profileId: UUID) -> Bool {
        verdicts[profileId] != nil
    }

    func verdict(for profileId: UUID) -> Verdict? {
        verdicts[profileId]
    }

    var condemnedIds: Set<UUID> {
        Set(verdicts.keys)
    }

    /// One failed usage read. Returns the verdict only when THIS read condemned
    /// the profile, and nil for every read after that, so the caller notifies
    /// once per condemnation and not once per failed read. A failure that is
    /// not a login refusal is neutral: it neither advances nor resets the run.
    @discardableResult
    func recordFailedRead(
        _ profileId: UUID,
        error: Error,
        credentialRevision: Int,
        otherAccountSuccessAt: Date?,
        now: Date = Date()
    ) -> Verdict? {
        guard Self.isLoginRefusal(error) else { return nil }
        let streak = Self.advance(streaks[profileId], credentialRevision: credentialRevision, now: now)
        streaks[profileId] = streak
        guard verdicts[profileId] == nil,
              Self.condemns(streak, otherAccountSuccessAt: otherAccountSuccessAt) else { return nil }
        let verdict = Verdict(evidence: .unauthorizedReads(streak.count), at: now)
        verdicts[profileId] = verdict
        return verdict
    }

    /// A usage read of this profile answered. The run ends and any verdict
    /// lifts. Returns true when a verdict was lifted.
    @discardableResult
    func recordSuccessfulRead(_ profileId: UUID) -> Bool {
        streaks.removeValue(forKey: profileId)
        return verdicts.removeValue(forKey: profileId) != nil
    }

    /// Runs detector B against the active Claude login. Call once per sweep,
    /// never while a switch is rewriting the pointers.
    func evaluateFleetMarkers(
        _ markers: [FleetAuthFailureMarker],
        ownerId: UUID,
        ownerCredentialRevision: Int,
        now: Date = Date()
    ) -> FleetOutcome {
        let epoch: OwnerEpoch
        if let current = ownerEpoch,
           current.ownerId == ownerId, current.credentialRevision == ownerCredentialRevision {
            epoch = current
        } else {
            epoch = OwnerEpoch(ownerId: ownerId, credentialRevision: ownerCredentialRevision, since: now)
            ownerEpoch = epoch
        }
        guard verdicts[ownerId] == nil else { return .none }

        let notBefore = max(epoch.since.addingTimeInterval(Self.fleetOwnerGrace), fleetWatermark)
        let sessions = Self.reportingSessions(markers, now: now, notBefore: notBefore)
        guard sessions.count >= Self.fleetDistinctSessions else { return .none }

        fleetWatermark = now
        fleetCondemnations.removeAll { now.timeIntervalSince($0) >= Self.fleetBreakerWindow }
        guard fleetCondemnations.count < Self.fleetBreakerLimit else {
            if breakerAnnounced { return .suppressed }
            breakerAnnounced = true
            return .breakerTripped
        }
        breakerAnnounced = false
        fleetCondemnations.append(now)
        let verdict = Verdict(evidence: .fleetAuthFailures(sessions: sessions.count), at: now)
        verdicts[ownerId] = verdict
        return .condemned(verdict)
    }

    /// Test seam: forget every verdict, run and epoch.
    func resetForTesting() {
        verdicts.removeAll()
        streaks.removeAll()
        ownerEpoch = nil
        fleetWatermark = .distantPast
        fleetCondemnations.removeAll()
        breakerAnnounced = false
    }
}
