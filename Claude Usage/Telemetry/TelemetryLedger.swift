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
//  Threading: every call happens on ONE serial utility queue owned by
//  TelemetryService. The class is `nonisolated` (load-bearing under the
//  MainActor default) and `@unchecked Sendable` because that queue is the
//  synchronisation; it is never touched from the main actor.
//

import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated final class TelemetryLedger: @unchecked Sendable {

    struct LedgerError: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    static let schemaVersion = 1

    let url: URL
    private var db: OpaquePointer?
    private var transactionDepth = 0

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
        try createSchema()
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS events (
            unit_id TEXT PRIMARY KEY, provider TEXT NOT NULL, at REAL NOT NULL, model TEXT NOT NULL,
            input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
            cache_write_1h INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL,
            cost_nano INTEGER, session TEXT NOT NULL, sidechain INTEGER NOT NULL, source TEXT,
            file_id TEXT NOT NULL, source_offset INTEGER NOT NULL, parser_version INTEGER NOT NULL,
            in_flight INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS events_provider_at ON events(provider, at);
        CREATE INDEX IF NOT EXISTS events_at ON events(at);
        CREATE INDEX IF NOT EXISTS events_file ON events(file_id);
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
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
        if meta("schemaVersion") == nil {
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

    // MARK: - Events

    /// Inserts or, for a `unitId` already present, replaces the row — but only
    /// with a snapshot whose output is at least as large, so a replay of early
    /// partial blocks can never regress a finished message.
    func upsert(_ events: [TelemetryEvent]) throws {
        guard !events.isEmpty else { return }
        let sql = """
        INSERT INTO events (unit_id, provider, at, model, input, cache_read, cache_write, cache_write_1h, output,
            reasoning, cost_nano, session, sidechain, source, file_id, source_offset, parser_version, in_flight)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
        ON CONFLICT(unit_id) DO UPDATE SET
            at = excluded.at, model = excluded.model, input = excluded.input, cache_read = excluded.cache_read,
            cache_write = excluded.cache_write, cache_write_1h = excluded.cache_write_1h, output = excluded.output,
            reasoning = excluded.reasoning, cost_nano = excluded.cost_nano, session = excluded.session,
            sidechain = excluded.sidechain, source = excluded.source, file_id = excluded.file_id,
            source_offset = excluded.source_offset, parser_version = excluded.parser_version,
            in_flight = excluded.in_flight
        WHERE excluded.output >= events.output
        """
        let statement = try prepare(sql)
        try transaction {
            for event in events {
                statement.bind(1, event.unitId); statement.bind(2, event.provider.rawValue)
                statement.bind(3, event.at.timeIntervalSince1970); statement.bind(4, event.model)
                statement.bind(5, event.input); statement.bind(6, event.cacheRead)
                statement.bind(7, event.cacheWrite); statement.bind(8, event.cacheWrite1h)
                statement.bind(9, event.output); statement.bind(10, event.reasoning)
                statement.bind(11, event.reportedCostNanoUSD); statement.bind(12, event.session)
                statement.bind(13, event.sidechain ? 1 : 0); statement.bind(14, event.source)
                statement.bind(15, event.fileId); statement.bind(16, event.sourceOffset)
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

    /// Events with `from <= at < to`, oldest first.
    func events(provider: TelemetryProvider? = nil, from: Date, to: Date) throws -> [TelemetryEvent] {
        var sql = """
        SELECT unit_id, provider, at, model, input, cache_read, cache_write, cache_write_1h, output, reasoning,
            cost_nano, session, sidechain, source, file_id, source_offset, parser_version, in_flight
        FROM events WHERE at >= ?1 AND at < ?2
        """
        if provider != nil { sql += " AND provider = ?3" }
        sql += " ORDER BY at"
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

    func eventCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM events")
        return try statement.step() ? statement.int(0) : 0
    }

    /// The oldest and newest event times, or nil when the ledger is empty.
    func eventTimeSpan(provider: TelemetryProvider? = nil) throws -> (from: Date, to: Date)? {
        let statement = try prepare(provider == nil ? "SELECT MIN(at), MAX(at) FROM events"
                                                    : "SELECT MIN(at), MAX(at) FROM events WHERE provider = ?1")
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
