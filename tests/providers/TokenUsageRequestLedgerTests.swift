import Foundation
import XCTest
import QuotaCore
@testable import QuotaProviders

final class TokenUsageRequestLedgerTests: XCTestCase {
    let zone = TimeZone(secondsFromGMT: 0)!
    let start = QuotaRules.date("2026-10-01T00:00:00Z")!
    let end = QuotaRules.date("2026-10-02T00:00:00Z")!
    func usage(_ input: Int, cache: Int = 0, write: Int = 0, output: Int = 20) -> [String: Int] {
        ["input_tokens": input, "cached_input_tokens": cache, "cache_write_input_tokens": write,
         "output_tokens": output, "reasoning_output_tokens": output / 2, "total_tokens": input + output]
    }
    func line(_ type: String, _ payload: [String: Any], second: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": String(format: "2026-10-01T02:00:%02dZ", second), "payload": payload])
    }
    func request(_ response: String, thread: String = "child", session: String = "tree", turn: String = "turn",
                 input: Int = 100, total: Int = 100, totalOutput: Int = 20, second: Int = 1) throws -> Data {
        try line("token_usage_record", ["response_id": response, "thread_id": thread, "session_id": session,
            "turn_id": turn, "usage": usage(input, cache: 50), "thread_token_usage": usage(total, cache: total / 2, output: totalOutput)], second: second)
    }
    func testOwnedForkRequestsExcludeInheritedRowsAndDeduplicateResponses() throws {
        var p = TokenUsageLogAccumulator(agent: .codex)
        let meta = try line("session_meta", ["id": "child", "session_id": "tree", "forked_from_id": "parent"])
        let context = try line("turn_context", ["turn_id": "turn", "model": "gpt-6.1-sol"])
        for _ in 0..<2 {
            p.beginFile()
            for row in [meta, context, try request("inherited", thread: "parent"), try request("own", second: 2)] { p.consume(row) }
        }
        let result = p.result(timeZone: zone, since: start, through: end)
        XCTAssertEqual(result.buckets.first?.tokens.total, 120)
        XCTAssertEqual(result.buckets.first?.tokens.cacheRead, 50)
        XCTAssertEqual(result.buckets.first?.tokens.output, 20, "Reasoning is inside output")
        XCTAssertEqual(result.costs.first?.pricedTokens, 120)
        XCTAssertTrue(result.incomplete, "Copied parent rows remain an explicit coverage gap")
        XCTAssertEqual(result.reasons["unowned_request_rows"], 2)
    }
    func testLegacyMirrorAndRequestLedgerDoNotDoubleCountInEitherOrder() throws {
        let modern = try request("response", thread: "thread", session: "thread")
        let legacy = try line("event_msg", ["type": "token_count", "info": ["total_token_usage": usage(100, cache: 50), "last_token_usage": usage(100, cache: 50)]], second: 2)
        for pair in [[modern, legacy], [legacy, modern]] {
            var p = TokenUsageLogAccumulator(agent: .codex)
            p.consume(try line("session_meta", ["id": "thread"]))
            p.consume(try line("turn_context", ["turn_id": "turn", "model": "gpt-6.1-sol"]))
            pair.forEach { p.consume($0) }
            let result = p.result(timeZone: zone, since: start, through: end)
            XCTAssertEqual(result.buckets.first?.tokens.total, 120)
            XCTAssertEqual(result.costs.first?.pricedTokens, 120)
        }
    }
    func testLegacyPrefixRemainsAndAmbiguousPostLedgerRowsAreNotAdded() throws {
        var p = TokenUsageLogAccumulator(agent: .codex)
        p.consume(try line("session_meta", ["id": "child", "session_id": "tree"]))
        p.consume(try line("event_msg", ["type": "token_count", "info": ["total_token_usage": usage(50, cache: 25)]], second: 1))
        p.consume(try request("owned", input: 100, total: 150, totalOutput: 40, second: 2))
        p.consume(try line("event_msg", ["type": "token_count", "info": ["total_token_usage": usage(200, cache: 100)]], second: 3))
        let result = p.result(timeZone: zone, since: start, through: end)
        XCTAssertEqual(result.buckets.first?.tokens.total, 190)
        XCTAssertEqual(result.reasons["unreconciled_legacy_rows"], 1)
    }
    func testCacheWritesAreInsideCodexInputAndUnknownModelRetainsTokens() throws {
        var p = TokenUsageLogAccumulator(agent: .codex)
        p.consume(try line("session_meta", ["id": "thread"]))
        p.consume(try line("token_usage_record", ["response_id": "r", "thread_id": "thread", "model": "unknown-model",
            "usage": usage(100, cache: 30, write: 10), "thread_token_usage": usage(100, cache: 30, write: 10)]))
        let result = p.result(timeZone: zone, since: start, through: end)
        XCTAssertEqual(result.buckets.first?.tokens, TokenUsageCounts(nonCachedInput: 60, cacheRead: 30, cacheWrite: 10, output: 20))
        XCTAssertNil(result.costs.first?.standardUSD)
        XCTAssertEqual(result.costs.first?.unpricedTokens, 120)
    }
    func testSubagentLegacyHistoryIsExcludedButOwnedRequestStillCounts() throws {
        var p = TokenUsageLogAccumulator(agent: .codex)
        p.consume(try line("session_meta", ["id": "child", "session_id": "tree", "source": ["subagent": ["spawn": [:]]]]))
        p.consume(try line("event_msg", ["type": "token_count", "info": ["total_token_usage": usage(100, cache: 50)]]))
        p.consume(try request("owned"))
        let result = p.result(timeZone: zone, since: start, through: end)
        XCTAssertEqual(result.buckets.first?.tokens.total, 120)
        XCTAssertEqual(result.reasons["ambiguous_fork_rows"], 1)
    }
    func testDistinctResponsesSurviveCounterResetWhileRestampedCopyDoesNotAdd() throws {
        var p = TokenUsageLogAccumulator(agent: .codex)
        p.consume(try line("session_meta", ["id": "child", "session_id": "tree"]))
        for row in [try request("first"), try request("second", second: 2), try request("first", second: 3)] { p.consume(row) }
        let result = p.result(timeZone: zone, since: start, through: end)
        XCTAssertEqual(result.buckets.first?.tokens.total, 240)
        XCTAssertEqual(result.costs.first?.unpricedTokens, 240)
        XCTAssertFalse(result.incomplete)
    }
    func testExplicitUnknownModelAndClearedContextNeverBorrowKnownPricing() throws {
        for explicit in ["", "Future Model", "unknown-model"] {
            var p = TokenUsageLogAccumulator(agent: .codex)
            p.consume(try line("session_meta", ["id": "child", "session_id": "tree"]))
            p.consume(try line("turn_context", ["turn_id": "turn", "model": "gpt-6.1-sol"]))
            p.consume(try line("token_usage_record", ["response_id": "r", "thread_id": "child", "session_id": "tree", "turn_id": "turn",
                "model": explicit, "usage": usage(100), "thread_token_usage": usage(100)]))
            let result = p.result(timeZone: zone, since: start, through: end)
            XCTAssertEqual(result.costs.first?.unpricedTokens, 120)
            XCTAssertNil(result.costs.first?.standardUSD)
        }
        var p = TokenUsageLogAccumulator(agent: .codex)
        for row in [try line("session_meta", ["id": "child", "session_id": "tree"]),
                    try line("turn_context", ["turn_id": "turn", "model": "gpt-6.1-sol"]),
                    try line("turn_context", ["turn_id": "turn", "model": ""]), try request("r")] { p.consume(row) }
        XCTAssertNil(p.result(timeZone: zone, since: start, through: end).costs.first?.standardUSD)
    }
    func testConflictingResponseIsTombstonedInBothOrdersIncludingLegacyMirrorsAndReplays() throws {
        let first = try request("conflict", input: 100, total: 100)
        let conflicting = try request("conflict", input: 200, total: 300)
        let legacy = try line("event_msg", ["type": "token_count", "info": ["model": "gpt-6.1-sol",
            "total_token_usage": usage(300, cache: 150), "last_token_usage": usage(200, cache: 50)]])
        for pair in [[first, conflicting], [conflicting, first]] {
            var p = TokenUsageLogAccumulator(agent: .codex)
            p.consume(try line("session_meta", ["id": "child", "session_id": "tree"]))
            p.consume(try line("turn_context", ["turn_id": "turn", "model": "gpt-6.1-sol"]))
            for row in [legacy] + pair + [first, conflicting, try request("trusted", second: 4)] { p.consume(row) }
            let result = p.result(timeZone: zone, since: start, through: end)
            XCTAssertEqual(result.buckets.first?.tokens.total, 120, "Only the distinct trusted response survives")
            XCTAssertEqual(result.costs.first?.pricedTokens, 120)
            XCTAssertEqual(result.reasons["conflicting_request_rows"], 3)
            XCTAssertEqual(result.reasons["unreconciled_legacy_rows"], 1)
            XCTAssertTrue(result.incomplete)
        }
    }
    func testLegacyConflictingModelOrRequestEvidenceRemainsUnpricedInBothOrdersAndReplays() throws {
        func legacy(_ model: String, input: Int) throws -> Data {
            try line("event_msg", ["type": "token_count", "info": ["model": model,
                "total_token_usage": usage(100, cache: 50), "last_token_usage": usage(input, cache: input / 2)]])
        }
        let priced = try legacy("gpt-6.1-sol", input: 100)
        for uncertain in [try legacy("gpt-6-astra", input: 100), try legacy("gpt-6.1-sol", input: 50)] {
            for pair in [[priced, uncertain], [uncertain, priced]] {
                var p = TokenUsageLogAccumulator(agent: .codex)
                p.consume(try line("session_meta", ["id": "child"]))
                for row in pair + [priced, uncertain, priced] { p.consume(row) }
                let result = p.result(timeZone: zone, since: start, through: end)
                XCTAssertEqual(result.buckets.first?.tokens.total, 120)
                XCTAssertEqual(result.costs.first?.unpricedTokens, 120)
                XCTAssertNil(result.costs.first?.standardUSD)
            }
        }
    }
    func testClaudeConflictingKnownCacheTTLRemainsUnpricedInBothOrdersAndLaterReplays() throws {
        func claude(_ hour: Int, write: Int = 100) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "assistant", "timestamp": "2026-10-01T02:00:00Z",
                "message": ["id": "synthetic", "model": "claude-sonnet-4-6", "usage": ["input_tokens": 100,
                    "output_tokens": 20, "cache_creation_input_tokens": write,
                    "cache_creation": ["ephemeral_5m_input_tokens": write - hour, "ephemeral_1h_input_tokens": hour]]]])
        }
        let five = try claude(0), hour = try claude(100)
        for pair in [[five, hour], [hour, five]] {
            var p = TokenUsageLogAccumulator(agent: .claudeCode)
            for row in pair + [five, hour, try claude(0, write: 200)] { p.consume(row) }
            let result = p.result(timeZone: zone, since: start, through: end)
            XCTAssertEqual(result.buckets.first?.tokens.total, 320)
            XCTAssertEqual(result.costs.first?.unpricedTokens, 320)
            XCTAssertNil(result.costs.first?.standardUSD)
        }
    }
    func testClaudeKnownTTLConstraintsSurviveUnknownUpdatesInEveryOrder() throws {
        func claude(_ hour: Int?, write: Int) throws -> Data {
            var usage: [String: Any] = ["input_tokens": 100, "output_tokens": 20, "cache_creation_input_tokens": write]
            if let hour { usage["cache_creation"] = ["ephemeral_5m_input_tokens": write - hour, "ephemeral_1h_input_tokens": hour] }
            return try JSONSerialization.data(withJSONObject: ["type": "assistant", "timestamp": "2026-10-01T02:00:00Z",
                "message": ["id": "synthetic", "model": "claude-sonnet-4-6", "usage": usage]])
        }
        let rows = [try claude(100, write: 100), try claude(nil, write: 200), try claude(0, write: 200)]
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            var p = TokenUsageLogAccumulator(agent: .claudeCode)
            for index in order + [1, 0, 2] { p.consume(rows[index]) }
            let result = p.result(timeZone: zone, since: start, through: end)
            XCTAssertEqual(result.buckets.first?.tokens.total, 320)
            XCTAssertEqual(result.costs.first?.unpricedTokens, 320)
            XCTAssertNil(result.costs.first?.standardUSD)
        }
        var compatible = TokenUsageLogAccumulator(agent: .claudeCode)
        for row in [rows[0], rows[1], try claude(100, write: 200)] { compatible.consume(row) }
        XCTAssertNotNil(compatible.result(timeZone: zone, since: start, through: end).costs.first?.standardUSD,
            "A proven larger distribution compatible with earlier counters is priceable")
    }
    func testExistingTurnContextCanInvalidateModelAtContextLimit() throws {
        var p = TokenUsageLogAccumulator(agent: .codex)
        p.consume(try line("session_meta", ["id": "child", "session_id": "tree"]))
        for index in 0..<10_000 { p.consume(try line("turn_context", ["turn_id": "turn-\(index)", "model": "gpt-6.1-sol"])) }
        p.consume(try line("turn_context", ["turn_id": "turn-0", "model": ""]))
        p.consume(try request("owned", turn: "turn-0"))
        let result = p.result(timeZone: zone, since: start, through: end)
        XCTAssertEqual(result.costs.first?.unpricedTokens, 120)
        XCTAssertNil(result.costs.first?.standardUSD, "Capacity must not retain a previously known model after invalidation")
    }
    func testClaudeConflictingSmallerDistributionsAreDetectedBehindLargerKnownCounters() throws {
        func row(write: Int, hour: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "assistant", "timestamp": "2026-10-01T02:00:00Z",
                "message": ["id": "synthetic", "model": "claude-sonnet-4-6", "usage": ["input_tokens": 100,
                    "output_tokens": 20, "cache_creation_input_tokens": write,
                    "cache_creation": ["ephemeral_5m_input_tokens": write - hour, "ephemeral_1h_input_tokens": hour]]]])
        }
        let rows = [try row(write: 200, hour: 100), try row(write: 100, hour: 0), try row(write: 100, hour: 100)]
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            var p = TokenUsageLogAccumulator(agent: .claudeCode)
            for index in order + [0, 1, 2] { p.consume(rows[index]) }
            let result = p.result(timeZone: zone, since: start, through: end)
            XCTAssertEqual(result.buckets.first?.tokens.total, 320)
            XCTAssertNil(result.costs.first?.standardUSD)
            XCTAssertEqual(result.costs.first?.unpricedTokens, 320)
        }
        var bounded = TokenUsageLogAccumulator(agent: .claudeCode)
        for write in 1...9 { bounded.consume(try row(write: write, hour: 0)) }
        let result = bounded.result(timeZone: zone, since: start, through: end)
        XCTAssertEqual(result.buckets.first?.tokens.total, 129)
        XCTAssertNil(result.costs.first?.standardUSD, "Evidence beyond the bound cannot produce an assumed price")
    }
    func testOversizedTranscriptLineDoesNotHideLaterValidUsage() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = try line("session_meta", ["id": "child", "session_id": "tree"]); data.append(10)
        data.append(Data(repeating: 65, count: 2_097_153)); data.append(10)
        data.append(try request("after-huge-content")); data.append(10)
        try data.write(to: root.appendingPathComponent("synthetic.jsonl"))
        let result = try TokenUsageScanner.analyze(roots: .init(claude: [], codex: [root]), timeZone: zone,
            now: end, deviceID: "test", epoch: "test", sequence: 1, byteLimit: data.count)
        XCTAssertEqual(result.snapshot.buckets.first?.tokens.total, 120)
        XCTAssertEqual(result.localAnalysis?.sources.first(where: { $0.agent == .codex })?.reasons["oversized_lines"], 1)
        XCTAssertEqual(result.snapshot.sources.first(where: { $0.agent == .codex })?.status, .partial)
        XCTAssertTrue(try XCTUnwrap(result.localAnalysis).isValid(for: result.snapshot))
    }
    func testUnchangedNumericCacheInvalidatesOnFileAndTimezoneChangesAndClockRewind() throws {
        TokenUsageScanner.clearCachedAnalysis()
        defer { TokenUsageScanner.clearCachedAnalysis() }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.jsonl")
        var data = try line("session_meta", ["id": "child", "session_id": "tree"]); data.append(10)
        data.append(try request("first")); data.append(10); try data.write(to: file)
        let roots = TokenUsageLogRoots(claude: [], codex: [root])
        func scan(_ now: Date, _ zone: TimeZone) throws -> TokenUsageScanResult {
            try TokenUsageScanner.analyze(roots: roots, timeZone: zone, now: now, deviceID: "test", epoch: "test", sequence: 1, byteLimit: 100_000)
        }
        let initial = try scan(end, zone), repeated = try scan(end, zone)
        XCTAssertEqual(repeated.snapshot.buckets, initial.snapshot.buckets)
        XCTAssertTrue(try XCTUnwrap(repeated.localAnalysis?.sources.first(where: { $0.agent == .codex })).reusedUnchangedFiles)
        XCTAssertEqual(repeated.localAnalysis?.sources.first(where: { $0.agent == .codex })?.bytesRead, 0)
        data.append(try request("second", total: 200, totalOutput: 40, second: 2)); data.append(10); try data.write(to: file)
        let changed = try scan(end, zone)
        XCTAssertEqual(changed.snapshot.buckets.first?.tokens.total, 240)
        XCTAssertFalse(try XCTUnwrap(changed.localAnalysis?.sources.first(where: { $0.agent == .codex })).reusedUnchangedFiles)
        let moved = try scan(end, TimeZone(identifier: "Asia/Singapore")!)
        XCTAssertFalse(try XCTUnwrap(moved.localAnalysis?.sources.first(where: { $0.agent == .codex })).reusedUnchangedFiles)
        _ = try scan(QuotaRules.date("2026-10-01T03:00:00Z")!, zone)
        let rewind = try scan(QuotaRules.date("2026-10-01T01:00:00Z")!, zone)
        XCTAssertTrue(rewind.snapshot.buckets.isEmpty)
    }
}
