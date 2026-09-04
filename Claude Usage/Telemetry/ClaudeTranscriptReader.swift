//
//  ClaudeTranscriptReader.swift
//  Claude Usage
//
//  Turns Claude Code transcript lines into consumption events (spec §2.1).
//  The CLI writes ONE `assistant` record per content block of the same API
//  response, all with the same `message.id`; early blocks carry a partial
//  `output_tokens` (measured: 1 → 1 → 390 on one message). Records of one
//  message are contiguous in a file, so a message is finished when a record
//  of a DIFFERENT id follows it; the last message of a file stays "in flight"
//  and is upserted again — never duplicated — when the file grows.
//
//  Skipped: `<synthetic>` records and any record whose usage is all zeros
//  (errors), which become markers instead; `iterations[]` is never summed —
//  it mirrors the top-level usage.
//

import Foundation

nonisolated enum ClaudeTranscriptReader {

    static let parserVersion = 1
    static let needles = JSONLFraming.needles(["\"type\":\"assistant\"", "\"type\": \"assistant\""])

    /// The best snapshot of the message currently being written.
    struct Pending: Codable, Sendable, Equatable {
        var event: TelemetryEvent
    }

    /// Per-file resume state persisted in the cursor.
    struct State: Codable, Sendable, Equatable {
        var pending: Pending?
    }

    struct Output: Sendable {
        var events: [TelemetryEvent] = []
        var markers: [TelemetryMarker] = []
        var state: State
        var malformed = 0
        var unknownShapes = 0
        var dataThrough: Date?
    }

    static func parse(lines: [JSONLFraming.Line], fileId: String, state: State) -> Output {
        var output = Output(state: state)
        // One pool per line: a million parsed dictionaries otherwise live until
        // the enclosing pool drains (the corpus run was killed at ~4 minutes).
        for line in lines { autoreleasepool { parseLine(line, fileId: fileId, into: &output) } }
        // The message still being written is upserted as in flight; the next
        // pass replaces it with the fuller snapshot under the same unit id.
        if let pending = output.state.pending {
            output.events.append(pending.event)
        }
        return output
    }

    private static func parseLine(_ line: JSONLFraming.Line, fileId: String, into output: inout Output) {
        do {
            guard let object = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else {
                output.malformed += 1
                return
            }
            guard object["type"] as? String == "assistant" else { return }
            guard let message = object["message"] as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let at = JSONLFraming.parseISODate(timestamp) else {
                output.unknownShapes += 1
                return
            }
            if output.dataThrough.map({ at > $0 }) ?? true { output.dataThrough = at }
            let session = (object["sessionId"] as? String) ?? (object["session_id"] as? String) ?? ""
            let usage = message["usage"] as? [String: Any] ?? [:]
            let model = message["model"] as? String ?? "unknown"
            let outputTokens = int(usage["output_tokens"])
            let inputTokens = int(usage["input_tokens"])
            let cacheRead = int(usage["cache_read_input_tokens"])
            let cacheWrite = int(usage["cache_creation_input_tokens"])
            let allZero = outputTokens == 0 && inputTokens == 0 && cacheRead == 0 && cacheWrite == 0

            if model == "<synthetic>" || allZero {
                if let marker = marker(object: object, message: message, at: at, session: session, fileId: fileId, offset: line.offset) {
                    output.markers.append(marker)
                }
                return
            }

            guard let id = (message["id"] as? String) ?? (object["requestId"] as? String) ?? (object["uuid"] as? String) else {
                output.unknownShapes += 1
                return
            }
            let cacheWrite1h = int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
            let thinking = int((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
            let cwd = object["cwd"] as? String
            let event = TelemetryEvent(
                unitId: id, provider: .claude, at: at, model: model,
                input: inputTokens, cacheRead: cacheRead, cacheWrite: cacheWrite, cacheWrite1h: min(cacheWrite1h, cacheWrite),
                output: outputTokens, reasoning: min(thinking, outputTokens), reportedCostNanoUSD: nil,
                session: session, sidechain: object["isSidechain"] as? Bool ?? false,
                source: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                fileId: fileId, sourceOffset: Int(line.offset), parserVersion: parserVersion, inFlight: true)

            if var pending = output.state.pending {
                if pending.event.unitId == id {
                    // Another block of the same message: keep the fuller snapshot whole.
                    if event.output >= pending.event.output { pending.event = event }
                    output.state.pending = pending
                } else {
                    // A new message began — the previous one is finished.
                    pending.event.inFlight = false
                    output.events.append(pending.event)
                    output.state.pending = Pending(event: event)
                }
            } else {
                output.state.pending = Pending(event: event)
            }
        }
    }

    private static func marker(object: [String: Any], message: [String: Any], at: Date, session: String,
                               fileId: String, offset: Int64) -> TelemetryMarker? {
        let kind: TelemetryMarker.Kind
        var detail: String?
        if object["error"] as? String == "rate_limit" {
            kind = .rateLimit
            detail = text(of: message)
        } else if let quota = object["quotaLimits"] as? [String: Any], quota["status"] as? String == "rejected" {
            kind = .quotaRejected
            detail = quota["rateLimitType"] as? String
        } else {
            return nil
        }
        return TelemetryMarker(markerId: "\(fileId)#\(offset)", provider: .claude, kind: kind, at: at,
                               session: session, detail: detail)
    }

    private static func text(of message: [String: Any]) -> String? {
        if let content = message["content"] as? String { return content }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    static func int(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }
}
