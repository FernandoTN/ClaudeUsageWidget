//
//  StopFailureJournal.swift
//  Claude Usage
//
//  The fleet's own report that a login stopped working: one marker per CLI
//  turn that ended on `authentication_failed`. Written by the StopFailure hook
//  (scripts/hooks/cuw-stop-failure.sh) and read here once per sweep.
//

import Foundation

/// One CLI session's report that a turn ended on `authentication_failed`.
/// Detector B (`ObservedDeadLogins.evaluateFleetMarkers`) counts DISTINCT
/// sessions, so the two sources that produce these (this journal and the
/// transcript tripwire) can report the same failure without double-counting.
nonisolated struct FleetAuthFailureMarker: Equatable, Sendable {
    let at: Date
    let sessionId: String
}

/// Reader for the StopFailure hook's journal.
///
/// The file is JSON Lines, one object per failed turn:
/// `{"ts": <epoch seconds>, "session_id": "…", "cwd": "…", "error": "authentication_failed"}`.
/// The hook appends only for `authentication_failed` and truncates the file
/// itself once it passes 64 KiB. This side never writes it. It reads at most
/// the last `maxReadBytes`, skips any line it cannot parse, and returns
/// nothing at all for a missing file. A corrupt journal costs detector B its
/// evidence, never a crash.
///
/// File I/O: call it off the main actor (the sweep reads it inside the
/// transcript tripwire's detached task).
nonisolated enum StopFailureJournal {

    /// The only `error` value that is evidence about a login. The rest of the
    /// hook's closed enum is ignored even if a line carries it: `rate_limit` is
    /// normal operation, `overloaded` is a 529 that needs a retry, and none of
    /// the others say anything about the shared login.
    static let authenticationFailed = "authentication_failed"

    /// `~/Library/Application Support/Claude Usage/stop-failures.jsonl`, next
    /// to the telemetry ledger. The hook script hard-codes the same path
    /// (overridable there with `CUW_STOP_FAILURE_JOURNAL`).
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Claude Usage", isDirectory: true)
            .appendingPathComponent("stop-failures.jsonl")
    }

    /// The hook keeps the file under 64 KiB; this bound holds even if
    /// something else grew it.
    static let maxReadBytes = 65_536
    /// A real line is ~200 bytes. Anything longer is not ours.
    static let maxLineBytes = 4_096

    static func read(at url: URL = defaultURL, maxBytes: Int = maxReadBytes) -> [FleetAuthFailureMarker] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        // A tail read that started mid-file starts mid-line: drop that fragment.
        return parse(data, droppingFirstLine: offset > 0)
    }

    static func parse(_ data: Data, droppingFirstLine: Bool = false) -> [FleetAuthFailureMarker] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if droppingFirstLine, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines.compactMap { marker(fromLine: Data($0)) }
    }

    static func marker(fromLine line: Data) -> FleetAuthFailureMarker? {
        guard line.count <= maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["error"] as? String == authenticationFailed,
              let session = object["session_id"] as? String, !session.isEmpty,
              let ts = (object["ts"] as? NSNumber)?.doubleValue, ts.isFinite, ts > 0 else {
            return nil
        }
        return FleetAuthFailureMarker(at: Date(timeIntervalSince1970: ts), sessionId: session)
    }
}
