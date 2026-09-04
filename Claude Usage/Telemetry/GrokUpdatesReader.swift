//
//  GrokUpdatesReader.swift
//  Claude Usage
//
//  Turns a Grok session's `updates.jsonl` into consumption events (spec §2.1):
//  each prompt turn ends with a `turn_completed` update carrying per-model
//  usage for THAT turn (not cumulative — verified on an 8-turn session) and
//  the CLI's own list-price figure in nano-USD. Only completed turns are
//  logged by the CLI; the window labels Grok accordingly. Deduplicated by
//  `_meta.eventId`, falling back to `<sessionId>#<prompt_id>`.
//

import Foundation

nonisolated enum GrokUpdatesReader {

    static let parserVersion = 1
    static let needles = JSONLFraming.needles(["\"turn_completed\""])

    struct Output: Sendable {
        var events: [TelemetryEvent] = []
        var malformed = 0
        var unknownShapes = 0
        var dataThrough: Date?
    }

    /// `source` is the session's working directory, decoded by the indexer
    /// from the percent-encoded directory name.
    static func parse(lines: [JSONLFraming.Line], fileId: String, source: String?) -> Output {
        var output = Output()
        for line in lines { autoreleasepool { parseLine(line, fileId: fileId, source: source, into: &output) } }
        return output
    }

    private static func parseLine(_ line: JSONLFraming.Line, fileId: String, source: String?, into output: inout Output) {
        do {
            guard let object = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else {
                output.malformed += 1
                return
            }
            guard let params = object["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed" else { return }
            guard let usage = update["usage"] as? [String: Any] else {
                output.unknownShapes += 1
                return
            }
            let session = params["sessionId"] as? String ?? fileId
            // The CLI nests `_meta` inside `params` (live shape); tolerate it at the root too.
            let meta = (params["_meta"] as? [String: Any]) ?? (object["_meta"] as? [String: Any]) ?? [:]
            let at: Date
            if let seconds = object["timestamp"] as? NSNumber {
                at = Date(timeIntervalSince1970: seconds.doubleValue)
            } else if let ms = meta["agentTimestampMs"] as? NSNumber {
                at = Date(timeIntervalSince1970: ms.doubleValue / 1_000)
            } else {
                output.unknownShapes += 1
                return
            }
            if output.dataThrough.map({ at > $0 }) ?? true { output.dataThrough = at }
            let eventId = (meta["eventId"] as? String)
                ?? "\(session)#\(update["prompt_id"] as? String ?? String(line.offset))"
            let perModel = (usage["modelUsage"] as? [String: Any])?
                .compactMapValues { $0 as? [String: Any] } ?? ["unknown": usage]
            for (model, modelUsage) in perModel.sorted(by: { $0.key < $1.key }) {
                let inputTokens = ClaudeTranscriptReader.int(modelUsage["inputTokens"])
                let cacheRead = min(ClaudeTranscriptReader.int(modelUsage["cachedReadTokens"]), inputTokens)
                let outputTokens = ClaudeTranscriptReader.int(modelUsage["outputTokens"])
                let cost = modelUsage["costUsdTicks"] as? NSNumber
                output.events.append(TelemetryEvent(
                    unitId: perModel.count == 1 ? eventId : "\(eventId)#\(model)", provider: .grok, at: at, model: model,
                    input: inputTokens - cacheRead, cacheRead: cacheRead,
                    cacheWrite: ClaudeTranscriptReader.int(modelUsage["cacheCreationTokens"]), cacheWrite1h: 0,
                    output: outputTokens, reasoning: min(ClaudeTranscriptReader.int(modelUsage["reasoningTokens"]), outputTokens),
                    reportedCostNanoUSD: cost?.intValue, session: session, sidechain: false, source: source,
                    fileId: fileId, sourceOffset: Int(line.offset), parserVersion: parserVersion, inFlight: false))
            }
        }
    }
}
