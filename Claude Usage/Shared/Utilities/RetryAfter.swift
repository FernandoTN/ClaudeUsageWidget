//
//  RetryAfter.swift
//  Claude Usage
//
//  One parser for the HTTP `Retry-After` header, shared by every 429 site.
//  Three separate defects lived in the ad-hoc `.flatMap(TimeInterval.init)`
//  spellings it replaces (audit 2026-09-01):
//
//  - H5: RFC 9110 allows BOTH `delta-seconds` and an HTTP-date. The numeric-only
//    parse returned nil for the date form, so a date-form 429 never reached
//    `stampAccountThrottleIfNeeded`'s 60s floor and account exhaustion went
//    unstamped — stale cached usage kept reading as headroom, the exact failure
//    the stamp exists to prevent.
//  - H3: `Double("1e400")` is `+infinity`, not nil. It passes every `> 0` test
//    and then TRAPS in `Int(_:)`. Server-controlled input must never reach an
//    unguarded `Int(Double)`.
//  - H2: an unclamped value (a legitimate `86400`, or a buggy upstream number)
//    parks a profile's usage fetch for its full span — the tile goes blind
//    silently.
//

import Foundation

/// Largest delay any `Retry-After` may impose. Nothing in this app benefits
/// from a longer blind window than a day: every usage window it tracks (5-hour
/// session, weekly) either resets or is re-probed well inside it, and a value
/// past the cap is far more likely to be an upstream bug than an instruction.
nonisolated let retryAfterMaximum: TimeInterval = 24 * 60 * 60

/// Parses `Retry-After` per RFC 9110 §10.2.3 into a non-negative, finite,
/// clamped number of seconds. Returns nil for an absent, empty, non-finite,
/// negative or unparseable value — nil means "the server told us nothing
/// usable", which every call site already handles.
///
/// A `Retry-After: 0` parses to `0`, not nil: zero is the shape an exhausted
/// account's usage endpoint actually returned during the 2026-08-11 incident,
/// and the inferred-throttle detector reads it as evidence.
nonisolated func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }

    // delta-seconds. Integer per the RFC; decimals are accepted because real
    // servers emit them and rounding them away loses nothing.
    if let seconds = Double(raw) {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return min(seconds, retryAfterMaximum)
    }

    // HTTP-date. All three forms the RFC requires a recipient to accept.
    for formatter in httpDateFormatters {
        guard let date = formatter.date(from: raw) else { continue }
        let delta = date.timeIntervalSince(now)
        guard delta.isFinite else { return nil }
        return min(max(0, delta), retryAfterMaximum)
    }

    return nil
}

/// `Int(_:)` on a Double TRAPS for infinity, NaN, and anything outside
/// `Int64`'s range — and several of the Doubles this app converts come
/// straight off the wire. Converts by saturating instead of crashing.
nonisolated func clampedInt(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    // 2^63 is not exactly representable as a Double bound to compare against,
    // so saturate a comfortable step inside Int64's range.
    if value >= 9.0e18 { return Int.max }
    if value <= -9.0e18 { return Int.min }
    return Int(value)
}

/// The three date formats RFC 9110 §5.6.7 requires a recipient to parse:
/// IMF-fixdate (the only one a sender may produce), the obsolete RFC 850 form,
/// and ANSI C `asctime()`. Fixed POSIX locale and GMT — a device locale would
/// otherwise fail to parse the English day/month names.
private nonisolated let httpDateFormatters: [DateFormatter] = [
    "EEE, dd MMM yyyy HH:mm:ss zzz",   // Sun, 06 Nov 1994 08:49:37 GMT
    "EEEE, dd-MMM-yy HH:mm:ss zzz",    // Sunday, 06-Nov-94 08:49:37 GMT
    "EEE MMM d HH:mm:ss yyyy",         // Sun Nov  6 08:49:37 1994
].map { format in
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = format
    return formatter
}
