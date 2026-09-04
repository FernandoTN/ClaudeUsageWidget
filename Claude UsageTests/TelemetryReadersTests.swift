//
//  TelemetryReadersTests.swift
//  Claude UsageTests
//
//  The three log readers against fixture lines shaped like the real files
//  (docs/research/2026-09-04-token-telemetry-sources.md): Claude's per-block
//  duplication and in-flight finalize, the all-zero / synthetic skips and the
//  rate-limit marker; Codex's cumulative component deltas, repeated
//  snapshots, negative steps, the external-import trap and counter resets;
//  Grok's per-turn per-model usage, eventId dedup and null cost.
//

import XCTest
@testable import Claude_Usage

final class TelemetryReadersTests: XCTestCase {

    private func lines(_ strings: [String]) -> [JSONLFraming.Line] {
        var offset: Int64 = 0
        return strings.map { s in
            defer { offset += Int64(s.utf8.count) + 1 }
            return JSONLFraming.Line(offset: offset, data: Data(s.utf8))
        }
    }

    // MARK: - Claude

    private let claudeBlock0 = #"{"parentUuid":"p","isSidechain":false,"type":"assistant","uuid":"u1","timestamp":"2026-09-01T10:00:01.000Z","sessionId":"S1","cwd":"/Users/x/Projects/Demo","requestId":"req_1","apiBlockIndex":0,"message":{"id":"msg_1","model":"claude-opus-5","role":"assistant","stop_reason":"tool_use","usage":{"input_tokens":2,"cache_creation_input_tokens":3000,"cache_read_input_tokens":40000,"output_tokens":4,"output_tokens_details":{"thinking_tokens":2},"cache_creation":{"ephemeral_1h_input_tokens":3000,"ephemeral_5m_input_tokens":0},"iterations":[{"input_tokens":2,"output_tokens":4}]},"content":[{"type":"thinking","thinking":"…"}]}}"#
    private let claudeBlock1 = #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"u2","timestamp":"2026-09-01T10:00:03.000Z","sessionId":"S1","cwd":"/Users/x/Projects/Demo","requestId":"req_1","apiBlockIndex":1,"message":{"id":"msg_1","model":"claude-opus-5","role":"assistant","stop_reason":"tool_use","usage":{"input_tokens":2,"cache_creation_input_tokens":3000,"cache_read_input_tokens":40000,"output_tokens":1730,"output_tokens_details":{"thinking_tokens":900},"cache_creation":{"ephemeral_1h_input_tokens":3000,"ephemeral_5m_input_tokens":0}},"content":[{"type":"tool_use","name":"Bash"}]}}"#
    private let claudeSidechain = #"{"type":"assistant","uuid":"u3","timestamp":"2026-09-01T10:00:05.000Z","sessionId":"S1","isSidechain":true,"cwd":"/Users/x/Projects/Demo","message":{"id":"msg_2","model":"claude-fable-5-1","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":500,"output_tokens":50}}}"#
    private let claudeDeath = #"{"type":"assistant","uuid":"u4","timestamp":"2026-09-01T10:00:06.000Z","sessionId":"S1","error":"rate_limit","apiErrorStatus":429,"message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"text","text":"You've hit your session limit · resets 10:20pm (America/Los_Angeles)"}]}}"#
    private let claudeAuthError = #"{"type":"assistant","uuid":"u5","timestamp":"2026-09-01T10:00:07.000Z","sessionId":"S1","error":"authentication_failed","message":{"model":"claude-opus-5","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#

    func testClaudeCollapsesBlocksKeepsTheFullerSnapshotAndSkipsErrors() {
        let out = ClaudeTranscriptReader.parse(
            lines: lines([claudeBlock0, claudeBlock1, claudeSidechain, claudeDeath, claudeAuthError]),
            fileId: "claude:proj/S1.jsonl", state: .init())
        XCTAssertEqual(out.events.count, 2)
        let first = out.events[0]
        XCTAssertEqual(first.unitId, "msg_1")
        XCTAssertEqual(first.output, 1730, "the fuller block wins; iterations[] is never summed")
        XCTAssertEqual(first.reasoning, 900)
        XCTAssertEqual(first.input, 2, "Claude's input_tokens is already uncached — never input − cacheRead")
        XCTAssertEqual(first.cacheRead, 40_000)
        XCTAssertEqual(first.cacheWrite, 3_000)
        XCTAssertEqual(first.cacheWrite1h, 3_000)
        XCTAssertFalse(first.inFlight, "a different message followed it")
        XCTAssertEqual(first.source, "Demo")
        XCTAssertEqual(first.session, "S1")
        XCTAssertEqual(first.sourceOffset, claudeBlock0.utf8.count + 1, "the offset of the winning (fuller) block")
        let second = out.events[1]
        XCTAssertEqual(second.unitId, "msg_2")
        XCTAssertTrue(second.sidechain)
        XCTAssertTrue(second.inFlight, "the last message of the file is still being written")
        XCTAssertEqual(out.state.pending?.event.unitId, "msg_2")
        XCTAssertEqual(out.markers.count, 1, "the synthetic death is a marker; the all-zero auth error is neither")
        XCTAssertEqual(out.markers[0].kind, .rateLimit)
        XCTAssertEqual(out.markers[0].detail?.contains("resets 10:20pm"), true)
        XCTAssertEqual(out.dataThrough, JSONLFraming.parseISODate("2026-09-01T10:00:07.000Z"))
    }

    func testClaudeInFlightMessageIsCompletedAcrossPasses() {
        let pass1 = ClaudeTranscriptReader.parse(lines: lines([claudeBlock0]), fileId: "f", state: .init())
        XCTAssertEqual(pass1.events.map(\.output), [4])
        XCTAssertTrue(pass1.events[0].inFlight)
        let pass2 = ClaudeTranscriptReader.parse(lines: lines([claudeBlock1, claudeSidechain]), fileId: "f", state: pass1.state)
        XCTAssertEqual(pass2.events.map(\.unitId), ["msg_1", "msg_2"])
        XCTAssertEqual(pass2.events[0].output, 1730)
        XCTAssertFalse(pass2.events[0].inFlight)
    }

    func testClaudeMalformedLinesAreCountedNotFatal() {
        let out = ClaudeTranscriptReader.parse(lines: lines(["{not json", claudeSidechain]), fileId: "f", state: .init())
        XCTAssertEqual(out.malformed, 1)
        XCTAssertEqual(out.events.count, 1)
    }

    // MARK: - Codex

    private func codexTotals(_ ts: String, input: Int, cached: Int, output: Int, reasoning: Int, total: Int, cacheWrite: Int? = nil) -> String {
        let write = cacheWrite.map { ",\"cache_write_input_tokens\":\($0)" } ?? ""
        return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total)\#(write)},"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":0.0,"window_minutes":10080}}}}"#
    }

    func testCodexDeltasComponentsSkipsRepeatsClampsNegativesAndFollowsTheModel() {
        let fixture = [
            #"{"timestamp":"2026-07-25T21:39:42.288Z","type":"session_meta","payload":{"id":"sid","originator":"codex_exec","source":"exec","cwd":"/x"}}"#,
            #"{"timestamp":"2026-07-25T21:39:42.300Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"xhigh"}}"#,
            codexTotals("2026-07-25T21:39:52.332Z", input: 30_251, cached: 0, output: 312, reasoning: 149, total: 30_563),
            codexTotals("2026-07-25T21:39:53.000Z", input: 30_251, cached: 0, output: 312, reasoning: 149, total: 30_563),
            codexTotals("2026-07-25T21:39:56.196Z", input: 60_827, cached: 29_440, output: 477, reasoning: 159, total: 61_304),
            codexTotals("2026-07-25T21:40:00.000Z", input: 61_000, cached: 29_440, output: 400, reasoning: 100, total: 61_400),
            #"{"timestamp":"2026-07-25T21:41:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            codexTotals("2026-07-25T21:41:05.000Z", input: 61_500, cached: 29_540, output: 450, reasoning: 120, total: 61_950, cacheWrite: 7),
            codexTotals("2026-07-25T21:42:00.000Z", input: 100, cached: 0, output: 5, reasoning: 1, total: 105),
        ]
        let out = CodexRolloutReader.parse(lines: lines(fixture), fileId: "codex:rollout-x.jsonl", state: .init())
        XCTAssertEqual(out.events.count, 5, "the repeated snapshot adds nothing")
        XCTAssertEqual(out.events.map(\.unitId), (1...5).map { "codex:rollout-x.jsonl#\($0)" })
        XCTAssertEqual(out.events[0].input, 30_251); XCTAssertEqual(out.events[0].output, 312); XCTAssertEqual(out.events[0].reasoning, 149)
        XCTAssertEqual(out.events[1].cacheRead, 29_440); XCTAssertEqual(out.events[1].input, 30_576 - 29_440)
        XCTAssertEqual(out.events[1].output, 165); XCTAssertEqual(out.events[1].reasoning, 10)
        XCTAssertEqual(out.events[2].input, 173, "input still moved")
        XCTAssertEqual(out.events[2].output, 0, "an output counter that stepped backwards is clamped, never re-added")
        XCTAssertEqual(out.events[2].reasoning, 0)
        XCTAssertEqual(out.events[3].model, "gpt-5.5", "the model follows the latest turn_context")
        XCTAssertEqual(out.events[3].cacheWrite, 7)
        XCTAssertEqual(out.events[3].output, 50)
        XCTAssertEqual(out.events[3].reasoning, 20)
        XCTAssertEqual(out.events[4].input, 100, "a dropped total means a fresh counter: the snapshot is the delta")
        XCTAssertEqual(out.events[4].output, 5)
        XCTAssertEqual(out.events.map(\.source), Array(repeating: "codex_exec", count: 5))
        XCTAssertEqual(out.events.map(\.model).prefix(3), ["gpt-5.6-sol", "gpt-5.6-sol", "gpt-5.6-sol"])
        XCTAssertEqual(out.state.seq, 5)
        XCTAssertEqual(out.state.model, "gpt-5.5")
    }

    func testCodexExternalImportSnapshotEmitsNothingAndUnknownModelWhenNoTurnContext() {
        let fixture = [
            #"{"timestamp":"2026-08-11T19:05:05.000Z","type":"response_item","payload":{"type":"message","content":"<EXTERNAL SESSION IMPORTED>"}}"#,
            codexTotals("2026-08-11T19:05:06.000Z", input: 0, cached: 0, output: 0, reasoning: 0, total: 11_177),
            codexTotals("2026-08-11T19:06:06.000Z", input: 500, cached: 0, output: 20, reasoning: 0, total: 11_697),
        ]
        let out = CodexRolloutReader.parse(lines: lines(fixture), fileId: "codex:r.jsonl", state: .init())
        XCTAssertEqual(out.events.count, 1, "the all-zero-component import snapshot books nothing")
        XCTAssertEqual(out.events[0].input, 500)
        XCTAssertEqual(out.events[0].model, "unknown")
        XCTAssertNil(out.firstModel)
    }

    func testCodexUnitsBeforeTheFirstTurnContextTakeItsModel() {
        let fixture = [
            codexTotals("2026-07-25T21:39:52.332Z", input: 1_000, cached: 0, output: 10, reasoning: 1, total: 1_010),
            #"{"timestamp":"t","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            codexTotals("2026-07-25T21:39:55.000Z", input: 1_500, cached: 0, output: 30, reasoning: 5, total: 1_530),
        ]
        let out = CodexRolloutReader.parse(lines: lines(fixture), fileId: "f", state: .init())
        XCTAssertEqual(out.events.map(\.model), ["gpt-5.6-sol", "gpt-5.6-sol"], "same parse: fixed in place")
        XCTAssertEqual(out.firstModel, "gpt-5.6-sol", "the indexer reassigns earlier slices' 'unknown' units for this file")
        // A later model change is not a first sighting.
        let later = CodexRolloutReader.parse(lines: lines([#"{"timestamp":"t","type":"turn_context","payload":{"model":"gpt-5.5"}}"#]),
                                             fileId: "f", state: out.state)
        XCTAssertNil(later.firstModel)
        XCTAssertEqual(later.state.model, "gpt-5.5")
    }

    func testCodexStateResumesAcrossPasses() {
        let first = CodexRolloutReader.parse(lines: lines([
            #"{"timestamp":"t","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            codexTotals("2026-07-25T21:39:52.332Z", input: 1_000, cached: 100, output: 10, reasoning: 1, total: 1_010),
        ]), fileId: "f", state: .init())
        let second = CodexRolloutReader.parse(lines: lines([
            codexTotals("2026-07-25T21:39:55.000Z", input: 1_500, cached: 200, output: 30, reasoning: 5, total: 1_530),
        ]), fileId: "f", state: first.state)
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(second.events[0].unitId, "f#2")
        XCTAssertEqual(second.events[0].input, 400)
        XCTAssertEqual(second.events[0].cacheRead, 100)
        XCTAssertEqual(second.events[0].output, 20)
        XCTAssertEqual(second.events[0].model, "gpt-5.6-sol")
    }

    // MARK: - Grok

    private func grokTurn(ts: Int, eventId: String, promptId: String, models: String) -> String {
        #"{"timestamp":\#(ts),"method":"_x.ai/session/update","params":{"sessionId":"01a06a5e","update":{"sessionUpdate":"turn_completed","prompt_id":"\#(promptId)","stop_reason":"end_turn","usage":{"inputTokens":7004569,"outputTokens":34345,"totalTokens":7038914,"cachedReadTokens":6571520,"cacheCreationTokens":0,"reasoningTokens":18391,"modelCalls":49,"costUsdTicks":8743001400,"modelUsage":{\#(models)},"numTurns":49}},"_meta":{"eventId":"\#(eventId)","agentTimestampMs":\#(ts)000}}}"#
    }

    func testGrokSumsPerTurnPerModelWithCostAndDedupKey() {
        let one = #""grok-4.6-build":{"inputTokens":7004569,"outputTokens":34345,"totalTokens":7038914,"cachedReadTokens":6571520,"cacheCreationTokens":0,"reasoningTokens":18391,"modelCalls":49,"costUsdTicks":8743001400}"#
        let two = #""grok-4.6-build":{"inputTokens":1000,"outputTokens":100,"cachedReadTokens":600,"cacheCreationTokens":0,"reasoningTokens":40,"costUsdTicks":null},"grok-4.5-build":{"inputTokens":300,"outputTokens":30,"cachedReadTokens":0,"cacheCreationTokens":5,"reasoningTokens":0,"costUsdTicks":12000}"#
        let fixture = [
            #"{"timestamp":1788490978,"method":"session/update","params":{"sessionId":"01a06a5e","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"hi"}}}}"#,
            grokTurn(ts: 1_788_491_778, eventId: "01a06a5e-5445", promptId: "p1", models: one),
            grokTurn(ts: 1_788_491_900, eventId: "01a06a5e-6000", promptId: "p2", models: two),
        ]
        let out = GrokUpdatesReader.parse(lines: lines(fixture), fileId: "grok:01a06a5e", source: "ClaudeUsageWidget")
        XCTAssertEqual(out.events.count, 3)
        let first = out.events[0]
        XCTAssertEqual(first.unitId, "01a06a5e-5445", "a single-model turn keeps the bare eventId")
        XCTAssertEqual(first.input, 7_004_569 - 6_571_520)
        XCTAssertEqual(first.cacheRead, 6_571_520)
        XCTAssertEqual(first.output, 34_345)
        XCTAssertEqual(first.reasoning, 18_391)
        XCTAssertEqual(first.reportedCostNanoUSD, 8_743_001_400)
        XCTAssertEqual(first.at, Date(timeIntervalSince1970: 1_788_491_778))
        XCTAssertEqual(first.source, "ClaudeUsageWidget")
        XCTAssertEqual(first.session, "01a06a5e")
        XCTAssertEqual(out.events[1].unitId, "01a06a5e-6000#grok-4.5-build")
        XCTAssertEqual(out.events[1].cacheWrite, 5)
        XCTAssertEqual(out.events[1].reportedCostNanoUSD, 12_000)
        XCTAssertEqual(out.events[2].unitId, "01a06a5e-6000#grok-4.6-build")
        XCTAssertNil(out.events[2].reportedCostNanoUSD, "a null cost is omitted, never interpolated")
        XCTAssertEqual(out.events[2].input, 400)
        XCTAssertEqual(out.dataThrough, Date(timeIntervalSince1970: 1_788_491_900))
    }

    // MARK: - Framing

    func testFramingReturnsCompleteMatchingLinesAndStopsBeforeATrailingFragment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cuw-framing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jsonl")
        let body = "{\"type\":\"user\"}\n{\"type\":\"assistant\",\"n\":1}\n{\"type\":\"assistant\",\"n\":2}\n{\"type\":\"assis"
        try Data(body.utf8).write(to: url)
        let size = Int64(body.utf8.count)
        let result = try JSONLFraming.readLines(url: url, from: 0, limit: size, maxBytes: 1 << 20,
                                                needles: ClaudeTranscriptReader.needles)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].offset, Int64("{\"type\":\"user\"}\n".utf8.count))
        XCTAssertEqual(result.nextOffset, Int64(body.utf8.count - "{\"type\":\"assis".utf8.count), "never past the last complete newline")
        XCTAssertFalse(result.hitByteBound)

        // A tiny byte budget stops early and says so; the offset still lands on a newline.
        let bounded = try JSONLFraming.readLines(url: url, from: 0, limit: size, maxBytes: 20, needles: ClaudeTranscriptReader.needles)
        XCTAssertTrue(bounded.hitByteBound)
        XCTAssertEqual(bounded.nextOffset, Int64("{\"type\":\"user\"}\n".utf8.count))
        XCTAssertTrue(bounded.lines.isEmpty)
    }
}
