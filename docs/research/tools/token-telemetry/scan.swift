import Foundation
// Prototype of the telemetry indexer's hot path: walk, prune, byte-prefilter, parse only matching lines.
// Usage: scan <root> <mode: claude|codex> [sinceHoursAgo]
let args = CommandLine.arguments
let root = args[1]; let mode = args[2]
let since: Date? = args.count > 3 ? Date().addingTimeInterval(-Double(args[3])! * 3600) : nil
let needle: [UInt8] = Array((mode == "claude" ? "\"type\":\"assistant\"" : "\"token_count\"").utf8)
let fm = FileManager.default
let start = Date()
var files = 0, bytes = 0, matched = 0, parsed = 0, skippedByMtime = 0
var msgs = Set<String>(); var inTok = 0, outTok = 0, ccTok = 0, crTok = 0
var lastOut: [String: Int] = [:]
func contains(_ hay: UnsafeRawBufferPointer, _ start: Int, _ end: Int, _ needle: [UInt8]) -> Bool {
    let n = needle.count; if end - start < n { return false }
    var i = start
    let first = needle[0]
    while i <= end - n {
        if hay[i] == first {
            var j = 1
            while j < n && hay[i + j] == needle[j] { j += 1 }
            if j == n { return true }
        }
        i += 1
    }
    return false
}
let enumerator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])!
for case let url as URL in enumerator {
    let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
    if v?.isDirectory == true { if url.lastPathComponent == "tool-results" { enumerator.skipDescendants() }; continue }
    guard url.pathExtension == "jsonl" else { continue }
    if let since, let m = v?.contentModificationDate, m < since { skippedByMtime += 1; continue }
    files += 1
    guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
    defer { try? handle.close() }
    var carry = Data()
    let chunk = 4 << 20
    while true {
        guard let piece = try? handle.read(upToCount: chunk), !piece.isEmpty else { break }
        bytes += piece.count
        var buf = carry; buf.append(piece)
        var lineStart = 0
        buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            let n = raw.count
            while i < n {
                if raw[i] == 0x0A {
                    if contains(raw, lineStart, i, needle) {
                        matched += 1
                        let line = Data(bytes: raw.baseAddress! + lineStart, count: i - lineStart)
                        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                            parsed += 1
                            if mode == "claude", let msg = obj["message"] as? [String: Any], let usage = msg["usage"] as? [String: Any], (msg["model"] as? String) != "<synthetic>" {
                                let id = (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? ""
                                let o = usage["output_tokens"] as? Int ?? 0
                                if let prev = lastOut[id] { if o > prev { outTok += o - prev; lastOut[id] = o } }
                                else { lastOut[id] = o; msgs.insert(id); outTok += o
                                    inTok += usage["input_tokens"] as? Int ?? 0; ccTok += usage["cache_creation_input_tokens"] as? Int ?? 0; crTok += usage["cache_read_input_tokens"] as? Int ?? 0 }
                            }
                        }
                    }
                    lineStart = i + 1
                }
                i += 1
            }
        }
        carry = lineStart < buf.count ? buf.subdata(in: lineStart..<buf.count) : Data()
    }
    lastOut.removeAll(keepingCapacity: true)
}
let el = Date().timeIntervalSince(start)
print(String(format: "mode=%@ files=%d skippedByMtime=%d bytes=%.2fGB matchedLines=%d parsed=%d distinctMsgs=%d in=%d out=%d cc=%d cr=%d elapsed=%.1fs throughput=%.0fMB/s", mode, files, skippedByMtime, Double(bytes)/1e9, matched, parsed, msgs.count, inTok, outTok, ccTok, crTok, el, Double(bytes)/1e6/max(el,0.001)))
