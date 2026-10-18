import Foundation
import XCTest
import QuotaCore
@testable import QuotaProviders

final class TokenUsageLogTests: XCTestCase {
    let zone = TimeZone(identifier: "Etc/UTC")!
    let start = QuotaRules.date("2026-09-01T00:00:00Z")!
    let end = QuotaRules.date("2026-10-02T03:00:00Z")!
    let meta = #"{"type":"session_meta","payload":{"id":"synthetic-session","timestamp":"2026-10-01T00:00:00Z"}}"#
    func claude(_ output: Int, id: String = "synthetic-message") -> String {
        #"{"type":"assistant","timestamp":"2026-10-01T02:00:00Z","requestId":"test-request","message":{"id":"\#(id)","content":[{"text":"PRIVATE CONTENT MUST NOT LEAVE PARSER"}],"usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":30,"output_tokens":\#(output)}}}"#
    }
    func codex(input: Int, cache: Int, output: Int, second: Int = 1) -> String {
        #"{"timestamp":"2026-10-01T02:00:0\#(second)Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cache),"output_tokens":\#(output),"reasoning_output_tokens":5,"total_tokens":\#(input + output)},"last_token_usage":{"input_tokens":999999,"output_tokens":999999}}}}"#
    }
    func pricedLegacy(input: Int, cache: Int, output: Int, lastInput: Int, lastCache: Int, lastOutput: Int, second: Int,
                      explicitModel: String? = nil, turn: String? = nil) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: Data(codex(input: input, cache: cache, output: output, second: second).utf8)) as! [String: Any]
        var payload = object["payload"] as! [String: Any]
        var info = payload["info"] as! [String: Any]
        info["last_token_usage"] = ["input_tokens": lastInput, "cached_input_tokens": lastCache, "output_tokens": lastOutput, "total_tokens": lastInput + lastOutput]
        if let explicitModel { info["model"] = explicitModel }
        if let turn { payload["turn_id"] = turn }
        payload["info"] = info; object["payload"] = payload
        return try JSONSerialization.data(withJSONObject: object)
    }
    func testLegacyNoTurnIDUsesPrecedingFileContextAndChangesModels() throws {
        var parser = TokenUsageLogAccumulator(agent: .codex)
        parser.consume(Data(meta.utf8))
        parser.consume(Data(#"{"type":"turn_context","payload":{"turn_id":"first","model":"gpt-6-luna"}}"#.utf8))
        parser.consume(try pricedLegacy(input: 100, cache: 80, output: 20, lastInput: 100, lastCache: 80, lastOutput: 20, second: 1))
        parser.consume(Data(#"{"type":"turn_context","payload":{"turn_id":"second","model":"gpt-6.1-sol"}}"#.utf8))
        parser.consume(try pricedLegacy(input: 150, cache: 100, output: 40, lastInput: 50, lastCache: 20, lastOutput: 20, second: 2))
        let result = parser.result(timeZone: zone, since: start, through: end)
        let first = try XCTUnwrap(TokenUsagePricing.standardUSD(agent: .codex, model: "gpt-6-luna", counts: .init(nonCachedInput: 20, cacheRead: 80, output: 20), requestInput: 100))
        let second = try XCTUnwrap(TokenUsagePricing.standardUSD(agent: .codex, model: "gpt-6.1-sol", counts: .init(nonCachedInput: 30, cacheRead: 20, output: 20), requestInput: 50))
        XCTAssertEqual(try XCTUnwrap(result.costs.first?.standardUSD), first + second, accuracy: 1e-12)
        XCTAssertEqual(result.costs.first?.pricedTokens, 190)
        XCTAssertEqual(result.buckets.first?.tokens.total, 190)
    }
    func testLegacyUnknownEvidenceNeverBorrowsActiveContext() throws {
        for context in [#"{"model":"INVALID MODEL"}"#, #"{}"#] {
            var parser = TokenUsageLogAccumulator(agent: .codex)
            parser.consume(Data(meta.utf8))
            parser.consume(Data(#"{"type":"turn_context","payload":{"turn_id":"known","model":"gpt-6-luna"}}"#.utf8))
            parser.consume(Data(("{\"type\":\"turn_context\",\"payload\":" + context + "}").utf8))
            parser.consume(try pricedLegacy(input: 100, cache: 80, output: 20, lastInput: 100, lastCache: 80, lastOutput: 20, second: 1))
            XCTAssertNil(parser.result(timeZone: zone, since: start, through: end).costs.first?.standardUSD)
        }
        for (model, turn) in [("INVALID MODEL", nil), (nil, "unknown")] as [(String?, String?)] {
            var parser = TokenUsageLogAccumulator(agent: .codex)
            parser.consume(Data(meta.utf8))
            parser.consume(Data(#"{"type":"turn_context","payload":{"turn_id":"known","model":"gpt-6-luna"}}"#.utf8))
            parser.consume(try pricedLegacy(input: 100, cache: 80, output: 20, lastInput: 100, lastCache: 80, lastOutput: 20, second: 1, explicitModel: model, turn: turn))
            XCTAssertNil(parser.result(timeZone: zone, since: start, through: end).costs.first?.standardUSD)
        }
    }
    func testLegacyMalformedContextClearsModelWithoutDroppingTokenCounts() throws {
        for context in [#"{}"#, #"{"payload":null}"#, #"{"payload":"invalid"}"#, #"{"payload":[]}"#] {
            var parser = TokenUsageLogAccumulator(agent: .codex)
            parser.consume(Data(meta.utf8))
            parser.consume(Data(#"{"type":"turn_context","payload":{"model":"gpt-6-luna"}}"#.utf8))
            var object = try JSONSerialization.jsonObject(with: Data(context.utf8)) as! [String: Any]
            object["type"] = "turn_context"
            parser.consume(try JSONSerialization.data(withJSONObject: object))
            parser.consume(try pricedLegacy(input: 100, cache: 80, output: 20, lastInput: 100, lastCache: 80, lastOutput: 20, second: 1))
            let result = parser.result(timeZone: zone, since: start, through: end)
            XCTAssertEqual(result.buckets.first?.tokens.total, 120)
            XCTAssertEqual(result.costs.first?.unpricedTokens, 120)
            XCTAssertNil(result.costs.first?.standardUSD)
            XCTAssertTrue(result.incomplete)
        }
    }
    func testLegacyUnreadableRowOrScannerGapInvalidatesOnlyFallbackPrice() throws {
        for gap in [Data(#"{"type":"turn_context","payload":"#.utf8), Data("[]".utf8), Data(repeating: 32, count: 2_097_153), nil] as [Data?] {
            var parser = TokenUsageLogAccumulator(agent: .codex)
            parser.consume(Data(meta.utf8))
            parser.consume(Data(#"{"type":"turn_context","payload":{"model":"gpt-6-luna"}}"#.utf8))
            if let gap { parser.consume(gap) } else { parser.markIncomplete("oversized_lines") }
            parser.consume(try pricedLegacy(input: 100, cache: 80, output: 20, lastInput: 100, lastCache: 80, lastOutput: 20, second: 1))
            let result = parser.result(timeZone: zone, since: start, through: end)
            XCTAssertEqual(result.buckets.first?.tokens.total, 120)
            XCTAssertEqual(result.costs.first?.unpricedTokens, 120)
            XCTAssertNil(result.costs.first?.standardUSD)
            XCTAssertTrue(result.incomplete)
        }
    }
    func testScannerOversizedSkippedRowCannotCarryFallbackModel() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = Data((meta + "\n" + #"{"type":"turn_context","payload":{"model":"gpt-6-luna"}}"# + "\n").utf8)
        data.append(Data(repeating: 32, count: 2_097_153)); data.append(Data("\n".utf8))
        data.append(try pricedLegacy(input: 100, cache: 80, output: 20, lastInput: 100, lastCache: 80, lastOutput: 20, second: 1))
        try data.write(to: root.appendingPathComponent("synthetic.jsonl"))
        let result = try TokenUsageScanner.scanWithAnalysis(roots: .init(claude: [], codex: [root]), timeZone: zone, now: end,
            deviceID: "synthetic", epoch: "synthetic", sequence: 1)
        XCTAssertEqual(result.snapshot.buckets.first?.tokens.total, 120)
        XCTAssertEqual(result.localAnalysis?.costs.first?.unpricedTokens, 120)
        XCTAssertNil(result.localAnalysis?.costs.first?.standardUSD)
        XCTAssertEqual(result.localAnalysis?.sources.first(where: { $0.agent == .codex })?.reasons["oversized_lines"], 1)
    }
    func testLegacyContextDoesNotCrossFiles() throws {
        var parser = TokenUsageLogAccumulator(agent: .codex)
        parser.consume(Data(#"{"type":"turn_context","payload":{"turn_id":"known","model":"gpt-6-luna"}}"#.utf8))
        parser.beginFile()
        parser.consume(Data(meta.utf8))
        parser.consume(try pricedLegacy(input: 100, cache: 80, output: 20, lastInput: 100, lastCache: 80, lastOutput: 20, second: 1))
        XCTAssertEqual(parser.result(timeZone: zone, since: start, through: end).costs.first?.unpricedTokens, 120)
    }
    func testClaudeStreamingAndCopiedRequestsReplaceRatherThanAdd() throws {
        var parser = TokenUsageLogAccumulator(agent: .claudeCode)
        var noRequestID = try JSONSerialization.jsonObject(with: Data(claude(12).utf8)) as! [String: Any]
        noRequestID.removeValue(forKey: "requestId")
        let lines = [Data(claude(2).utf8), Data(claude(12).utf8), Data(claude(12).utf8),
                     try JSONSerialization.data(withJSONObject: noRequestID)]
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: line))
            parser.consume(line)
        }
        let result = parser.result(timeZone: zone, since: start, through: end)
        XCTAssertEqual(result.buckets.first?.tokens, TokenUsageCounts(nonCachedInput: 100, cacheRead: 200, cacheWrite: 30, output: 12))
        XCTAssertFalse(result.incomplete)
    }
    func testCodexCumulativeDuplicatesCacheAndReasoningAreNotAddedTwice() {
        var parser = TokenUsageLogAccumulator(agent: .codex)
        let lines = [meta, codex(input: 100, cache: 80, output: 20), codex(input: 100, cache: 80, output: 20, second: 2), codex(input: 150, cache: 100, output: 40, second: 3)]
        for _ in 0..<2 {
            parser.beginFile() // copied/re-scanned session file
            for line in lines { parser.consume(Data(line.utf8)) }
        }
        let result = parser.result(timeZone: zone, since: start, through: end)
        XCTAssertEqual(result.buckets.first?.tokens, TokenUsageCounts(nonCachedInput: 50, cacheRead: 100, output: 40))
        XCTAssertEqual(result.buckets.first?.tokens.total, 190)
        XCTAssertFalse(result.incomplete)
    }
    func testCodexRestampedCopiesAndOverlappingResumeReconcileGlobally() {
        var parser = TokenUsageLogAccumulator(agent: .codex)
        for line in [meta, codex(input: 100, cache: 80, output: 20), codex(input: 150, cache: 100, output: 40, second: 2)] {
            parser.consume(Data(line.utf8))
        }
        parser.beginFile()
        for line in [meta, codex(input: 100, cache: 80, output: 20, second: 3), codex(input: 150, cache: 100, output: 40, second: 4), codex(input: 180, cache: 110, output: 60, second: 5)] {
            parser.consume(Data(line.utf8))
        }
        let result = parser.result(timeZone: zone, since: start, through: end)
        XCTAssertEqual(result.buckets.first?.tokens.total, 240)
        XCTAssertEqual(result.buckets.first?.tokens.nonCachedInput, 70)
    }
    func testCodexResetAndForkDoNotInventWork() {
        var parser = TokenUsageLogAccumulator(agent: .codex)
        for line in [meta, codex(input: 100, cache: 80, output: 20), codex(input: 20, cache: 10, output: 10, second: 2), codex(input: 40, cache: 20, output: 20, second: 3)] {
            parser.consume(Data(line.utf8))
        }
        let result = parser.result(timeZone: zone, since: start, through: end)
        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(result.buckets.first?.tokens.total, 120)
        var fork = TokenUsageLogAccumulator(agent: .codex)
        let forkMeta = #"{"type":"session_meta","payload":{"id":"fork","forked_from_id":"parent","timestamp":"2026-10-01T02:00:02Z"}}"#
        for line in [forkMeta, meta, codex(input: 100, cache: 80, output: 20, second: 3), codex(input: 150, cache: 100, output: 40, second: 4)] { fork.consume(Data(line.utf8)) }
        let forkResult = fork.result(timeZone: zone, since: start, through: end)
        XCTAssertTrue(forkResult.buckets.isEmpty)
        XCTAssertTrue(forkResult.incomplete)
    }
    func testMalformedAndUnknownUsageNeverBecomesZero() {
        var parser = TokenUsageLogAccumulator(agent: .claudeCode)
        parser.consume(Data(#"{"type":"assistant","message":{"id":"x","usage":{"input_tokens":true,"output_tokens":3}}}"#.utf8))
        parser.consume(Data("{truncated".utf8))
        XCTAssertTrue(parser.incomplete)
        XCTAssertEqual(parser.recognizedEvents, 0)
        XCTAssertTrue(parser.result(timeZone: zone, since: start, through: end).buckets.isEmpty)
    }
    func testSyntheticFilesystemScanIsReplacementBoundedAndPrivate() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try (claude(12) + "\n").write(to: root.appendingPathComponent("usage.jsonl"), atomically: true, encoding: .utf8)
        let roots = TokenUsageLogRoots(claude: [root], codex: [root.appendingPathComponent("missing")])
        let one = try TokenUsageScanner.scan(roots: roots, timeZone: zone, now: end, deviceID: "test", epoch: "test", sequence: 1)
        let two = try TokenUsageScanner.scan(roots: roots, timeZone: zone, now: end, deviceID: "test", epoch: "test", sequence: 2)
        XCTAssertEqual(one.buckets, two.buckets)
        XCTAssertEqual(one.sources.first(where: { $0.agent == .claudeCode })?.status, .available)
        XCTAssertEqual(one.buckets.first?.tokens.total, 342)
        XCTAssertEqual(one.sources.first(where: { $0.agent == .codex })?.status, .unavailable)
        let encoded = String(decoding: try TokenUsageSnapshotCodec.encode(two), as: UTF8.self)
        for forbidden in ["PRIVATE CONTENT", "test-request", "synthetic-message", root.path, "accountId", "project"] {
            XCTAssertFalse(encoded.contains(forbidden))
        }
    }

    func testConfiguredRootAliasIsReadableButDescendantLinksCannotEscape() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("logs"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try (claude(12) + "\n").write(to: real.appendingPathComponent("usage.jsonl"), atomically: true, encoding: .utf8)
        try (claude(9999, id: "excluded") + "\n").write(to: outside.appendingPathComponent("external.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("linked.jsonl"), withDestinationURL: outside.appendingPathComponent("external.jsonl"))
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("linked-directory"), withDestinationURL: outside)
        let alias = base.appendingPathComponent("configured-home")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        for paths in [[alias], [alias, real]] {
            let snapshot = try TokenUsageScanner.scan(roots: TokenUsageLogRoots(claude: paths, codex: []),
                timeZone: zone, now: end, deviceID: "test", epoch: "test", sequence: 1)
            XCTAssertEqual(snapshot.buckets.first?.tokens.total, 342)
            XCTAssertEqual(snapshot.sources.first(where: { $0.agent == .claudeCode })?.status, .available)
            XCTAssertFalse(String(decoding: try TokenUsageSnapshotCodec.encode(snapshot), as: UTF8.self).contains(base.path))
        }
    }

    func testReadBudgetPrioritizesRecentLogsAcrossRootsAndReportsPartial() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let oldRoot = base.appendingPathComponent("old"), recentRoot = base.appendingPathComponent("recent")
        for root in [oldRoot, recentRoot] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let old = oldRoot.appendingPathComponent("a-old.jsonl"), recent = recentRoot.appendingPathComponent("z-recent.jsonl")
        let oldData = Data((claude(50, id: "old-message") + "\n").utf8)
        let newData = Data((claude(12) + "\n").utf8)
        try oldData.write(to: old); try newData.write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: end], ofItemAtPath: recent.path)
        let snapshot = try TokenUsageScanner.scan(roots: TokenUsageLogRoots(claude: [oldRoot, recentRoot], codex: []),
            timeZone: zone, now: end, deviceID: "test", epoch: "test", sequence: 1, byteLimit: newData.count)
        XCTAssertEqual(snapshot.buckets.first?.tokens.total, 342)
        XCTAssertEqual(snapshot.sources.first(where: { $0.agent == .claudeCode })?.status, .partial)
        XCTAssertEqual(snapshot.sources.first(where: { $0.agent == .claudeCode })?.diagnostic, "incomplete_scan")
    }
}
