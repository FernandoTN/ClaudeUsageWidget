//
//  CodexRolloutReader.swift
//  Claude Usage
//
//  Turns Codex rollout lines into consumption events (spec §2.1). Each
//  `token_count` event carries `total_token_usage`, CUMULATIVE for the
//  rollout and re-emitted unchanged when only the rate limits changed; the
//  unit is the delta of the COMPONENTS between two distinct snapshots. The
//  `total_tokens` field is ignored: an `<EXTERNAL SESSION IMPORTED>` snapshot
//  has every component at 0 and a non-zero total, and output / reasoning step
//  backwards occasionally while the total rises (29 events each on disk).
//  The model is the latest preceding `turn_context`; rollouts are indexed by
//  FILE because subagent threads share the parent's `session_meta.id`.
//

import Foundation

nonisolated enum CodexRolloutReader {

    static let parserVersion = 1
    static let needles = JSONLFraming.needles(["\"token_count\"", "\"session_meta\"", "\"turn_context\""])

    struct Components: Codable, Sendable, Equatable {
        var input = 0, cached = 0, output = 0, reasoning = 0, cacheWrite = 0, total = 0

        init() {}

        init(_ usage: [String: Any]) {
            input = ClaudeTranscriptReader.int(usage["input_tokens"])
            cached = ClaudeTranscriptReader.int(usage["cached_input_tokens"])
            output = ClaudeTranscriptReader.int(usage["output_tokens"])
            reasoning = ClaudeTranscriptReader.int(usage["reasoning_output_tokens"])
            cacheWrite = ClaudeTranscriptReader.int(usage["cache_write_input_tokens"])
            total = ClaudeTranscriptReader.int(usage["total_tokens"])
        }

        var componentsAreZero: Bool { input == 0 && cached == 0 && output == 0 && reasoning == 0 && cacheWrite == 0 }
    }

    /// Per-file resume state persisted in the cursor: the last component
    /// vector, the current model, the rollout's originator and the snapshot
    /// sequence number that keys the unit ids.
    struct State: Codable, Sendable, Equatable {
        var last: Components?
        var model: String?
        var originator: String?
        var seq = 0
    }

    struct Output: Sendable {
        var events: [TelemetryEvent] = []
        var state: State
        var malformed = 0
        var unknownShapes = 0
        var dataThrough: Date?
        /// Set when this parse saw the file's FIRST `turn_context`: units already
        /// stored as "unknown" for this file should take this model.
        var firstModel: String?
    }

    static func parse(lines: [JSONLFraming.Line], fileId: String, state: State) -> Output {
        var output = Output(state: state)
        for line in lines { autoreleasepool { parseLine(line, fileId: fileId, into: &output) } }
        return output
    }

    private static func parseLine(_ line: JSONLFraming.Line, fileId: String, into output: inout Output) {
        do {
            guard let object = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else {
                output.malformed += 1
                return
            }
            let payload = object["payload"] as? [String: Any] ?? [:]
            switch object["type"] as? String {
            case "session_meta":
                output.state.originator = (payload["originator"] as? String) ?? (payload["source"] as? String)
            case "turn_context":
                if let model = payload["model"] as? String {
                    if output.state.model == nil {
                        output.firstModel = model
                        // Units of this parse that preceded the first turn_context.
                        for index in output.events.indices where output.events[index].model == "unknown" {
                            output.events[index].model = model
                        }
                    }
                    output.state.model = model
                }
            case "event_msg" where payload["type"] as? String == "token_count":
                guard let info = payload["info"] as? [String: Any],
                      let usage = info["total_token_usage"] as? [String: Any] else { return }
                guard let timestamp = object["timestamp"] as? String, let at = JSONLFraming.parseISODate(timestamp) else {
                    output.unknownShapes += 1
                    return
                }
                let current = Components(usage)
                if let last = output.state.last, last == current { return }  // rate-limit refresh only
                if output.dataThrough.map({ at > $0 }) ?? true { output.dataThrough = at }
                let previous = output.state.last ?? Components()
                var deltaInput = current.input - previous.input
                var deltaCached = current.cached - previous.cached
                var deltaOutput = current.output - previous.output
                var deltaReasoning = current.reasoning - previous.reasoning
                var deltaCacheWrite = current.cacheWrite - previous.cacheWrite
                if current.total < previous.total {
                    // The counter restarted: the snapshot is the delta.
                    deltaInput = current.input; deltaCached = current.cached; deltaOutput = current.output
                    deltaReasoning = current.reasoning; deltaCacheWrite = current.cacheWrite
                }
                output.state.last = current
                deltaInput = max(0, deltaInput); deltaCached = max(0, deltaCached); deltaOutput = max(0, deltaOutput)
                deltaReasoning = max(0, deltaReasoning); deltaCacheWrite = max(0, deltaCacheWrite)
                guard deltaInput + deltaCached + deltaOutput + deltaReasoning + deltaCacheWrite > 0 else { return }
                let cacheRead = min(deltaCached, deltaInput)
                output.state.seq += 1
                output.events.append(TelemetryEvent(
                    unitId: "\(fileId)#\(output.state.seq)", provider: .codex, at: at,
                    model: output.state.model ?? "unknown",
                    input: deltaInput - cacheRead, cacheRead: cacheRead, cacheWrite: deltaCacheWrite, cacheWrite1h: 0,
                    output: deltaOutput, reasoning: min(deltaReasoning, deltaOutput), reportedCostNanoUSD: nil,
                    session: fileId, sidechain: false, source: output.state.originator,
                    fileId: fileId, sourceOffset: Int(line.offset), parserVersion: parserVersion, inFlight: false))
            default:
                return
            }
        }
    }
}
