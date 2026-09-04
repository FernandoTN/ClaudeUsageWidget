//
//  PreferenceWriteJournal.swift
//  Claude Usage
//
//  Write-side half of the cfprefsd degradation defence (audit C3).
//

import Foundation

/// Outcome of checking one key against the authoritative preferences store.
enum PreferenceWriteVerification: Equatable {
    /// The intended value is in the store.
    case verified
    /// The store holds something else.
    case rejected
    /// No authoritative source was available (no plist yet, unreadable file, or
    /// running under XCTest with no injected source). Never a failure.
    case indeterminate
}

/// One point-in-time read of the authoritative preferences store. A whole sweep
/// pass costs ONE read this way rather than one per key.
protocol PreferenceStoreSnapshotting: AnyObject {
    /// Every key the store holds for this app, or nil when no authoritative
    /// source is available.
    func snapshotAuthoritativeValues() -> [String: Any]?
}

/// Compares two preference values. Property-list values round-trip through the
/// Objective-C bridge, so `isEqual:` is the comparison that actually holds for
/// every type stored here (String, Data, Bool, Double, [String]).
func preferenceValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case (nil, _), (_, nil):
        return false
    default:
        guard let left = lhs as? NSObject, let right = rhs as? NSObject else { return false }
        return left.isEqual(right)
    }
}

/// The app's own `~/Library/Preferences/<bundle id>.plist`, read-only.
///
/// **Why the disk, and why the check is deferred** — measured on this machine,
/// 2026-09-03, against a throwaway domain whose plist was made immutable so
/// cfprefsd could not write it (the artificial twin of the live "rejecting
/// write of key(s) … because Path not accessible" episode):
///
/// | mechanism | healthy | write rejected |
/// |---|---|---|
/// | `UserDefaults.synchronize()` | `true` | `true` |
/// | `CFPreferencesAppSynchronize` | `true` | `true` |
/// | `UserDefaults.string(forKey:)` | new value | **new value** |
/// | `CFPreferencesCopyAppValue` | new value | **new value** |
/// | `CFPreferencesCopyValue(user, anyHost)` | new value | **new value** |
/// | `CFPreferencesCopyMultiple` | new value | **new value** |
/// | a freshly built `UserDefaults(suiteName:)` | new value | **new value** |
/// | on-disk plist | new value (lagging) | stale value |
/// | another process's `defaults read` | new value | stale value |
///
/// Every in-process read is served from the CFPreferences client cache, which
/// keeps the value the daemon threw away, and both synchronize calls return
/// `true`. Nothing was logged on either side in the artificial case, so silence
/// is no evidence either. The disk is the only source inside this process that
/// disagrees.
///
/// It disagrees on a delay, though: with the same domain healthy, a write took
/// **2.57 s, 10.03 s and 9.98 s** to reach disk over three rounds, and a second
/// `CFPreferencesAppSynchronize` a second later did not force it — cfprefsd
/// coalesces flushes on its own timer. An immediate read-back therefore reports
/// a *healthy* write as rejected (measured: 39 of 41 rapid writes). That is why
/// nothing here verifies at write time and the check waits out
/// `PreferenceWriteJournal.flushGrace`.
///
/// READ-ONLY, always: like the cold-launch fallback in `ProfileStore`, nothing
/// here ever writes that file.
final class PlistPreferenceStoreSnapshot: PreferenceStoreSnapshotting {
    private let applicationID: CFString
    private let plistURL: URL

    init?(bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let url = ProfileStore.defaultPreferencesPlistURL(bundleIdentifier: bundleIdentifier)
        else { return nil }
        self.applicationID = bundleIdentifier as CFString
        self.plistURL = url
    }

    func snapshotAuthoritativeValues() -> [String: Any]? {
        // Ask the client to hand its pending writes to the daemon. This does not
        // make the flush synchronous (see above) — it just avoids judging a key
        // the client has not even offered yet.
        _ = CFPreferencesAppSynchronize(applicationID)

        guard let data = try? Data(contentsOf: plistURL),
              let root = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              )) as? [String: Any]
        else {
            // No readable plist — a first launch before the first flush, or an
            // unreadable file. Absence is not proof of rejection.
            return nil
        }
        return root
    }
}

/// Remembers every SINGLE-SHOT preference write, checks each one against the
/// authoritative store once per sweep, and rewrites the ones that are not there.
///
/// The gap this closes (audit C3, live 2026-09-03): cfprefsd rejected this
/// app's writes for two minutes. Keys rewritten every sweep — `profiles_v3`,
/// `measuredSessionHistory_v1` — healed by themselves the moment the episode
/// ended. Keys written ONCE, at the moment something changed, did not: both
/// provider-owner pointers, the focus pointer and the switch-history ring
/// buffer were still stale on disk an hour later, with a relaunch about to
/// re-flag a working account dead. Nothing noticed, because the existing
/// detector watches nil READS and reads were fine throughout.
///
/// How the check works, and why it is shaped this way:
///
///  - **Deferred, not at write time.** There is no synchronous oracle. Every
///    in-process read-back reports success for a rejected write, and the disk —
///    the one source that tells the truth — lags a healthy write by up to ten
///    seconds. So a write only records its intended value; the judging happens
///    on the next sweep that finds the entry older than `flushGrace`.
///  - **One snapshot per pass.** All remembered keys are checked against a
///    single read of the store, so the whole thing costs one file read per
///    sweep regardless of how many keys are in flight.
///  - **Rewrite on the first miss, escalate on the second.** The rewrite is the
///    remedy and is harmless, so it happens immediately. The user-visible
///    banner and notification wait for a second consecutive miss, which a merely
///    slow flush cannot produce.
///  - **Every remembered key is checked, not only the ones known bad.** A
///    rejection is invisible from inside this process, so a key that looked fine
///    is not evidence that it landed. This is what covers the stranded pointers
///    in the live incident, none of which carried any failure signal.
///
/// Main-actor by contract, like the two stores that use it.
@MainActor
final class PreferenceWriteJournal {
    static let shared = PreferenceWriteJournal()

    /// Which store wrote a key. Lets each store check only its own without a
    /// second journal.
    enum Owner: String {
        case profileStore
        case sharedDataStore
    }

    /// How long a write is left alone before its absence means anything.
    /// Measured healthy flush latency was 2.57–10.03 s; sweeps run every ~30 s,
    /// so this only ever skips the check that fires immediately after a write.
    static let flushGrace: TimeInterval = 20

    /// Consecutive missed checks before the episode becomes user-visible. The
    /// rewrite happens on the first miss regardless.
    static let missesBeforeEscalation = 2

    private struct Entry {
        let owner: Owner
        let defaults: UserDefaults
        let value: Any?
        var writtenAt: Date
        /// Consecutive checks that found this key absent or different.
        var misses: Int
    }

    /// Last intended value for every single-shot key written this process.
    /// Bounded by the number of such keys (~15); values are short strings, small
    /// JSON blobs and flags — never credentials.
    private var entries: [String: Entry] = [:]

    /// True from the first escalated miss until every key agrees with the store.
    private(set) var isWriteDegraded = false

    private var snapshotSource: PreferenceStoreSnapshotting?
    private var graceOverride: TimeInterval?

    private var flushGrace: TimeInterval { graceOverride ?? Self.flushGrace }

    private init() {
        // Same XCTest detection as the two stores. Under test there is no
        // snapshot source unless a test injects one: the suite must not depend
        // on the real preferences file, and an unverifiable write is never dirty.
        let isTestRun = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        if !isTestRun {
            snapshotSource = PlistPreferenceStoreSnapshot(bundleIdentifier: Bundle.main.bundleIdentifier)
        }
    }

    // MARK: - Writing

    /// Writes `value` (nil removes the key) and remembers it for checking. No
    /// verdict here: at write time there is nothing to verify against.
    func write(_ value: Any?, forKey key: String, in defaults: UserDefaults, owner: Owner) {
        apply(value, forKey: key, in: defaults)
        entries[key] = Entry(owner: owner, defaults: defaults, value: value, writtenAt: Date(), misses: 0)
    }

    private func apply(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Sweep check

    /// Keys this owner wrote that the last check did not find in the store.
    func pendingKeys(for owner: Owner) -> [String] {
        entries.filter { $0.value.owner == owner && $0.value.misses > 0 }.keys.sorted()
    }

    private var hasPendingWrites: Bool {
        entries.values.contains { $0.misses > 0 }
    }

    /// Checks this owner's single-shot keys against the authoritative store and
    /// rewrites the ones that are not there. Called once per sweep. Returns how
    /// many keys were rewritten.
    @discardableResult
    func runWriteCheck(owner: Owner, now: Date = Date()) -> Int {
        guard let snapshot = snapshotSource?.snapshotAuthoritativeValues() else { return 0 }

        var rewritten: [String] = []
        var newlyEscalated: String?

        for (key, entry) in entries where entry.owner == owner {
            guard now.timeIntervalSince(entry.writtenAt) >= flushGrace else { continue }

            if preferenceValuesEqual(snapshot[key], entry.value) {
                entries[key]?.misses = 0
                continue
            }

            // Missing from the store. Rewrite it — that is the remedy, and it is
            // harmless if the flush was merely slow.
            let misses = entry.misses + 1
            apply(entry.value, forKey: key, in: entry.defaults)
            entries[key]?.misses = misses
            entries[key]?.writtenAt = now
            rewritten.append(key)
            if misses >= Self.missesBeforeEscalation && newlyEscalated == nil {
                newlyEscalated = key
            }
        }

        if !rewritten.isEmpty {
            LoggingService.shared.log(
                "PreferenceWriteJournal: \(rewritten.count) \(owner.rawValue) key(s) missing from the preferences store — re-asserted \(rewritten.sorted().joined(separator: ", "))"
            )
        }

        if let newlyEscalated {
            enterWriteDegraded(key: newlyEscalated)
        } else if isWriteDegraded && !hasPendingWrites {
            leaveWriteDegraded()
        }

        return rewritten.count
    }

    private func enterWriteDegraded(key: String) {
        guard !isWriteDegraded else { return }
        isWriteDegraded = true
        ProfileStore.shared.markPreferenceWriteRejected(key: key)
    }

    private func leaveWriteDegraded() {
        isWriteDegraded = false
        LoggingService.shared.log(
            "PreferenceWriteJournal: every single-shot key is in the preferences store again (\(entries.count) tracked)"
        )
        ProfileStore.shared.clearPreferenceWriteRejected()
    }

    // MARK: - Test seams

    func setSnapshotSourceForTesting(_ source: PreferenceStoreSnapshotting?) {
        snapshotSource = source
    }

    /// Lets a test judge a write immediately instead of waiting out the real
    /// flush grace.
    func setFlushGraceForTesting(_ seconds: TimeInterval?) {
        graceOverride = seconds
    }

    /// Drops every remembered key and the episode state. The journal is a
    /// singleton that outlives a test case, so one test's pending key would
    /// otherwise be re-asserted inside the next one.
    func resetForTesting() {
        entries = [:]
        isWriteDegraded = false
        snapshotSource = nil
        graceOverride = nil
    }
}
