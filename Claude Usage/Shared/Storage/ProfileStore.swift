//
//  ProfileStore.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Security

/// Manages storage and retrieval of profiles and profile-related data.
///
/// Credentials (claudeSessionKey, apiSessionKey, cliCredentialsJSON) are NEVER written to
/// UserDefaults — `Profile.CodingKeys` excludes them. They live in the macOS Keychain plus
/// an in-memory cache.
///
/// IMPORTANT: All Keychain *writes* happen on a background queue, and *reads* are served
/// from the in-memory cache. This is deliberate — reading a Keychain item's data can raise
/// a modal SecurityAgent prompt, and if that happens on the main thread the app deadlocks
/// (the prompt needs the very thread that is blocked waiting for it). `loadProfiles()`
/// therefore never touches the Keychain on the calling thread.
///
/// Startup hydration is async: `credentialHydrationState` is `.loading` until the
/// background Keychain read finishes. Callers that would treat nil credentials as
/// "has no credentials" must gate on `.ready` / `.failed` so an unhydrated profile
/// is never misclassified.
class ProfileStore {
    static let shared = ProfileStore()

    /// Tri-state readiness for the in-memory credential cache.
    /// - `.loading`: Keychain warm still in flight — nil credentials mean "not loaded yet"
    /// - `.ready`: every profile's read completed (values already in memory win
    ///   over the Keychain snapshot, field by field)
    /// - `.failed`: warm hit an error or wall-clock deadline; partial cache may exist.
    ///   `.profileCredentialsReady` is still posted (first failure only), and a
    ///   background retry with exponential backoff keeps re-reading the MISSING
    ///   profiles until the warm completes — `.failed` heals to `.ready` and is
    ///   no longer terminal for the run. (2026-08-10: a post-reboot login storm
    ///   tripped the deadline mid-loop; the 6 unread profiles stayed
    ///   credential-less for the app's whole lifetime, freezing their tiles and
    ///   misclassifying the Grok profile into the Claude group.)
    enum CredentialHydrationState: Equatable {
        case loading
        case ready
        case failed
    }

    /// Main-actor-visible hydration readiness. Starts `.loading`; reaches
    /// `.ready` either directly or through `.failed` plus a healed retry.
    /// Posts on success and on the FIRST failure of a run (repeat failures
    /// change nothing for observers).
    private(set) var credentialHydrationState: CredentialHydrationState = .loading

    private let defaults: UserDefaults
    private let keychainService = KeychainService.shared

    /// Serial queue for all Keychain I/O — keeps it off the main thread.
    private let keychainQueue = DispatchQueue(label: "com.claudewidget.profilestore.keychain", qos: .userInitiated)

    /// Wall-clock budget for a single async Keychain warm. Beyond this we mark
    /// `.failed` with whatever partial cache was filled and still notify observers.
    private static let hydrationWallClockDeadline: TimeInterval = 15.0

    /// Backoff schedule for re-warming after a `.failed` hydration: 30s, 60s,
    /// 120s, 240s, then 480s forever. The deadline trips under transient load
    /// (post-reboot login storm: 75 `security` spawns that cost ~0.8s idle blew
    /// the 15s budget at load-average 11), so early retries usually succeed;
    /// the cap keeps a genuinely broken Keychain from being hammered.
    static func hydrationRetryDelay(afterAttempt attempt: Int) -> TimeInterval {
        min(30.0 * pow(2.0, Double(max(0, attempt))), 480.0)
    }

    /// Number of failed warm attempts this run (drives the backoff schedule).
    private var hydrationRetryAttempt = 0
    /// True while a retry is queued on the main queue — prevents pile-up when
    /// another warm path (e.g. the test rewarm) fails while one is pending.
    private var hydrationRetryScheduled = false

    /// Profile ids whose Keychain read has NOT yet completed for the current
    /// warm generation. Guarded by `cacheLock` (touched from `keychainQueue`
    /// and the main actor). This set — not cache-entry absence — is the
    /// retry's work list: `saveProfiles`' merge-on-save mints an (all-nil)
    /// cache entry for EVERY profile it persists, so "no entry" stops meaning
    /// "unread" the moment anything saves the full roster.
    private var pendingHydrationIds: Set<UUID> = []

    /// Bumped at every warm start (launch warm, v2 repair, test rewarm).
    /// Completions carry the generation they started under; a completion from
    /// a superseded generation is dropped so an in-flight retry can never flip
    /// state or re-post readiness over a newer warm's run.
    private var hydrationGeneration = 0

    /// Credential fields the user EXPLICITLY cleared while their profile's
    /// hydration read was pending or in flight. The read-merge preserves these
    /// nils instead of filling them from the Keychain snapshot — without the
    /// tombstone, an in-flight read resurrects the cleared credential in cache
    /// (its Keychain delete queues BEHIND the running read on the serial
    /// queue). Guarded by `cacheLock`; entries drop when their profile's read
    /// completes and on every new warm.
    private struct ClearedCredentialTombstone: Hashable {
        let profileId: UUID
        let key: CredentialKey
    }
    private var clearedWhilePending: Set<ClearedCredentialTombstone> = []

    /// True when running under XCTest (same detection the defaults isolation
    /// uses). Suites must be deterministic: the backoff timer is never armed
    /// under test — tests drive `retryHydrationForMissingProfiles()` directly.
    private let isTestRun: Bool

    /// Monotonic per-profile credential revision: bumped on EVERY mutation of
    /// the in-memory credential cache (hydration, merge-on-save, clear,
    /// migration restore). Constant-time change detection for UI memo caches —
    /// replaces hashing multi-KB credential blobs, and unlike a partial-string
    /// fingerprint it cannot miss a same-length/same-suffix token rotation
    /// (Codex-caught hazard). Main-actor, like the rest of the class surface.
    /// Lock-protected like `credentialCache`: bumps happen from both the main
    /// actor (merge/clear) and `keychainQueue` (hydration, migration restore).
    private var credentialRevisions: [UUID: Int] = [:]
    private let revisionLock = NSLock()

    func credentialRevision(for profileId: UUID) -> Int {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        return credentialRevisions[profileId] ?? 0
    }

    private func bumpCredentialRevision(_ profileId: UUID) {
        revisionLock.lock()
        credentialRevisions[profileId, default: 0] += 1
        revisionLock.unlock()
    }

    /// In-memory credential cache. `loadProfiles()` hydrates from here, not the Keychain.
    private struct CachedCredentials: Equatable {
        var claudeSessionKey: String?
        var apiSessionKey: String?
        var cliCredentialsJSON: String?
        var codexCredentialsJSON: String?
        var grokCredentialsJSON: String?

        subscript(key: CredentialKey) -> String? {
            get {
                switch key {
                case .claudeSessionKey: return claudeSessionKey
                case .apiSessionKey: return apiSessionKey
                case .cliCredentials: return cliCredentialsJSON
                case .codexCredentials: return codexCredentialsJSON
                case .grokCredentials: return grokCredentialsJSON
                }
            }
            set {
                switch key {
                case .claudeSessionKey: claudeSessionKey = newValue
                case .apiSessionKey: apiSessionKey = newValue
                case .cliCredentials: cliCredentialsJSON = newValue
                case .codexCredentials: codexCredentialsJSON = newValue
                case .grokCredentials: grokCredentialsJSON = newValue
                }
            }
        }
    }
    private var credentialCache: [UUID: CachedCredentials] = [:]
    private let cacheLock = NSLock()

    /// The Keychain item behind each credential field. Raw values are the
    /// per-profile Keychain key suffixes used by KeychainService.
    enum CredentialKey: String, CaseIterable {
        case claudeSessionKey = "claude-key"
        case apiSessionKey = "api-key"
        case cliCredentials = "cli-creds"
        case codexCredentials = "codex-creds"
        case grokCredentials = "grok-creds"
    }

    private enum Keys {
        static let profiles = "profiles_v3"
        static let activeProfileId = "activeProfileId"
        static let displayMode = "profileDisplayMode"
        static let multiProfileConfig = "multiProfileDisplayConfig"
        static let credentialsMigratedToKeychain = "credentialsMigratedToKeychain"  // legacy v1 flag
        static let credentialsRepairedV2 = "credentialsRepairedToKeychain_v2"
        static let keychainRebuiltV3 = "keychainItemsRebuiltViaSecurityTool_v3"
        static let activeClaudeProfileId = "activeClaudeProfileId"
        static let activeCodexProfileId = "activeCodexProfileId"
        static let activeGrokProfileId = "activeGrokProfileId"
    }

    /// This store's keys for `SettingsKeyRegistry` (spec §5.2).
    static let registeredKeys: [RegisteredKey] = [
        RegisteredKey(Keys.profiles, .profileStore, .live, ui: "Accounts"),
        RegisteredKey(Keys.activeProfileId, .profileStore, .live, ui: "Accounts (Viewing)"),
        RegisteredKey(Keys.displayMode, .profileStore, .live, ui: "Display › Menu bar"),
        RegisteredKey(Keys.multiProfileConfig, .profileStore, .live, ui: "Display › Menu bar"),
        RegisteredKey(Keys.credentialsMigratedToKeychain, .profileStore, .migrationFlag),
        RegisteredKey(Keys.credentialsRepairedV2, .profileStore, .migrationFlag),
        RegisteredKey(Keys.keychainRebuiltV3, .profileStore, .migrationFlag),
        RegisteredKey(Keys.activeClaudeProfileId, .profileStore, .live, ui: "Active & Auto-switch; ⇄ selector"),
        RegisteredKey(Keys.activeCodexProfileId, .profileStore, .live, ui: "Active & Auto-switch; ⇄ selector"),
        RegisteredKey(Keys.activeGrokProfileId, .profileStore, .live, ui: "Active & Auto-switch; ⇄ selector"),
    ]

    // MARK: - Preferences (cfprefsd) degradation resilience
    //
    // macOS's preferences daemon can lose access to plist files while the app is
    // running (its log: "rejecting write of key(s) … because Path not accessible").
    // Measured live 2026-09-01: `defaults read com.claudeusagewidget.app` returned an
    // EMPTY dict and every in-process `UserDefaults` read returned nil, while the
    // on-disk plist was intact (39 KB, all keys). The wedge began 26 minutes into a
    // healthy run. Because `loadProfiles()` is re-read many times per 30s sweep, a
    // single nil read emptied the whole UI — and persisting that empty state after the
    // daemon recovered would have destroyed the user's real roster.
    //
    // Defence, in three layers:
    //  1. LAST-KNOWN-GOOD shadow — every successful read and every write records what
    //     the store believes is true. A read that comes back absent/empty while the
    //     shadow holds a value is served from the shadow, not from the type default.
    //  2. COLD-LAUNCH PLIST FALLBACK — with nothing yet in the shadow, `profiles_v3`
    //     is read straight out of `~/Library/Preferences/<bundle id>.plist`.
    //     READ-ONLY, always: this code never writes that file.
    //  3. EMPTY-OVERWRITE GUARD — `saveProfiles([])` is refused whenever a non-empty
    //     roster is known, unless the caller passes `allowEmpty: true`.
    //
    // The shadow is per-process and is written by the SAVE path too, so a legitimate
    // user change (clearing the active Claude account, switching display mode) updates
    // it and is never "restored" by a later read.

    /// Last profile array this process decoded (or persisted) successfully and
    /// non-empty. `nil` until the first good read — that state is what the plist
    /// fallback exists for.
    private var lastKnownGoodProfiles: [Profile]?
    private var lastKnownGoodDisplayMode: ProfileDisplayMode?
    private var lastKnownGoodMultiProfileConfig: MultiProfileDisplayConfig?
    /// Active-profile pointers. The outer optional is "never observed"; the inner one
    /// is the value, so a deliberate `save…(nil)` is remembered as a real nil and is
    /// NOT re-filled from the shadow on the next read.
    private var lastKnownGoodActiveProfileId: UUID??
    private var lastKnownGoodActiveClaudeProfileId: UUID??
    private var lastKnownGoodActiveCodexProfileId: UUID??
    private var lastKnownGoodActiveGrokProfileId: UUID??

    /// True while EITHER half of the daemon is misbehaving — reads coming back
    /// empty against a known-good shadow, or a single-shot write that cfprefsd
    /// accepted in-process and never persisted. Observers get
    /// `.preferencesDegradedStateChanged` on each transition of the combined flag.
    ///
    /// The two halves are tracked separately because they do not overlap: during
    /// the 2026-09-03 write-rejection episode every READ was fine, so a single
    /// flag would have been cleared by the next `loadProfiles()` and the banner
    /// would have flickered off while five keys were still stranded.
    private(set) var preferencesDegraded = false

    /// Reads are being served from the shadow. Cleared by the first read that
    /// agrees with the shadow again.
    private var readDegraded = false

    /// A single-shot write did not reach disk. Cleared by
    /// `PreferenceWriteJournal` once every pending key has been re-asserted.
    private var writeDegraded = false

    /// The app's own preferences plist, used ONLY as a read-only cold-launch fallback.
    /// `nil` under XCTest unless a test injects a path — suites must never read or
    /// write the real user domain (2026-07-28 tearDown incident).
    private var preferencesPlistURL: URL?

    /// Throttle for the fallback: `loadProfiles()` runs many times per sweep, and a
    /// genuinely-first-launch install would otherwise stat + parse on every call.
    private var lastPlistFallbackAttempt: Date?
    private var cachedPlistRoot: [String: Any]?
    private static let plistFallbackMinInterval: TimeInterval = 5.0

    /// `~/Library/Preferences/<bundle id>.plist` for the running app.
    static func defaultPreferencesPlistURL(bundleIdentifier: String?) -> URL? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return library
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist", isDirectory: false)
    }

    /// Points the cold-launch fallback at a specific plist. Test-only seam — the
    /// production path is set once in `init()`.
    func setPreferencesPlistURLForTesting(_ url: URL?) {
        preferencesPlistURL = url
        lastPlistFallbackAttempt = nil
        cachedPlistRoot = nil
    }

    /// Clears the in-process last-known-good shadow and the degraded flag. Test-only:
    /// the singleton outlives every test case, so a shadow left by one test would
    /// otherwise mask the next one's empty-read setup.
    func resetPreferencesResilienceStateForTesting() {
        lastKnownGoodProfiles = nil
        lastKnownGoodDisplayMode = nil
        lastKnownGoodMultiProfileConfig = nil
        lastKnownGoodActiveProfileId = nil
        lastKnownGoodActiveClaudeProfileId = nil
        lastKnownGoodActiveCodexProfileId = nil
        lastKnownGoodActiveGrokProfileId = nil
        cachedPlistRoot = nil
        lastPlistFallbackAttempt = nil
        preferencesDegraded = false
        readDegraded = false
        writeDegraded = false
        PreferenceWriteJournal.shared.resetForTesting()
    }

    /// Parses a preferences plist off disk. READ-ONLY — nothing here ever writes it.
    static func readPreferencesPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )) as? [String: Any]
    }

    /// Reads `profiles_v3` out of a preferences plist on disk. READ-ONLY. Returns nil
    /// when the file is missing, unparseable, or carries no usable profile array.
    static func decodeProfilesFromPreferencesPlist(at url: URL) -> [Profile]? {
        guard let root = readPreferencesPlist(at: url) else { return nil }
        return decodeProfiles(fromPlistRoot: root)
    }

    private static func decodeProfiles(fromPlistRoot root: [String: Any]) -> [Profile]? {
        guard let profilesData = root[Keys.profiles] as? Data else { return nil }
        guard let profiles = try? JSONDecoder().decode([Profile].self, from: profilesData),
              !profiles.isEmpty else { return nil }
        return profiles
    }

    /// One throttled read-only parse of the on-disk plist. Throttled because
    /// `loadProfiles()` runs many times per 30s sweep and a genuinely-first-launch
    /// install would otherwise stat and parse the file on every call.
    private func preferencesPlistRoot() -> [String: Any]? {
        guard let url = preferencesPlistURL else { return nil }
        // Inside the window, serve the PARSED ROOT rather than nil. One
        // `ProfileManager.loadProfiles()` pass reads profiles, display mode and the
        // multi-profile config back to back; returning nil to the later callers would
        // throttle out exactly the reads this fallback exists to answer.
        if let last = lastPlistFallbackAttempt,
           Date().timeIntervalSince(last) < Self.plistFallbackMinInterval {
            return cachedPlistRoot
        }
        lastPlistFallbackAttempt = Date()
        cachedPlistRoot = Self.readPreferencesPlist(at: url)
        return cachedPlistRoot
    }

    private func profilesFromPreferencesPlist() -> [Profile]? {
        guard let root = preferencesPlistRoot() else { return nil }
        return Self.decodeProfiles(fromPlistRoot: root)
    }

    /// Cold-launch fallback for the two display keys.
    ///
    /// Their shadows are empty at launch, so a wedge that is ALREADY present when the
    /// app starts makes `loadDisplayMode()` return `.single` and
    /// `loadMultiProfileConfig()` return `.default` — concentric circles — without
    /// tripping the degraded flag, because an absent read is indistinguishable from a
    /// fresh install until something proves otherwise. The on-disk plist is that
    /// proof. Today a later read repairs this once cfprefsd recovers; it stops being
    /// self-healing the moment a caller hydrates these settings only once per process,
    /// so the repair belongs here rather than in the caller.
    private func displaySettingsFromPreferencesPlist() -> (mode: ProfileDisplayMode?, config: MultiProfileDisplayConfig?)? {
        guard let root = preferencesPlistRoot() else { return nil }
        let mode = (root[Keys.displayMode] as? String).flatMap(ProfileDisplayMode.init(rawValue:))
        let config = (root[Keys.multiProfileConfig] as? Data).flatMap {
            try? JSONDecoder().decode(MultiProfileDisplayConfig.self, from: $0)
        }
        if mode == nil && config == nil { return nil }
        return (mode, config)
    }

    /// Enters (or stays in) a READ degradation episode, logging exactly once.
    private func markPreferencesDegraded(_ reason: String) {
        guard !readDegraded else { return }
        readDegraded = true
        LoggingService.shared.logError("ProfileStore: \(reason)")
        publishDegradedState()
    }

    /// Leaves a read degradation episode after a read that agrees with the shadow.
    private func clearPreferencesDegraded() {
        guard readDegraded else { return }
        readDegraded = false
        LoggingService.shared.log("ProfileStore: preferences reads recovered — serving live values again")
        publishDegradedState()
    }

    /// Enters a WRITE degradation episode: a single-shot key was accepted by the
    /// CFPreferences client and never reached the daemon's store. Called by
    /// `PreferenceWriteJournal`, which owns the pending values and re-asserts them.
    func markPreferenceWriteRejected(key: String) {
        guard !writeDegraded else { return }
        writeDegraded = true
        LoggingService.shared.logError(
            "ProfileStore: preferences write rejected for '\(key)' — cfprefsd took the value in-process but did not persist it; re-asserting from memory every sweep"
        )
        publishDegradedState()
    }

    /// Leaves a write degradation episode once every pending key is on disk.
    func clearPreferenceWriteRejected() {
        guard writeDegraded else { return }
        writeDegraded = false
        LoggingService.shared.log("ProfileStore: preference writes are persisting again")
        publishDegradedState()
    }

    /// Recomputes the combined flag and posts only on a real transition — the
    /// two halves can enter and leave independently.
    private func publishDegradedState() {
        let combined = readDegraded || writeDegraded
        guard combined != preferencesDegraded else { return }
        preferencesDegraded = combined
        NotificationCenter.default.post(name: .preferencesDegradedStateChanged, object: nil)
    }

    // MARK: - Single-shot writes
    //
    // Keys written ONCE, when something changes, rather than on every sweep. A
    // cfprefsd write rejection strands exactly these (audit C3): the per-sweep
    // keys rewrite themselves the moment the episode ends, these never do.
    // `profiles_v3` is deliberately NOT routed here — it is a per-sweep key and
    // its write path already carries the empty-overwrite guard.

    private func writeSingleShot(_ value: Any?, forKey key: String) {
        PreferenceWriteJournal.shared.write(value, forKey: key, in: defaults, owner: .profileStore)
    }

    /// Checks this store's single-shot keys against the preferences store and
    /// rewrites any that are not there. Called once per sweep — the check is
    /// deferred because there is no oracle at write time (see
    /// `PlistPreferenceStoreSnapshot`).
    @discardableResult
    func reassertPendingWrites() -> Int {
        PreferenceWriteJournal.shared.runWriteCheck(owner: .profileStore)
    }

    /// How many profiles this process believes exist, from the cheapest source that
    /// can answer: the shadow, then UserDefaults, then the on-disk plist.
    private func knownProfileCount() -> Int {
        if let known = lastKnownGoodProfiles { return known.count }
        if let data = defaults.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
            return decoded.count
        }
        return profilesFromPreferencesPlist()?.count ?? 0
    }

    init() {
        // Under XCTest, use an isolated suite so test suites can never touch the
        // user's real profiles_v3. A real incident (2026-07-28): a tearDown
        // aborted mid-restore under parallel test hosts and left a test fixture
        // as the user's entire profile roster. Everything else (app container)
        // uses standard UserDefaults.
        let isTestRun = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        self.isTestRun = isTestRun
        if isTestRun, let suite = UserDefaults(suiteName: "com.claudeusagewidget.tests") {
            self.defaults = suite
            LoggingService.shared.log("ProfileStore: Using isolated TEST defaults suite")
        } else {
            self.defaults = UserDefaults.standard
            LoggingService.shared.log("ProfileStore: Using standard app container storage")
            // Cold-launch fallback source. Deliberately NOT set under XCTest: the
            // suite must never read (or be able to write) the real user domain.
            self.preferencesPlistURL = Self.defaultPreferencesPlistURL(
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
        }

        // Populate the credential cache and repair Keychain ACLs if needed.
        bootstrapCredentials()
    }

    // MARK: - Credential Bootstrap & Migration

    /// Populates the in-memory credential cache at startup, and (once) repairs Keychain
    /// item ACLs that may have been invalidated by a code-signature change.
    private func bootstrapCredentials() {
        if defaults.bool(forKey: Keys.credentialsRepairedV2) {
            warmCacheFromKeychain()
        } else {
            runCredentialRepairV2()
        }
    }

    /// v2-already-done path: load credentials from the Keychain into the cache
    /// asynchronously. Never blocks the main thread — readiness is published via
    /// `credentialHydrationState` and `.profileCredentialsReady`.
    private func warmCacheFromKeychain() {
        let ids = storedProfileIds()
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(Self.hydrationWallClockDeadline)

        hydrationGeneration += 1
        let generation = hydrationGeneration
        cacheLock.lock()
        pendingHydrationIds = Set(ids)
        clearedWhilePending.removeAll()
        cacheLock.unlock()

        keychainQueue.async { [weak self] in
            guard let self else { return }
            var success = true
            if !ids.isEmpty {
                success = self.readCredentialsIntoCache(profileIds: ids, deadline: deadline)
            }
            DispatchQueue.main.async {
                self.finishCredentialHydration(success: success, generation: generation)
            }
        }
    }

    /// Transition for a warm attempt (initial, v2 repair, or retry). A
    /// completion from a superseded generation is dropped. Success posts
    /// `.profileCredentialsReady` so ProfileManager reloads; a failure posts
    /// only on the FIRST failure of a run — repeat failures change nothing for
    /// observers, and re-running reload/repaint every backoff period on a
    /// genuinely broken Keychain would be pure churn. Every failure schedules
    /// the next backoff retry, so a deadline trip under transient launch-storm
    /// load heals within minutes instead of persisting all run.
    private func finishCredentialHydration(success: Bool, generation: Int) {
        guard generation == hydrationGeneration else { return }
        if success {
            let healed = credentialHydrationState == .failed
            credentialHydrationState = .ready
            hydrationRetryAttempt = 0
            LoggingService.shared.log(
                "ProfileStore: credential hydration ready\(healed ? " (healed by retry)" : "")"
            )
            NotificationCenter.default.post(name: .profileCredentialsReady, object: nil)
            // One-time v3 rebuild: recreates every item through the security
            // CLI so app rebuilds stop triggering SecurityAgent prompts. It
            // snapshots the cache and latches a once-ever flag, so it may only
            // run off a COMPLETE cache — which is exactly what reaching here
            // proves, for every success path (initial warm, healed retry,
            // everything-already-filled early success). Dispatched after the
            // readiness post so observers are not blocked on the (slow) pass;
            // the generation guard above kept superseded completions out.
            keychainQueue.async { [weak self] in
                self?.rebuildKeychainItemsViaSecurityToolIfNeeded()
            }
        } else {
            let firstFailure = hydrationRetryAttempt == 0
            credentialHydrationState = .failed
            LoggingService.shared.logError(
                "ProfileStore: credential hydration failed — proceeding with partial cache"
            )
            scheduleHydrationRetry()
            if firstFailure {
                NotificationCenter.default.post(name: .profileCredentialsReady, object: nil)
            }
        }
    }

    /// Queues one re-warm attempt after the backoff delay. No-op while a retry
    /// is already pending, and never armed under XCTest (suites stay
    /// deterministic; tests drive `retryHydrationForMissingProfiles` directly).
    private func scheduleHydrationRetry() {
        guard !isTestRun, !hydrationRetryScheduled else { return }
        hydrationRetryScheduled = true
        let delay = Self.hydrationRetryDelay(afterAttempt: hydrationRetryAttempt)
        hydrationRetryAttempt += 1
        LoggingService.shared.log(
            "ProfileStore: retrying credential hydration in \(Int(delay))s (attempt \(hydrationRetryAttempt))"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.hydrationRetryScheduled = false
            self.retryHydrationForMissingProfiles()
        }
    }

    /// Re-reads the Keychain for profiles still in `pendingHydrationIds` after
    /// a `.failed` warm. Internal (not private) so tests can drive the healing
    /// path and assert the not-`.failed` guard; production entry is the
    /// backoff timer only.
    ///
    /// The pending SET — not cache-entry absence — is the work list, because
    /// merge-on-save mints an all-nil entry for every unhydrated profile the
    /// moment anything saves the full roster (token-refresh persists do,
    /// every sweep). Judging by entry absence would let a routine save empty
    /// the work list and convert the retry into a false `.ready`.
    func retryHydrationForMissingProfiles() {
        guard credentialHydrationState == .failed else { return }
        let stored = Set(storedProfileIds())
        cacheLock.lock()
        // Prune profiles deleted since the warm; keep the set authoritative.
        pendingHydrationIds.formIntersection(stored)
        let missing = Array(pendingHydrationIds)
        cacheLock.unlock()
        let generation = hydrationGeneration
        guard !missing.isEmpty else {
            // Every profile's read completed (or the profile is gone) — whole.
            finishCredentialHydration(success: true, generation: generation)
            return
        }
        LoggingService.shared.log(
            "ProfileStore: credential hydration retry — reading \(missing.count) missing profile(s)"
        )
        let deadline = Date().addingTimeInterval(Self.hydrationWallClockDeadline)
        keychainQueue.async { [weak self] in
            guard let self else { return }
            let success = self.readCredentialsIntoCache(profileIds: missing, deadline: deadline)
            DispatchQueue.main.async {
                self.finishCredentialHydration(success: success, generation: generation)
            }
        }
    }

    /// Test-only: reconstructs the incident state — profiles whose Keychain
    /// read never completed (deadline trip mid-loop). Clears the given ids'
    /// cache entries, marks them pending, and sets `.failed`, exactly as an
    /// aborted warm leaves them.
    func simulatePartialHydrationForTesting(unreadIds: [UUID]) {
        cacheLock.lock()
        for id in unreadIds {
            credentialCache.removeValue(forKey: id)
            bumpCredentialRevision(id)
        }
        pendingHydrationIds.formUnion(unreadIds)
        cacheLock.unlock()
        credentialHydrationState = .failed
    }

    /// Clears the in-memory credential cache and re-runs async Keychain hydration.
    /// Used by tests that need a real `.loading` → `.ready` transition without
    /// constructing a second ProfileStore singleton.
    func resetAndRewarmCredentialCacheForTesting() {
        cacheLock.lock()
        credentialCache.removeAll()
        cacheLock.unlock()
        credentialHydrationState = .loading
        warmCacheFromKeychain()
    }

    /// One-time (v3): rebuilds every per-profile Keychain item through the
    /// security CLI. Items created by SecItemAdd carry a partition list stamped
    /// with the cdhash of whichever build created them; because this app is
    /// ad-hoc signed, EVERY rebuild has a new cdhash, fails the partition check,
    /// and raises one SecurityAgent prompt PER ITEM — "Always Allow" only
    /// whitelists the clicking build, which is why it never stuck. Items created
    /// by /usr/bin/security live in the `apple-tool:` partition and are readable
    /// by the security CLI forever, regardless of this app's signature; all
    /// KeychainService reads/writes now go through that CLI.
    ///
    /// Runs on keychainQueue AFTER the cache hydration, so every value is in
    /// memory: per item we add a backup copy first, then delete + re-add the
    /// canonical item, verify it reads back, and only then drop the backup — a
    /// crash mid-migration can always be recovered from on the next run.
    private func rebuildKeychainItemsViaSecurityToolIfNeeded() {
        guard !defaults.bool(forKey: Keys.keychainRebuiltV3) else { return }

        // Only profiles that still EXIST: an in-flight hydration read can
        // repopulate the cache entry of a profile deleted mid-warm (its
        // Keychain deletion is queued separately), and rebuilding from that
        // ghost entry would re-create the deleted profile's Keychain items.
        let storedIds = Set(storedProfileIds())
        cacheLock.lock()
        var snapshot = credentialCache.filter { storedIds.contains($0.key) }
        cacheLock.unlock()

        // Recover from a crash in a PREVIOUS migration run: a value whose backup
        // item exists but whose canonical read came back empty was caught between
        // delete and re-add — restore it from the backup before rebuilding.
        for profileId in snapshot.keys {
            for key in CredentialKey.allCases {
                let current = snapshot[profileId]?[key]
                guard current == nil,
                      let backup = keychainService.loadProfileCredential(profileId: profileId, key: key.rawValue + "-v3bak") else {
                    continue
                }
                LoggingService.shared.log("ProfileStore: recovered \(key.rawValue) for \(profileId.uuidString.prefix(8)) from v3 migration backup")
                snapshot[profileId]?[key] = backup
                cacheLock.lock()
                credentialCache[profileId]?[key] = backup
                bumpCredentialRevision(profileId)
                cacheLock.unlock()
            }
        }

        var rebuilt = 0
        var failed = 0
        for (profileId, creds) in snapshot {
            let values: [(CredentialKey, String?)] = [
                (.claudeSessionKey, creds.claudeSessionKey),
                (.apiSessionKey, creds.apiSessionKey),
                (.cliCredentials, creds.cliCredentialsJSON),
                (.codexCredentials, creds.codexCredentialsJSON),
                (.grokCredentials, creds.grokCredentialsJSON)
            ]
            for (key, value) in values {
                guard let value else { continue }
                let backupKey = key.rawValue + "-v3bak"
                keychainService.saveProfileCredential(value, profileId: profileId, key: backupKey)
                keychainService.deleteProfileCredential(profileId: profileId, key: key.rawValue)
                keychainService.saveProfileCredential(value, profileId: profileId, key: key.rawValue)
                if keychainService.loadProfileCredential(profileId: profileId, key: key.rawValue) == value {
                    keychainService.deleteProfileCredential(profileId: profileId, key: backupKey)
                    rebuilt += 1
                } else {
                    // Restore from the in-memory value and leave the flag unset so
                    // the next launch retries this item.
                    keychainService.saveProfileCredential(value, profileId: profileId, key: key.rawValue)
                    failed += 1
                    LoggingService.shared.logError("ProfileStore: v3 keychain rebuild verify failed for \(key.rawValue) (\(profileId.uuidString.prefix(8)))")
                }
            }
        }

        if failed == 0 {
            defaults.set(true, forKey: Keys.keychainRebuiltV3)
            LoggingService.shared.log("ProfileStore: rebuilt \(rebuilt) Keychain item(s) via security CLI (v3) — rebuild prompts are gone for good")
        } else {
            LoggingService.shared.logError("ProfileStore: v3 keychain rebuild incomplete (\(rebuilt) ok, \(failed) failed) — will retry next launch")
        }
    }

    /// First run on a build with the new storage model. Recovers credentials from the
    /// legacy plaintext JSON (no Keychain access needed), strips the plaintext leak, and
    /// repairs Keychain items in the background — deleting each item (which drops the
    /// stale, signature-bound ACL) and re-adding it with a permissive ACL.
    private func runCredentialRepairV2() {
        // This path replaces the Keychain warm on first run: the whole cache is
        // recovered synchronously from the legacy JSON below, so no profile is
        // ever hydration-pending and the completion is generation-stamped like
        // any other warm.
        hydrationGeneration += 1
        let generation = hydrationGeneration
        cacheLock.lock()
        pendingHydrationIds.removeAll()
        clearedWhilePending.removeAll()
        cacheLock.unlock()

        // 1. Recover secrets from the legacy plaintext JSON (synchronous, no Keychain).
        var recovered: [UUID: CachedCredentials] = [:]
        if let data = defaults.data(forKey: Keys.profiles),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for dict in array {
                guard let idString = dict["id"] as? String,
                      let id = UUID(uuidString: idString) else { continue }
                recovered[id] = CachedCredentials(
                    claudeSessionKey: nonEmptyString(dict["claudeSessionKey"]),
                    apiSessionKey: nonEmptyString(dict["apiSessionKey"]),
                    cliCredentialsJSON: nonEmptyString(dict["cliCredentialsJSON"])
                )
            }
        }

        cacheLock.lock()
        credentialCache = recovered
        cacheLock.unlock()

        // 2. Strip plaintext secrets from the stored JSON immediately (privacy fix).
        stripPlaintextCredentialsFromStoredJSON()

        // 3. Repair Keychain ACLs in the background. A prompt here cannot deadlock the
        //    UI — it runs on a background queue.
        let ids = Array(recovered.keys)
        keychainQueue.async { [weak self] in
            guard let self else { return }
            for id in ids {
                var creds = recovered[id] ?? CachedCredentials()
                // For any secret missing from the JSON, recover it from the existing
                // Keychain item before the item is deleted.
                if creds.claudeSessionKey == nil {
                    creds.claudeSessionKey = self.keychainService.loadProfileCredential(profileId: id, key: "claude-key")
                }
                if creds.apiSessionKey == nil {
                    creds.apiSessionKey = self.keychainService.loadProfileCredential(profileId: id, key: "api-key")
                }
                if creds.cliCredentialsJSON == nil {
                    creds.cliCredentialsJSON = self.keychainService.loadProfileCredential(profileId: id, key: "cli-creds")
                }
                // Delete (drops the stale ACL) then re-add with a permissive ACL.
                self.keychainService.deleteProfileCredentials(profileId: id)
                self.writeCredentialItems(profileId: id, credentials: creds)

                self.cacheLock.lock()
                self.credentialCache[id] = creds
                self.cacheLock.unlock()
                self.bumpCredentialRevision(id)
            }
            self.defaults.set(true, forKey: Keys.credentialsRepairedV2)
            // Items were just (re)written through the security CLI, so they are
            // already partition-safe — no separate v3 rebuild needed.
            self.defaults.set(true, forKey: Keys.keychainRebuiltV3)
            LoggingService.shared.log("ProfileStore: Keychain credential repair (v2) complete for \(ids.count) profile(s)")
            DispatchQueue.main.async {
                // v2 repair is the first-run hydration path — mark ready and notify
                // the same way warmCacheFromKeychain does.
                self.finishCredentialHydration(success: true, generation: generation)
            }
        }
    }

    /// Reads each profile's credential items from the Keychain into the cache.
    /// Returns `false` if the wall-clock deadline was exceeded mid-loop (partial
    /// cache is still better than none — caller marks `.failed` and notifies).
    @discardableResult
    private func readCredentialsIntoCache(profileIds: [UUID], deadline: Date) -> Bool {
        for id in profileIds {
            if Date() > deadline {
                LoggingService.shared.logError(
                    "ProfileStore: credential hydration hit \(Int(Self.hydrationWallClockDeadline))s deadline with partial cache"
                )
                return false
            }
            let read = CachedCredentials(
                claudeSessionKey: keychainService.loadProfileCredential(profileId: id, key: "claude-key"),
                apiSessionKey: keychainService.loadProfileCredential(profileId: id, key: "api-key"),
                cliCredentialsJSON: keychainService.loadProfileCredential(profileId: id, key: "cli-creds"),
                codexCredentialsJSON: keychainService.loadProfileCredential(profileId: id, key: "codex-creds"),
                grokCredentialsJSON: keychainService.loadProfileCredential(profileId: id, key: "grok-creds")
            )
            cacheLock.lock()
            // Per-field merge, in-memory value first: a credential that landed
            // in the cache while these five slow reads ran (user-driven sync,
            // activation, adoption) can be NEWER than its Keychain item — the
            // rotated-token Keychain write is queued BEHIND this very read on
            // keychainQueue — and replacing it with the Keychain snapshot
            // re-introduces the consumed-refresh-token class. Same semantics
            // as merge-on-save: memory wins per field, the read only fills
            // gaps. All-nil minted entries contribute nothing and are filled —
            // EXCEPT a field the user explicitly cleared mid-read, whose
            // tombstone keeps the intentional nil from being resurrected.
            let existing = credentialCache[id]
            func fill(_ memory: String?, _ disk: String?, _ key: CredentialKey) -> String? {
                if clearedWhilePending.contains(.init(profileId: id, key: key)) { return memory }
                return memory ?? disk
            }
            credentialCache[id] = CachedCredentials(
                claudeSessionKey: fill(existing?.claudeSessionKey, read.claudeSessionKey, .claudeSessionKey),
                apiSessionKey: fill(existing?.apiSessionKey, read.apiSessionKey, .apiSessionKey),
                cliCredentialsJSON: fill(existing?.cliCredentialsJSON, read.cliCredentialsJSON, .cliCredentials),
                codexCredentialsJSON: fill(existing?.codexCredentialsJSON, read.codexCredentialsJSON, .codexCredentials),
                grokCredentialsJSON: fill(existing?.grokCredentialsJSON, read.grokCredentialsJSON, .grokCredentials)
            )
            pendingHydrationIds.remove(id)
            clearedWhilePending = clearedWhilePending.filter { $0.profileId != id }
            bumpCredentialRevision(id)
            cacheLock.unlock()
        }
        return true
    }

    /// Removes the three credential keys from the stored profiles JSON.
    private func stripPlaintextCredentialsFromStoredJSON() {
        guard let data = defaults.data(forKey: Keys.profiles),
              var array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        var changed = false
        for i in array.indices {
            for key in ["claudeSessionKey", "apiSessionKey", "cliCredentialsJSON"] {
                if array[i].removeValue(forKey: key) != nil { changed = true }
            }
        }
        guard changed,
              let cleaned = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted]) else {
            return
        }
        defaults.set(cleaned, forKey: Keys.profiles)
        LoggingService.shared.log("ProfileStore: Stripped plaintext credentials from stored profiles JSON")
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Profile ids to hydrate credentials for. Falls through to the last-known-good
    /// shadow and then the on-disk plist: a cfprefsd wedge at launch would otherwise
    /// return an empty id list, and hydration would settle `.ready` over an empty
    /// cache — every tile credential-less for the rest of the run.
    private func storedProfileIds() -> [UUID] {
        if let data = defaults.data(forKey: Keys.profiles),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let ids = array.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
            if !ids.isEmpty { return ids }
        }
        if let known = lastKnownGoodProfiles, !known.isEmpty {
            return known.map(\.id)
        }
        return profilesFromPreferencesPlist()?.map(\.id) ?? []
    }

    // MARK: - Profile Management

    /// Usage-only field update for a single profile. `nil` means "leave this field alone"
    /// (not "clear it"). Patches never carry credentials.
    struct UsagePatch {
        var claudeUsage: ClaudeUsage?
        var apiUsage: APIUsage?
    }

    /// Atomically patches usage fields on the CURRENT persisted profile array.
    ///
    /// Decodes from defaults, sets only non-nil usage fields by UUID, encodes, and
    /// writes back. NEVER touches the credential cache, enqueues Keychain work,
    /// calls `saveProfiles`, or accepts a caller-supplied `[Profile]` — a stale
    /// reconstructed array could overwrite a concurrent credential rotation
    /// (`saveProfiles` merge only protects against nil, not stale non-nil).
    ///
    /// Note: persisted JSON already excludes credentials (`Profile.CodingKeys`), so
    /// decode → patch usage → encode inherently cannot write secrets; the forbidden
    /// list above is belt-and-suspenders against future regressions.
    func applyUsagePatches(_ patches: [UUID: UsagePatch]) {
        guard !patches.isEmpty else { return }

        guard let data = defaults.data(forKey: Keys.profiles) else {
            LoggingService.shared.log("ProfileStore: applyUsagePatches skipped — no profiles in storage")
            return
        }

        do {
            // Decode the CURRENT persisted array (not any caller-supplied snapshot).
            var profiles = try JSONDecoder().decode([Profile].self, from: data)
            var applied = 0

            for (id, patch) in patches {
                guard let index = profiles.firstIndex(where: { $0.id == id }) else { continue }
                if let claudeUsage = patch.claudeUsage {
                    profiles[index].claudeUsage = claudeUsage
                }
                if let apiUsage = patch.apiUsage {
                    profiles[index].apiUsage = apiUsage
                }
                applied += 1
            }

            // Always re-encode when at least one UUID matched so a no-op unknown-id
            // patch set does not rewrite storage needlessly.
            if applied > 0 {
                let encoder = JSONEncoder()
                let encoded = try encoder.encode(profiles)
                defaults.set(encoded, forKey: Keys.profiles)
            }

            LoggingService.shared.log("ProfileStore: applied \(applied) usage patches")
        } catch {
            LoggingService.shared.logStorageError("applyUsagePatches", error: error)
        }
    }

    /// Persists the roster. `allowEmpty` must be `true` for a deliberate delete-all —
    /// see the empty-overwrite guard below.
    func saveProfiles(_ profiles: [Profile], allowEmpty: Bool = false) {
        // 0. EMPTY-OVERWRITE GUARD. An empty array reaching here is nearly always a
        //    read that failed (a wedged cfprefsd hands every caller nil), not a user
        //    who deleted everything — `ProfileManager.deleteProfile` refuses to delete
        //    the last profile, so no in-app path legitimately produces an empty
        //    roster today. Persisting it once the daemon recovers would destroy the
        //    real one.
        if profiles.isEmpty && !allowEmpty {
            let known = knownProfileCount()
            if known > 0 {
                LoggingService.shared.logError(
                    "ProfileStore: refusing to persist an empty profile list while \(known) profiles are known — pass allowEmpty: true for a deliberate delete-all"
                )
                return
            }
        }

        // 1. Sync credentials into the in-memory cache; persist changes to the
        //    Keychain on a background queue (never blocks the caller).
        //
        //    MERGE semantics: a nil credential field NEVER implies deletion here.
        //    Profile values may predate the background Keychain hydration
        //    (`credentialHydrationState == .loading`) — saving such a stale profile
        //    used to diff nil-vs-cached and enqueue Keychain deletions, silently
        //    destroying every credential on a slow Keychain. Intentional removal
        //    goes through clearProfileCredential(_:key:) instead.
        for profile in profiles {
            let incoming = CachedCredentials(
                claudeSessionKey: profile.claudeSessionKey,
                apiSessionKey: profile.apiSessionKey,
                cliCredentialsJSON: profile.cliCredentialsJSON,
                codexCredentialsJSON: profile.codexCredentialsJSON,
                grokCredentialsJSON: profile.grokCredentialsJSON
            )

            cacheLock.lock()
            let old = credentialCache[profile.id]
            let merged = CachedCredentials(
                claudeSessionKey: incoming.claudeSessionKey ?? old?.claudeSessionKey,
                apiSessionKey: incoming.apiSessionKey ?? old?.apiSessionKey,
                cliCredentialsJSON: incoming.cliCredentialsJSON ?? old?.cliCredentialsJSON,
                codexCredentialsJSON: incoming.codexCredentialsJSON ?? old?.codexCredentialsJSON,
                grokCredentialsJSON: incoming.grokCredentialsJSON ?? old?.grokCredentialsJSON
            )
            credentialCache[profile.id] = merged
            if merged != old {
                bumpCredentialRevision(profile.id)
            }
            cacheLock.unlock()

            if merged != incoming {
                LoggingService.shared.log("ProfileStore: preserved cached credential(s) for \(profile.id) that the saved profile was missing (stale pre-hydration copy?)")
            }

            if merged != old {
                let profileId = profile.id
                keychainQueue.async { [weak self] in
                    self?.writeCredentialItems(profileId: profileId, credentials: merged)
                }
            }
        }

        // 2. Encode profiles WITHOUT credentials (Profile.CodingKeys excludes them),
        //    so the JSON written to UserDefaults contains NO secrets.
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(profiles)
            defaults.set(data, forKey: Keys.profiles)
            // The shadow tracks what this process believes, so a subsequent empty read
            // is recognised as degraded rather than adopted as truth. An empty array
            // only reaches here with `allowEmpty`, and recording it (rather than
            // leaving the shadow nil) is what stops the fallbacks from resurrecting
            // profiles the user deliberately deleted.
            lastKnownGoodProfiles = profiles
            LoggingService.shared.log("ProfileStore: Saved \(profiles.count) profiles (\(data.count) bytes, credentials in Keychain)")
        } catch {
            LoggingService.shared.logStorageError("saveProfiles", error: error)
        }
    }

    /// Suspends until every Keychain write queued so far has been committed.
    /// Call after persisting a ROTATED refresh token: the old token is already
    /// consumed at the provider, so process death before the queue drains would
    /// lose the only working login for that account.
    func flushKeychainWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            keychainQueue.async { continuation.resume() }
        }
    }

    func loadProfiles() -> [Profile] {
        var decoded: [Profile]?

        if let data = defaults.data(forKey: Keys.profiles) {
            do {
                // Credential fields are nil here (excluded from Profile.CodingKeys).
                decoded = try JSONDecoder().decode([Profile].self, from: data)
            } catch {
                LoggingService.shared.logStorageError("loadProfiles", error: error)
                decoded = nil
            }
        }

        if let decoded, !decoded.isEmpty {
            clearPreferencesDegraded()
            lastKnownGoodProfiles = decoded
            return hydrated(decoded, source: "storage")
        }

        // Empty or undecodable. Serve the shadow rather than emptying the UI — unless
        // the shadow itself is empty, which only an explicit `allowEmpty` delete-all
        // produces. That is a real roster, so it is returned as-is and no fallback
        // (cache or plist) may resurrect the deleted profiles.
        if let cached = lastKnownGoodProfiles {
            if cached.isEmpty {
                clearPreferencesDegraded()
                return []
            }
            markPreferencesDegraded(
                "preferences read returned empty while \(cached.count) profiles are known — cfprefsd degraded, serving cached profiles"
            )
            return hydrated(cached, source: "last-known-good cache")
        }

        // Nothing known yet this process: cold launch. Try the on-disk plist, which
        // survives a cfprefsd wedge intact.
        if let fromDisk = profilesFromPreferencesPlist() {
            markPreferencesDegraded(
                "UserDefaults yielded no profiles but the on-disk preferences plist holds \(fromDisk.count) — cfprefsd degraded, decoding from disk"
            )
            lastKnownGoodProfiles = fromDisk
            return hydrated(fromDisk, source: "on-disk preferences plist")
        }

        LoggingService.shared.log("ProfileStore: No profiles found in storage")
        return []
    }

    /// Fills credentials from the in-memory cache (never the Keychain on this thread).
    private func hydrated(_ profiles: [Profile], source: String) -> [Profile] {
        var copy = profiles
        for i in copy.indices {
            hydrateCredentialsFromCache(for: &copy[i])
        }
        LoggingService.shared.log("ProfileStore: Loaded \(copy.count) profiles from \(source) (credentials from cache)")
        return copy
    }

    func saveActiveProfileId(_ id: UUID) {
        writeSingleShot(id.uuidString, forKey: Keys.activeProfileId)
        lastKnownGoodActiveProfileId = .some(id)
    }

    func loadActiveProfileId() -> UUID? {
        loadPointer(
            key: Keys.activeProfileId,
            shadow: &lastKnownGoodActiveProfileId,
            label: "activeProfileId"
        )
    }

    /// Shared read path for the three active-profile pointers.
    ///
    /// A nil read is ambiguous — it means either "genuinely unset" or "cfprefsd is
    /// refusing to answer". The shadow disambiguates: it is written by every save
    /// (including a deliberate `save…(nil)`), so a nil read is only overridden when
    /// this process last observed a real id.
    private func loadPointer(key: String, shadow: inout UUID??, label: String) -> UUID? {
        let live = defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
        if let live {
            shadow = .some(live)
            return live
        }
        if case .some(.some(let cached)) = shadow {
            markPreferencesDegraded(
                "preferences read returned no \(label) while \(cached) was previously loaded — cfprefsd degraded, serving cached value"
            )
            return cached
        }
        shadow = .some(nil)
        return nil
    }

    // MARK: - Per-Provider Active Accounts
    // Two accounts are "active" at any time — one Claude (owns the Claude Code CLI
    // Keychain login) and one Codex (owns ~/.codex/auth.json). Switching a profile
    // of one provider must never disturb the other provider's active account.

    func saveActiveClaudeProfileId(_ id: UUID?) {
        writeSingleShot(id?.uuidString, forKey: Keys.activeClaudeProfileId)
        lastKnownGoodActiveClaudeProfileId = .some(id)
    }

    func loadActiveClaudeProfileId() -> UUID? {
        loadPointer(
            key: Keys.activeClaudeProfileId,
            shadow: &lastKnownGoodActiveClaudeProfileId,
            label: "activeClaudeProfileId"
        )
    }

    func saveActiveCodexProfileId(_ id: UUID?) {
        writeSingleShot(id?.uuidString, forKey: Keys.activeCodexProfileId)
        lastKnownGoodActiveCodexProfileId = .some(id)
    }

    func loadActiveCodexProfileId() -> UUID? {
        loadPointer(
            key: Keys.activeCodexProfileId,
            shadow: &lastKnownGoodActiveCodexProfileId,
            label: "activeCodexProfileId"
        )
    }

    /// The profile that owns ~/.grok/auth.json — the third provider's shared CLI
    /// login, symmetric with the two above. Same single-shot journaling and same
    /// last-known-good shadow: it is written ONCE when ownership changes, which
    /// is exactly the class of key a cfprefsd write rejection strands (audit C3).
    func saveActiveGrokProfileId(_ id: UUID?) {
        writeSingleShot(id?.uuidString, forKey: Keys.activeGrokProfileId)
        lastKnownGoodActiveGrokProfileId = .some(id)
    }

    func loadActiveGrokProfileId() -> UUID? {
        loadPointer(
            key: Keys.activeGrokProfileId,
            shadow: &lastKnownGoodActiveGrokProfileId,
            label: "activeGrokProfileId"
        )
    }

    func saveDisplayMode(_ mode: ProfileDisplayMode) {
        writeSingleShot(mode.rawValue, forKey: Keys.displayMode)
        lastKnownGoodDisplayMode = mode
    }

    /// A wedged read must not silently demote a multi-profile menu bar back to
    /// `.single` — that empties the tile group exactly as an empty roster does.
    func loadDisplayMode() -> ProfileDisplayMode {
        if let rawValue = defaults.string(forKey: Keys.displayMode),
           let mode = ProfileDisplayMode(rawValue: rawValue) {
            lastKnownGoodDisplayMode = mode
            return mode
        }
        if let cached = lastKnownGoodDisplayMode {
            markPreferencesDegraded(
                "preferences read returned no display mode while '\(cached.rawValue)' was previously loaded — cfprefsd degraded, serving cached value"
            )
            return cached
        }
        // Cold launch: nothing in the shadow yet, so fall through to disk.
        if let fromDisk = displaySettingsFromPreferencesPlist()?.mode {
            markPreferencesDegraded(
                "UserDefaults yielded no display mode but the on-disk preferences plist holds '\(fromDisk.rawValue)' — cfprefsd degraded, reading from disk"
            )
            lastKnownGoodDisplayMode = fromDisk
            return fromDisk
        }
        return .single
    }

    // MARK: - Multi-Profile Display Config

    func saveMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            writeSingleShot(data, forKey: Keys.multiProfileConfig)
            lastKnownGoodMultiProfileConfig = config
        } catch {
            LoggingService.shared.logStorageError("saveMultiProfileConfig", error: error)
        }
    }

    /// Falling back to `.default` here is what repainted the saved `.progressBar`
    /// tiles as `.concentric` circles during the 2026-09-01 wedge — the visible
    /// half of "the app crashed". Serve the last value this process loaded instead.
    func loadMultiProfileConfig() -> MultiProfileDisplayConfig {
        if let data = defaults.data(forKey: Keys.multiProfileConfig) {
            do {
                let config = try JSONDecoder().decode(MultiProfileDisplayConfig.self, from: data)
                lastKnownGoodMultiProfileConfig = config
                return config
            } catch {
                LoggingService.shared.logStorageError("loadMultiProfileConfig", error: error)
            }
        }
        if let cached = lastKnownGoodMultiProfileConfig {
            markPreferencesDegraded(
                "preferences read returned no multi-profile display config while one was previously loaded — cfprefsd degraded, serving cached value"
            )
            return cached
        }
        // Cold launch: nothing in the shadow yet, so fall through to disk. This is the
        // read that painted circles over a saved progressBar config all day.
        if let fromDisk = displaySettingsFromPreferencesPlist()?.config {
            markPreferencesDegraded(
                "UserDefaults yielded no multi-profile display config but the on-disk preferences plist holds one (\(fromDisk.iconStyle.rawValue)) — cfprefsd degraded, reading from disk"
            )
            lastKnownGoodMultiProfileConfig = fromDisk
            return fromDisk
        }
        return .default
    }

    // MARK: - Credential Helpers

    func saveProfileCredentials(_ profileId: UUID, credentials: ProfileCredentials) throws {
        var profiles = loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw NSError(domain: "ProfileStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Profile not found"])
        }

        // Update credential fields on the in-memory profile
        profiles[index].claudeSessionKey = credentials.claudeSessionKey
        profiles[index].organizationId = credentials.organizationId
        profiles[index].apiSessionKey = credentials.apiSessionKey
        profiles[index].apiOrganizationId = credentials.apiOrganizationId
        profiles[index].cliCredentialsJSON = credentials.cliCredentialsJSON
        profiles[index].codexCredentialsJSON = credentials.codexCredentialsJSON
        profiles[index].grokCredentialsJSON = credentials.grokCredentialsJSON

        // saveProfiles persists credentials to the Keychain (cache + background queue)
        // and non-credential data to UserDefaults.
        saveProfiles(profiles)
    }

    func loadProfileCredentials(_ profileId: UUID) throws -> ProfileCredentials {
        let profiles = loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileId }) else {
            throw NSError(domain: "ProfileStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Profile not found"])
        }

        // Credentials have already been hydrated from the cache by loadProfiles()
        return ProfileCredentials(
            claudeSessionKey: profile.claudeSessionKey,
            organizationId: profile.organizationId,
            apiSessionKey: profile.apiSessionKey,
            apiOrganizationId: profile.apiOrganizationId,
            apiSessionKeyExpiry: profile.apiSessionKeyExpiry,
            cliCredentialsJSON: profile.cliCredentialsJSON,
            codexCredentialsJSON: profile.codexCredentialsJSON,
            grokCredentialsJSON: profile.grokCredentialsJSON
        )
    }

    // MARK: - Private Keychain Helpers

    /// Deletes all Keychain credentials for a given profile (called when a profile is
    /// deleted) and drops it from the in-memory cache.
    func deleteProfileCredentials(profileId: UUID) {
        cacheLock.lock()
        credentialCache.removeValue(forKey: profileId)
        cacheLock.unlock()

        keychainQueue.async { [weak self] in
            self?.keychainService.deleteProfileCredentials(profileId: profileId)
        }
    }

    /// Writes a profile's non-nil credentials to the Keychain. Nil fields are left
    /// untouched — deletion is only ever explicit (clearProfileCredential /
    /// deleteProfileCredentials). MUST be called on `keychainQueue`.
    private func writeCredentialItems(profileId: UUID, credentials: CachedCredentials) {
        syncCredentialItem(credentials.claudeSessionKey, profileId: profileId, key: CredentialKey.claudeSessionKey.rawValue)
        syncCredentialItem(credentials.apiSessionKey, profileId: profileId, key: CredentialKey.apiSessionKey.rawValue)
        syncCredentialItem(credentials.cliCredentialsJSON, profileId: profileId, key: CredentialKey.cliCredentials.rawValue)
        syncCredentialItem(credentials.codexCredentialsJSON, profileId: profileId, key: CredentialKey.codexCredentials.rawValue)
        syncCredentialItem(credentials.grokCredentialsJSON, profileId: profileId, key: CredentialKey.grokCredentials.rawValue)
    }

    private func syncCredentialItem(_ value: String?, profileId: UUID, key: String) {
        if let value {
            keychainService.saveProfileCredential(value, profileId: profileId, key: key)
        }
    }

    /// Explicitly removes ONE credential from a profile — the only way a single
    /// credential leaves the Keychain. Drops it from the in-memory cache
    /// immediately and deletes the Keychain item on the background queue.
    func clearProfileCredential(_ profileId: UUID, key: CredentialKey) {
        cacheLock.lock()
        var cached = credentialCache[profileId] ?? CachedCredentials()
        switch key {
        case .claudeSessionKey: cached.claudeSessionKey = nil
        case .apiSessionKey: cached.apiSessionKey = nil
        case .cliCredentials: cached.cliCredentialsJSON = nil
        case .codexCredentials: cached.codexCredentialsJSON = nil
        case .grokCredentials: cached.grokCredentialsJSON = nil
        }
        credentialCache[profileId] = cached
        // A read for a still-pending profile may be in flight and would
        // otherwise resurrect this field from the Keychain snapshot (the item
        // delete below queues BEHIND that read). Tombstone the explicit nil.
        if pendingHydrationIds.contains(profileId) {
            clearedWhilePending.insert(.init(profileId: profileId, key: key))
        }
        bumpCredentialRevision(profileId)
        cacheLock.unlock()

        keychainQueue.async { [weak self] in
            self?.deleteKeychainCredential(profileId: profileId, key: key.rawValue)
        }
        LoggingService.shared.log("ProfileStore: cleared credential '\(key.rawValue)' for profile \(profileId)")
    }

    /// Deletes a single Keychain credential entry for a profile.
    private func deleteKeychainCredential(profileId: UUID, key: String) {
        let service = "com.claudewidget.\(key)-\(profileId.uuidString)"
        let account = "profile-credential"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }

    /// Loads credentials from the in-memory cache into the profile's fields.
    private func hydrateCredentialsFromCache(for profile: inout Profile) {
        cacheLock.lock()
        let cached = credentialCache[profile.id]
        cacheLock.unlock()

        profile.claudeSessionKey = cached?.claudeSessionKey
        profile.apiSessionKey = cached?.apiSessionKey
        profile.cliCredentialsJSON = cached?.cliCredentialsJSON
        profile.codexCredentialsJSON = cached?.codexCredentialsJSON
        profile.grokCredentialsJSON = cached?.grokCredentialsJSON
    }
}
