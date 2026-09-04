//
//  JSONLFraming.swift
//  Claude Usage
//
//  Reads a JSONL file from a byte offset in bounded chunks and hands back only
//  the COMPLETE lines that contain one of the caller's byte needles. The files
//  are being appended while we read: a trailing fragment without its newline
//  is normal, not malformed, and is left for the next pass — the returned
//  `nextOffset` never advances past the last complete newline.
//

import Foundation

nonisolated enum JSONLFraming {

    struct Line: Sendable {
        /// Absolute byte offset of the line's first byte in the file.
        let offset: Int64
        let data: Data
    }

    struct Result: Sendable {
        var lines: [Line]
        /// The offset just past the last complete newline read; resume here.
        var nextOffset: Int64
        var bytesRead: Int64
        /// True when `maxBytes` stopped the read before `limit`.
        var hitByteBound: Bool
    }

    /// Reads `[offset, limit)` — `limit` is the file size the caller snapshotted
    /// when it opened the file, so bytes appended mid-read are ignored until the
    /// next pass — returning the matching complete lines.
    static func readLines(url: URL, from offset: Int64, limit: Int64, maxBytes: Int,
                          needles: [[UInt8]]) throws -> Result {
        guard offset < limit, maxBytes > 0 else {
            return Result(lines: [], nextOffset: offset, bytesRead: 0, hitByteBound: false)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let wanted = Int(min(Int64(maxBytes), limit - offset))
        let data = try handle.read(upToCount: wanted) ?? Data()
        let hitBound = Int64(wanted) < limit - offset

        var lines: [Line] = []
        var consumed = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var lineStart = 0
            var i = 0
            let n = raw.count
            while i < n {
                if raw[i] == 0x0A {
                    if lineStart < i, matches(raw, lineStart, i, needles) {
                        lines.append(Line(offset: offset + Int64(lineStart),
                                          data: Data(bytes: raw.baseAddress! + lineStart, count: i - lineStart)))
                    }
                    lineStart = i + 1
                    consumed = lineStart
                }
                i += 1
            }
        }
        return Result(lines: lines, nextOffset: offset + Int64(consumed), bytesRead: Int64(data.count),
                      hitByteBound: hitBound)
    }

    /// Byte-level substring search over `[start, end)`; no allocation, no UTF-8
    /// decoding of the 99 % of lines that are tool results and user turns.
    static func matches(_ hay: UnsafeRawBufferPointer, _ start: Int, _ end: Int, _ needles: [[UInt8]]) -> Bool {
        for needle in needles {
            let n = needle.count
            guard n > 0, end - start >= n else { continue }
            let first = needle[0]
            var i = start
            while i <= end - n {
                if hay[i] == first {
                    var j = 1
                    while j < n && hay[i + j] == needle[j] { j += 1 }
                    if j == n { return true }
                }
                i += 1
            }
        }
        return false
    }

    static func needles(_ strings: [String]) -> [[UInt8]] {
        strings.map { Array($0.utf8) }
    }

    /// ISO-8601 with or without fractional seconds (both occur in the logs).
    static func parseISODate(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    // Configured once, never mutated; documented thread-safe for parsing.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
}
