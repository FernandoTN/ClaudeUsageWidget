//
//  TelemetryLedger.swift
//  Claude Usage
//
//  The token-consumption archive: a SQLite database (the system `SQLite3`
//  library — no dependency) under
//  ~/Library/Application Support/Claude Usage/telemetry/. It is the ARCHIVE,
//  not a cache: Claude Code deletes transcripts after 30 days, so what is
//  indexed here is the only copy. Never UserDefaults (cfprefsd degrades),
//  never rebuilt from scratch.
//
//  Why a database and not append-only JSONL (spec §2.2, consult §8): the
//  ledger needs a unique unit key — Claude messages finish across ticks and
//  are upserted, a shrunken or moved source file is re-read, a crash replays a
//  slice — and one transaction covering the events, the markers and the
//  cursor advance. Rollups are derived from this table, never stored as truth.
//
//  Schema v2 (2026-09-03): the first deploy measured ~470 B/event on v1 because
//  every row repeated its file id (a ~100-char relative path), the session
//  uuid and the project slug as text. v2 interns those three into `strings`
//  and stores integer refs; a v1 ledger is migrated in place on first open.
//
//  Threading: every call happens on ONE serial utility queue owned by
//  TelemetryService. The class is `nonisolated` (load-bearing under the
//  MainActor default) and `@unchecked Sendable` because that queue is the
//  synchronisation; it is never touched from the main actor.
//

import Foundation
import os
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated final class TelemetryLedger: @unchecked Sendable {

    struct LedgerError: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    /// 3 adds the `minutes` and `compacted` tables (stage 4c); no data moves.
    static let schemaVersion = 3
    /// WAL cap; a checkpoint after every catch-up run truncates it.
    static let journalSizeLimit = 64 << 20

    let url: URL
    private var db: OpaquePointer?
    private var transactionDepth = 0
    private var internCache: [String: Int64] = [:]
    /// Per file, the newest event time already folded into `minutes`: a
    /// replay of older units (a lost cursor, a moved file) is dropped rather
    /// than counted twice. Loaded at open, refreshed after every compaction.
    private var compactedThrough: [Int64: Double] = [:]

    /// Opens (creating the directory `0700` and the files `0600`) and migrates.
    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw LedgerError(code: rc, message: message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2_000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA journal_size_limit=\(Self.journalSizeLimit)")
        try createSchema()
        try reloadCompactionWatermarks()
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Schema

    private static let eventsDDL = """
    CREATE TABLE IF NOT EXISTS events (
        unit_id TEXT PRIMARY KEY, provider TEXT NOT NULL, at REAL NOT NULL, model TEXT NOT NULL,
        input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
        cache_write_1h INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL,
        cost_nano INTEGER, session_ref INTEGER NOT NULL, sidechain INTEGER NOT NULL, source_ref INTEGER,
        file_ref INTEGER NOT NULL, source_offset INTEGER NOT NULL, parser_version INTEGER NOT NULL,
        in_flight INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS events_provider_at ON events(provider, at);
    CREATE INDEX IF NOT EXISTS events_at ON events(at);
    CREATE INDEX IF NOT EXISTS events_file ON events(file_ref);
    """

    /// Stage 4c: raw events older than the compaction age fold into one row
    /// per (provider, UTC minute, model, source, sidechain, session) — every
    /// key the report, the Codex session count and the time span read —
    /// and `compacted` remembers per file how far that has gone.
    private static let minutesDDL = """
    CREATE TABLE IF NOT EXISTS minutes (
        provider TEXT NOT NULL, minute INTEGER NOT NULL, model TEXT NOT NULL, source_ref INTEGER NOT NULL,
        sidechain INTEGER NOT NULL, session_ref INTEGER NOT NULL,
        units INTEGER NOT NULL, input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
        cache_write_1h INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL,
        cost_nano INTEGER NOT NULL, unpriced INTEGER NOT NULL, first_at REAL NOT NULL, last_at REAL NOT NULL,
        PRIMARY KEY (provider, minute, model, source_ref, sidechain, session_ref)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS minutes_minute ON minutes(minute);
    CREATE TABLE IF NOT EXISTS compacted (file_ref INTEGER PRIMARY KEY, through REAL NOT NULL);
    """

    private func createSchema() throws {
        try exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        try exec("CREATE TABLE IF NOT EXISTS strings (id INTEGER PRIMARY KEY, value TEXT NOT NULL UNIQUE);")
        let version = meta("schemaVersion")
        var migrationStart: Date?
        var sizeBefore: Int64 = 0
        if version == "1" {
            migrationStart = Date()
            sizeBefore = storageBytes()
            try migrateV1ToV2()
        }
        try exec(Self.eventsDDL)
        try exec("""
        CREATE TABLE IF NOT EXISTS markers (
            marker_id TEXT PRIMARY KEY, provider TEXT NOT NULL, kind TEXT NOT NULL, at REAL NOT NULL,
            session TEXT NOT NULL, detail TEXT
        );
        CREATE INDEX IF NOT EXISTS markers_provider_at ON markers(provider, at);
        CREATE TABLE IF NOT EXISTS cursors (
            file_id TEXT PRIMARY KEY, path TEXT NOT NULL, inode INTEGER NOT NULL, size INTEGER NOT NULL,
            mtime REAL NOT NULL, offset INTEGER NOT NULL, state BLOB
        );
        CREATE TABLE IF NOT EXISTS ownership (
            seq INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, provider TEXT NOT NULL,
            profile_id TEXT, previous_profile_id TEXT, account_stamp TEXT, name TEXT,
            basis TEXT NOT NULL, cause TEXT
        );
        CREATE INDEX IF NOT EXISTS ownership_provider_at ON ownership(provider, at);
        CREATE TABLE IF NOT EXISTS health (
            provider TEXT PRIMARY KEY, scanned_at REAL, data_through REAL, files_seen INTEGER NOT NULL,
            files_unreadable INTEGER NOT NULL, lines_malformed INTEGER NOT NULL, unknown_shapes INTEGER NOT NULL,
            backlog_files INTEGER NOT NULL, backlog_bytes INTEGER NOT NULL
        );
        """)
        try exec(Self.minutesDDL)
        if version != String(Self.schemaVersion) {
            // v2 → v3 is additive (the two tables above); nothing to move.
            try setMeta("schemaVersion", String(Self.schemaVersion))
        }
        if let migrationStart {
            // Outside the migration transaction: hand the freed pages back, then
            // fold the VACUUM's WAL pages into the main file.
            try? exec("VACUUM")
            checkpoint()
            let elapsed = Date().timeIntervalSince(migrationStart)
            telemetryLog.info("ledger schema v1→v2 migrated in \(String(format: "%.1f", elapsed), privacy: .public) s, size \(sizeBefore) → \(self.storageBytes()) B")
        }
    }

    /// v1 stored file id, session and source as text on every row. Rebuild the
    /// table with interned refs in one transaction; cursors, ownership, health
    /// and markers are untouched, so no re-index follows.
    private func migrateV1ToV2() throws {
        try transaction {
            try exec("""
            INSERT OR IGNORE INTO strings (value)
                SELECT file_id FROM events UNION SELECT session FROM events
                UNION SELECT source FROM events WHERE source IS NOT NULL;
            ALTER TABLE events RENAME TO events_v1;
            DROP INDEX IF EXISTS events_provider_at;
            DROP INDEX IF EXISTS events_at;
            DROP INDEX IF EXISTS events_file;
            """)
            try exec(Self.eventsDDL)
            try exec("""
            INSERT INTO events (unit_id, provider, at, model, input, cache_read, cache_write, cache_write_1h, output, reasoning,
                cost_nano, session_ref, sidechain, source_ref, file_ref, source_offset, parser_version, in_flight)
            SELECT e.unit_id, e.provider, e.at, e.model, e.input, e.cache_read, e.cache_write, e.cache_write_1h, e.output, e.reasoning,
                e.cost_nano, (SELECT id FROM strings WHERE value = e.session), e.sidechain,
                (SELECT id FROM strings WHERE value = e.source), (SELECT id FROM strings WHERE value = e.file_id),
                e.source_offset, e.parser_version, e.in_flight
            FROM events_v1 e;
            DROP TABLE events_v1;
            """)
            // Inside the same transaction: a crash anywhere before COMMIT rolls
            // the whole rebuild back and the next open migrates again; a crash
            // after it finds version 2 and never re-runs.
            try setMeta("schemaVersion", String(Self.schemaVersion))
        }
    }

    // MARK: - Transactions

    /// `BEGIN IMMEDIATE … COMMIT`, rolled back if `body` throws. Nested calls
    /// join the outer transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try exec("BEGIN IMMEDIATE")
        transactionDepth = 1
        defer { transactionDepth = 0 }
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Truncates the WAL back into the main file; called after a catch-up run.
    func checkpoint() {
        try? exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: - Interning

    private func intern(_ value: String) throws -> Int64 {
        if let cached = internCache[value] { return cached }
        let insert = try prepare("INSERT OR IGNORE INTO strings (value) VALUES (?1)")
        insert.bind(1, value)
        _ = try insert.step()
        let select = try prepare("SELECT id FROM strings WHERE value = ?1")
        select.bind(1, value)
        guard try select.step() else { throw LedgerError(code: SQLITE_INTERNAL, message: "intern failed") }
        let id = select.int64(0)
        if internCache.count > 200_000 { internCache.removeAll(keepingCapacity: true) }
        internCache[value] = id
        return id
    }

    private func internedId(_ value: String) throws -> Int64? {
        if let cached = internCache[value] { return cached }
        let select = try prepare("SELECT id FROM strings WHERE value = ?1")
        select.bind(1, value)
        return try select.step() ? select.int64(0) : nil
    }

    // MARK: - Events

    /// Inserts or, for a `unitId` already present, replaces the row — but only
    /// with a snapshot whose output is at least as large, so a replay of early
    /// partial blocks can never regress a finished message.
    func upsert(_ events: [TelemetryEvent]) throws {
        guard !events.isEmpty else { return }
        let sql = """
        INSERT INTO events (unit_id, provider, at, model, input, cache_read, cache_write, cache_write_1h, output,
            reasoning, cost_nano, session_ref, sidechain, source_ref, file_ref, source_offset, parser_version, in_flight)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
        ON CONFLICT(unit_id) DO UPDATE SET
            at = excluded.at, model = excluded.model, input = excluded.input, cache_read = excluded.cache_read,
            cache_write = excluded.cache_write, cache_write_1h = excluded.cache_write_1h, output = excluded.output,
            reasoning = excluded.reasoning, cost_nano = excluded.cost_nano, session_ref = excluded.session_ref,
            sidechain = excluded.sidechain, source_ref = excluded.source_ref, file_ref = excluded.file_ref,
            source_offset = excluded.source_offset, parser_version = excluded.parser_version,
            in_flight = excluded.in_flight
        WHERE excluded.output >= events.output
        """
        let statement = try prepare(sql)
        try transaction {
            for event in events {
                let fileRef = try intern(event.fileId)
                // Already folded into `minutes` for this file: a replay, not news.
                if let through = compactedThrough[fileRef], event.at.timeIntervalSince1970 <= through { continue }
                let sessionRef = try intern(event.session)
                let sourceRef = try event.source.map { try intern($0) }
                statement.bind(1, event.unitId); statement.bind(2, event.provider.rawValue)
                statement.bind(3, event.at.timeIntervalSince1970); statement.bind(4, event.model)
                statement.bind(5, event.input); statement.bind(6, event.cacheRead)
                statement.bind(7, event.cacheWrite); statement.bind(8, event.cacheWrite1h)
                statement.bind(9, event.output); statement.bind(10, event.reasoning)
                statement.bind(11, event.reportedCostNanoUSD); statement.bind(12, sessionRef)
                statement.bind(13, event.sidechain ? 1 : 0); statement.bind(14, sourceRef)
                statement.bind(15, fileRef); statement.bind(16, event.sourceOffset)
                statement.bind(17, event.parserVersion); statement.bind(18, event.inFlight ? 1 : 0)
                _ = try statement.step()
                statement.reset()
            }
        }
    }

    func insert(_ markers: [TelemetryMarker]) throws {
        guard !markers.isEmpty else { return }
        let statement = try prepare("""
        INSERT OR IGNORE INTO markers (marker_id, provider, kind, at, session, detail) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """)
        try transaction {
            for marker in markers {
                statement.bind(1, marker.markerId); statement.bind(2, marker.provider.rawValue)
                statement.bind(3, marker.kind.rawValue); statement.bind(4, marker.at.timeIntervalSince1970)
                statement.bind(5, marker.session); statement.bind(6, marker.detail)
                _ = try statement.step()
                statement.reset()
            }
        }
    }

    private static let eventSelect = """
    SELECT e.unit_id, e.provider, e.at, e.model, e.input, e.cache_read, e.cache_write, e.cache_write_1h, e.output, e.reasoning,
        e.cost_nano, s.value, e.sidechain, src.value, f.value, e.source_offset, e.parser_version, e.in_flight
    FROM events e
    JOIN strings s ON s.id = e.session_ref
    LEFT JOIN strings src ON src.id = e.source_ref
    JOIN strings f ON f.id = e.file_ref
    """

    /// Events with `from <= at < to`, oldest first.
    func events(provider: TelemetryProvider? = nil, from: Date, to: Date) throws -> [TelemetryEvent] {
        var sql = Self.eventSelect + " WHERE e.at >= ?1 AND e.at < ?2"
        if provider != nil { sql += " AND e.provider = ?3" }
        sql += " ORDER BY e.at"
        let statement = try prepare(sql)
        statement.bind(1, from.timeIntervalSince1970); statement.bind(2, to.timeIntervalSince1970)
        if let provider { statement.bind(3, provider.rawValue) }
        var result: [TelemetryEvent] = []
        while try statement.step() {
            guard let providerName = statement.string(1), let provider = TelemetryProvider(rawValue: providerName) else { continue }
            result.append(TelemetryEvent(
                unitId: statement.string(0) ?? "", provider: provider,
                at: Date(timeIntervalSince1970: statement.double(2)), model: statement.string(3) ?? "unknown",
                input: statement.int(4), cacheRead: statement.int(5), cacheWrite: statement.int(6),
                cacheWrite1h: statement.int(7), output: statement.int(8), reasoning: statement.int(9),
                reportedCostNanoUSD: statement.isNull(10) ? nil : statement.int(10),
                session: statement.string(11) ?? "", sidechain: statement.int(12) != 0,
                source: statement.string(13), fileId: statement.string(14) ?? "",
                sourceOffset: statement.int(15), parserVersion: statement.int(16), inFlight: statement.int(17) != 0))
        }
        return result
    }

    func markers(provider: TelemetryProvider? = nil, from: Date, to: Date) throws -> [TelemetryMarker] {
        var sql = "SELECT marker_id, provider, kind, at, session, detail FROM markers WHERE at >= ?1 AND at < ?2"
        if provider != nil { sql += " AND provider = ?3" }
        sql += " ORDER BY at"
        let statement = try prepare(sql)
        statement.bind(1, from.timeIntervalSince1970); statement.bind(2, to.timeIntervalSince1970)
        if let provider { statement.bind(3, provider.rawValue) }
        var result: [TelemetryMarker] = []
        while try statement.step() {
            guard let providerName = statement.string(1), let provider = TelemetryProvider(rawValue: providerName),
                  let kind = statement.string(2).flatMap(TelemetryMarker.Kind.init(rawValue:)) else { continue }
            result.append(TelemetryMarker(markerId: statement.string(0) ?? "", provider: provider, kind: kind,
                                          at: Date(timeIntervalSince1970: statement.double(3)),
                                          session: statement.string(4) ?? "", detail: statement.string(5)))
        }
        return result
    }

    /// Codex rollouts can log token snapshots before their first `turn_context`;
    /// once the model is known, the file's earlier "unknown" units take it
    /// (a rollout rarely changes model — 3 of 1,209 on disk).
    /// Raw rows only: a compacted minute keeps the model it was folded with
    /// (the pre-first-turn_context units of a rollout that is still being
    /// written are never older than the compaction age).
    func reassignUnknownModel(fileId: String, to model: String) throws {
        guard let fileRef = try internedId(fileId) else { return }
        let statement = try prepare("UPDATE events SET model = ?1 WHERE file_ref = ?2 AND model = 'unknown'")
        statement.bind(1, model); statement.bind(2, fileRef)
        _ = try statement.step()
    }

    // MARK: - Compaction (stage 4c)

    struct CompactionReport: Sendable, Equatable {
        var eventsRemoved = 0
        var daysProcessed = 0
        /// The budget ran out before the cutoff was reached; call again.
        var remaining = false
    }

    /// Folds raw events older than `cutoff` — in-flight rows excepted — into
    /// `minutes`, one UTC day per transaction, until the cutoff is reached or
    /// `maxSeconds` is spent. Lossless for the report: the minute aggregation,
    /// the distinct-session count and the time span read the union of both
    /// tables. Freed pages are reused by new events; the file is never
    /// vacuumed here (a VACUUM of a 288 MB ledger doubles it on disk for
    /// seconds and is the migration path's business).
    @discardableResult
    func compact(before cutoff: Date, maxSeconds: TimeInterval = 2) throws -> CompactionReport {
        var report = CompactionReport()
        let started = Date()
        let cutoffSeconds = cutoff.timeIntervalSince1970
        let fold = try prepare("""
        INSERT INTO minutes (provider, minute, model, source_ref, sidechain, session_ref, units, input, cache_read, cache_write,
            cache_write_1h, output, reasoning, cost_nano, unpriced, first_at, last_at)
        SELECT provider, CAST(at / 60 AS INTEGER), model, COALESCE(source_ref, 0), sidechain, session_ref, COUNT(*), SUM(input),
            SUM(cache_read), SUM(cache_write), SUM(cache_write_1h), SUM(output), SUM(reasoning), COALESCE(SUM(cost_nano), 0),
            SUM(CASE WHEN cost_nano IS NULL THEN 1 ELSE 0 END), MIN(at), MAX(at)
        FROM events WHERE at >= ?1 AND at < ?2 AND in_flight = 0
        GROUP BY provider, CAST(at / 60 AS INTEGER), model, COALESCE(source_ref, 0), sidechain, session_ref
        ON CONFLICT(provider, minute, model, source_ref, sidechain, session_ref) DO UPDATE SET
            units = units + excluded.units, input = input + excluded.input, cache_read = cache_read + excluded.cache_read,
            cache_write = cache_write + excluded.cache_write, cache_write_1h = cache_write_1h + excluded.cache_write_1h,
            output = output + excluded.output, reasoning = reasoning + excluded.reasoning,
            cost_nano = cost_nano + excluded.cost_nano, unpriced = unpriced + excluded.unpriced,
            first_at = MIN(first_at, excluded.first_at), last_at = MAX(last_at, excluded.last_at)
        """)
        let watermark = try prepare("""
        INSERT INTO compacted (file_ref, through)
        SELECT file_ref, MAX(at) FROM events WHERE at >= ?1 AND at < ?2 AND in_flight = 0 GROUP BY file_ref
        ON CONFLICT(file_ref) DO UPDATE SET through = MAX(through, excluded.through)
        """)
        let remove = try prepare("DELETE FROM events WHERE at >= ?1 AND at < ?2 AND in_flight = 0")
        let oldest = try prepare("SELECT MIN(at) FROM events WHERE at < ?1 AND in_flight = 0")
        func oldestRaw() throws -> Double? {
            oldest.reset(); oldest.bind(1, cutoffSeconds)
            guard try oldest.step(), !oldest.isNull(0) else { return nil }
            return oldest.double(0)
        }
        while let first = try oldestRaw() {
            let dayStart = (first / 86_400).rounded(.down) * 86_400
            let dayEnd = min(dayStart + 86_400, cutoffSeconds)
            try transaction {
                for statement in [fold, watermark, remove] {
                    statement.reset(); statement.bind(1, dayStart); statement.bind(2, dayEnd)
                    _ = try statement.step()
                }
                report.eventsRemoved += changes
            }
            report.daysProcessed += 1
            if Date().timeIntervalSince(started) > maxSeconds {
                report.remaining = try oldestRaw() != nil
                break
            }
        }
        if report.daysProcessed > 0 { try reloadCompactionWatermarks() }
        return report
    }

    private func reloadCompactionWatermarks() throws {
        let statement = try prepare("SELECT file_ref, through FROM compacted")
        var loaded: [Int64: Double] = [:]
        while try statement.step() { loaded[statement.int64(0)] = statement.double(1) }
        compactedThrough = loaded
    }

    /// Rows changed by the last statement.
    private var changes: Int { db.map { Int(sqlite3_changes($0)) } ?? 0 }

    /// Rows in the `minutes` table — a test seam and a log figure.
    func compactedMinuteRows() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM minutes")
        return try statement.step() ? statement.int(0) : 0
    }

    /// Every raw row of one file — the first half of a replace-in-place
    /// re-index (stage 4d); the second half is the upsert in the same
    /// transaction. Compacted minutes are untouched.
    func deleteEvents(fileId: String) throws {
        guard let fileRef = try internedId(fileId) else { return }
        let statement = try prepare("DELETE FROM events WHERE file_ref = ?1")
        statement.bind(1, fileRef)
        _ = try statement.step()
    }

    /// Raw rows still in `events` — a test seam.
    func rawEventCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM events")
        return try statement.step() ? statement.int(0) : 0
    }

    /// Minute-level sums for the report builder: one row per (provider, model,
    /// source, sidechain, UTC minute). Attribution happens at the minute, which
    /// is finer than any switch the fleet makes. `cost_nano` sums only what the
    /// source reported (Grok); the null count becomes `unpricedUnits`.
    func aggregateMinutes(provider: TelemetryProvider? = nil, from: Date, to: Date) throws -> [MinuteAggregate] {
        var sql = """
        SELECT e.provider, e.model, src.value, e.sidechain, CAST(e.at / 60 AS INTEGER) AS minute, COUNT(*), SUM(e.input),
            SUM(e.cache_read), SUM(e.cache_write), SUM(e.cache_write_1h), SUM(e.output), SUM(e.reasoning),
            COALESCE(SUM(e.cost_nano), 0), SUM(CASE WHEN e.cost_nano IS NULL THEN 1 ELSE 0 END)
        FROM events e LEFT JOIN strings src ON src.id = e.source_ref
        WHERE e.at >= ?1 AND e.at < ?2
        """
        if provider != nil { sql += " AND e.provider = ?3" }
        sql += " GROUP BY e.provider, e.model, e.source_ref, e.sidechain, minute"
        // Compacted minutes (stage 4c) carry one row per session; the same
        // columns in the same order, summed into the raw rows below.
        var compactedSQL = """
        SELECT m.provider, m.model, src.value, m.sidechain, m.minute, m.units, m.input, m.cache_read, m.cache_write,
            m.cache_write_1h, m.output, m.reasoning, m.cost_nano, m.unpriced
        FROM minutes m LEFT JOIN strings src ON src.id = m.source_ref
        WHERE m.minute * 60 >= ?1 AND m.minute * 60 < ?2
        """
        if provider != nil { compactedSQL += " AND m.provider = ?3" }
        struct Key: Hashable { var provider: TelemetryProvider; var model: String; var source: String?; var sidechain: Bool; var minute: Double }
        var merged: [Key: TokenTotals] = [:]
        for text in [sql, compactedSQL] {
            let statement = try prepare(text)
            statement.bind(1, from.timeIntervalSince1970); statement.bind(2, to.timeIntervalSince1970)
            if let provider { statement.bind(3, provider.rawValue) }
            while try statement.step() {
                guard let providerName = statement.string(0), let provider = TelemetryProvider(rawValue: providerName) else { continue }
                let sidechain = statement.int(3) != 0
                var totals = TokenTotals()
                totals.units = statement.int(5); totals.input = statement.int(6); totals.cacheRead = statement.int(7)
                totals.cacheWrite = statement.int(8); totals.cacheWrite1h = statement.int(9); totals.output = statement.int(10)
                totals.reasoning = statement.int(11); totals.costNanoUSD = statement.int(12); totals.unpricedUnits = statement.int(13)
                totals.sidechainUnits = sidechain ? totals.units : 0
                let key = Key(provider: provider, model: statement.string(1) ?? "unknown", source: statement.string(2),
                              sidechain: sidechain, minute: statement.double(4))
                merged[key, default: TokenTotals()].add(totals)
            }
        }
        return merged.map { key, totals in
            MinuteAggregate(provider: key.provider, model: key.model, source: key.source, sidechain: key.sidechain,
                            minute: Date(timeIntervalSince1970: key.minute * 60), totals: totals)
        }.sorted { ($0.minute, $0.provider.rawValue, $0.model, $0.source ?? "", $0.sidechain ? 1 : 0)
                 < ($1.minute, $1.provider.rawValue, $1.model, $1.source ?? "", $1.sidechain ? 1 : 0) }
    }

    /// Raw and compacted rows alike — a compacted minute keeps its session.
    func distinctSessions(provider: TelemetryProvider, from: Date, to: Date) throws -> Int {
        let statement = try prepare("""
        SELECT COUNT(*) FROM (
            SELECT session_ref FROM events WHERE provider = ?1 AND at >= ?2 AND at < ?3
            UNION SELECT session_ref FROM minutes WHERE provider = ?1 AND minute * 60 >= ?2 AND minute * 60 < ?3)
        """)
        statement.bind(1, provider.rawValue); statement.bind(2, from.timeIntervalSince1970); statement.bind(3, to.timeIntervalSince1970)
        return try statement.step() ? statement.int(0) : 0
    }

    /// Units ever indexed: raw rows plus the units folded into `minutes`.
    func eventCount() throws -> Int {
        let statement = try prepare("SELECT (SELECT COUNT(*) FROM events) + (SELECT COALESCE(SUM(units), 0) FROM minutes)")
        return try statement.step() ? statement.int(0) : 0
    }

    /// The oldest and newest event times, or nil when the ledger is empty. A
    /// compacted minute remembers its exact first and last event time.
    func eventTimeSpan(provider: TelemetryProvider? = nil) throws -> (from: Date, to: Date)? {
        let filter = provider == nil ? "" : " WHERE provider = ?1"
        let statement = try prepare("""
        SELECT MIN(lo), MAX(hi) FROM (SELECT at AS lo, at AS hi FROM events\(filter)
            UNION ALL SELECT first_at AS lo, last_at AS hi FROM minutes\(filter))
        """)
        if let provider { statement.bind(1, provider.rawValue) }
        guard try statement.step(), !statement.isNull(0) else { return nil }
        return (Date(timeIntervalSince1970: statement.double(0)), Date(timeIntervalSince1970: statement.double(1)))
    }

    // MARK: - Cursors

    func cursor(for fileId: String) throws -> TelemetryCursor? {
        let statement = try prepare("SELECT file_id, path, inode, size, mtime, offset, state FROM cursors WHERE file_id = ?1")
        statement.bind(1, fileId)
        guard try statement.step() else { return nil }
        return Self.cursor(from: statement)
    }

    func allCursors() throws -> [TelemetryCursor] {
        let statement = try prepare("SELECT file_id, path, inode, size, mtime, offset, state FROM cursors")
        var result: [TelemetryCursor] = []
        while try statement.step() { result.append(Self.cursor(from: statement)) }
        return result
    }

    private static func cursor(from statement: Statement) -> TelemetryCursor {
        TelemetryCursor(fileId: statement.string(0) ?? "", path: statement.string(1) ?? "",
                        inode: UInt64(bitPattern: statement.int64(2)), size: statement.int64(3),
                        mtime: Date(timeIntervalSince1970: statement.double(4)), offset: statement.int64(5),
                        state: statement.blob(6))
    }

    func save(_ cursor: TelemetryCursor) throws {
        let statement = try prepare("""
        INSERT INTO cursors (file_id, path, inode, size, mtime, offset, state) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(file_id) DO UPDATE SET path = excluded.path, inode = excluded.inode, size = excluded.size,
            mtime = excluded.mtime, offset = excluded.offset, state = excluded.state
        """)
        statement.bind(1, cursor.fileId); statement.bind(2, cursor.path)
        statement.bind(3, Int64(bitPattern: cursor.inode)); statement.bind(4, cursor.size)
        statement.bind(5, cursor.mtime.timeIntervalSince1970); statement.bind(6, cursor.offset)
        statement.bind(7, cursor.state)
        _ = try statement.step()
    }

    /// A vanished source file loses only its cursor — never its events.
    func deleteCursor(fileId: String) throws {
        let statement = try prepare("DELETE FROM cursors WHERE file_id = ?1")
        statement.bind(1, fileId)
        _ = try statement.step()
    }

    // MARK: - Ownership

    @discardableResult
    func append(_ record: OwnershipRecord) throws -> Int64 {
        let statement = try prepare("""
        INSERT INTO ownership (at, provider, profile_id, previous_profile_id, account_stamp, name, basis, cause)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """)
        statement.bind(1, record.at.timeIntervalSince1970); statement.bind(2, record.provider.rawValue)
        statement.bind(3, record.profileId?.uuidString); statement.bind(4, record.previousProfileId?.uuidString)
        statement.bind(5, record.accountStamp); statement.bind(6, record.name)
        statement.bind(7, record.basis.rawValue); statement.bind(8, record.cause)
        _ = try statement.step()
        return sqlite3_last_insert_rowid(db)
    }

    /// Oldest first.
    func ownership(provider: TelemetryProvider? = nil) throws -> [OwnershipRecord] {
        var sql = "SELECT seq, at, provider, profile_id, previous_profile_id, account_stamp, name, basis, cause FROM ownership"
        if provider != nil { sql += " WHERE provider = ?1" }
        sql += " ORDER BY at, seq"
        let statement = try prepare(sql)
        if let provider { statement.bind(1, provider.rawValue) }
        var result: [OwnershipRecord] = []
        while try statement.step() {
            guard let providerName = statement.string(2), let provider = TelemetryProvider(rawValue: providerName),
                  let basis = statement.string(7).flatMap(OwnershipRecord.Basis.init(rawValue:)) else { continue }
            result.append(OwnershipRecord(
                seq: statement.int64(0), at: Date(timeIntervalSince1970: statement.double(1)), provider: provider,
                profileId: statement.string(3).flatMap(UUID.init(uuidString:)),
                previousProfileId: statement.string(4).flatMap(UUID.init(uuidString:)),
                accountStamp: statement.string(5), name: statement.string(6), basis: basis, cause: statement.string(8)))
        }
        return result
    }

    func lastOwnership(provider: TelemetryProvider) throws -> OwnershipRecord? {
        try ownership(provider: provider).last
    }

    // MARK: - Health and meta

    func health(provider: TelemetryProvider) throws -> ProviderHealth {
        let statement = try prepare("""
        SELECT scanned_at, data_through, files_seen, files_unreadable, lines_malformed, unknown_shapes, backlog_files,
            backlog_bytes FROM health WHERE provider = ?1
        """)
        statement.bind(1, provider.rawValue)
        guard try statement.step() else { return ProviderHealth(provider: provider) }
        return ProviderHealth(
            provider: provider,
            scannedAt: statement.isNull(0) ? nil : Date(timeIntervalSince1970: statement.double(0)),
            dataThrough: statement.isNull(1) ? nil : Date(timeIntervalSince1970: statement.double(1)),
            filesSeen: statement.int(2), filesUnreadable: statement.int(3), linesMalformed: statement.int(4),
            unknownShapes: statement.int(5), backlogFiles: statement.int(6), backlogBytes: statement.int64(7))
    }

    func save(_ health: ProviderHealth) throws {
        let statement = try prepare("""
        INSERT INTO health (provider, scanned_at, data_through, files_seen, files_unreadable, lines_malformed,
            unknown_shapes, backlog_files, backlog_bytes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        ON CONFLICT(provider) DO UPDATE SET scanned_at = excluded.scanned_at, data_through = excluded.data_through,
            files_seen = excluded.files_seen, files_unreadable = excluded.files_unreadable,
            lines_malformed = excluded.lines_malformed, unknown_shapes = excluded.unknown_shapes,
            backlog_files = excluded.backlog_files, backlog_bytes = excluded.backlog_bytes
        """)
        statement.bind(1, health.provider.rawValue)
        statement.bind(2, health.scannedAt?.timeIntervalSince1970); statement.bind(3, health.dataThrough?.timeIntervalSince1970)
        statement.bind(4, health.filesSeen); statement.bind(5, health.filesUnreadable); statement.bind(6, health.linesMalformed)
        statement.bind(7, health.unknownShapes); statement.bind(8, health.backlogFiles); statement.bind(9, health.backlogBytes)
        _ = try statement.step()
    }

    func meta(_ key: String) -> String? {
        guard let statement = try? prepare("SELECT value FROM meta WHERE key = ?1") else { return nil }
        statement.bind(1, key)
        guard (try? statement.step()) == true else { return nil }
        return statement.string(0)
    }

    func setMeta(_ key: String, _ value: String) throws {
        let statement = try prepare("INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        statement.bind(1, key); statement.bind(2, value)
        _ = try statement.step()
    }

    /// Bytes on disk for the database and its WAL.
    func storageBytes() -> Int64 {
        ["", "-wal"].reduce(0) { total, suffix in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
            return total + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: - SQLite plumbing

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw LedgerError(code: rc, message: message)
        }
    }

    private func prepare(_ sql: String) throws -> Statement {
        guard let db else { throw LedgerError(code: SQLITE_MISUSE, message: "closed") }
        return try Statement(db: db, sql: sql)
    }

    /// A prepared statement finalized on deinit. Bind indices are 1-based,
    /// column indices 0-based, as in the C API.
    private final class Statement {
        let handle: OpaquePointer
        private let db: OpaquePointer

        init(db: OpaquePointer, sql: String) throws {
            var statement: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            guard rc == SQLITE_OK, let statement else {
                throw LedgerError(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
            self.handle = statement
            self.db = db
        }

        deinit { sqlite3_finalize(handle) }

        func bind(_ index: Int32, _ value: String?) {
            if let value { sqlite3_bind_text(handle, index, value, -1, sqliteTransient) } else { sqlite3_bind_null(handle, index) }
        }
        func bind(_ index: Int32, _ value: Int) { sqlite3_bind_int64(handle, index, Int64(value)) }
        func bind(_ index: Int32, _ value: Int?) {
            if let value { sqlite3_bind_int64(handle, index, Int64(value)) } else { sqlite3_bind_null(handle, index) }
        }
        func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(handle, index, value) }
        func bind(_ index: Int32, _ value: Int64?) {
            if let value { sqlite3_bind_int64(handle, index, value) } else { sqlite3_bind_null(handle, index) }
        }
        func bind(_ index: Int32, _ value: Double) { sqlite3_bind_double(handle, index, value) }
        func bind(_ index: Int32, _ value: Double?) {
            if let value { sqlite3_bind_double(handle, index, value) } else { sqlite3_bind_null(handle, index) }
        }
        func bind(_ index: Int32, _ value: Data?) {
            guard let value else { sqlite3_bind_null(handle, index); return }
            value.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(handle, index, raw.baseAddress, Int32(raw.count), sqliteTransient)
            }
        }

        /// Steps once; true when a row is available, false when done.
        func step() throws -> Bool {
            let rc = sqlite3_step(handle)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw LedgerError(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
        }

        func reset() {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }

        func string(_ column: Int32) -> String? {
            guard let text = sqlite3_column_text(handle, column) else { return nil }
            return String(cString: text)
        }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
        func blob(_ column: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(handle, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
        }
    }
}
