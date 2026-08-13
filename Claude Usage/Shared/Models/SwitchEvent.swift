import Foundation

/// One entry in the persisted account-switch history (SharedDataStore ring
/// buffer, `switchHistory_v1`). Exists because the unified log persists
/// nothing for this process: on 2026-08-12 the owner could not reconstruct
/// which account had been active before a switch he half-remembered making.
/// Names only — never credentials, tokens, or ids that outlive profiles.
struct SwitchEvent: Codable, Equatable {
    enum Trigger: String, Codable {
        /// User clicked/selected the profile themselves.
        case manual
        /// Auto-switch walk picked it by ranking (soonest weekly reset).
        case auto
        /// Auto-switch took it from the user's explicit switch queue.
        case queued
    }

    var at: Date
    var from: String
    var to: String
    var trigger: Trigger
    /// Human-readable context, e.g. the measurements that fired the trigger.
    var reason: String?
}
