import Foundation
import XCTest
import Darwin
import CryptoKit
import QuotaCore
@testable import QuotaProviders

final class ProviderTests: XCTestCase {
    // Localized model strings resolve through L10n; pin the language so the
    // zh-Hans literals below assert table contents deterministically.
    override func setUp() {
        super.setUp()
        L10n.setLanguage(.simplifiedChinese)
    }

    override func tearDown() {
        L10n.resetLanguage()
        super.tearDown()
    }

    func testNativeDiscoveryAndExecutableVerification() throws {
        let paths = CodexAppDiscovery.bundledCandidates(home: URL(fileURLWithPath: "/test-home"), applications: URL(fileURLWithPath: "/Apps"))
        XCTAssertEqual(paths.first?.path, "/test-home/Applications/ChatGPT.app/Contents/Resources/codex")
        XCTAssertEqual(paths.last?.path, "/Apps/Codex.app/Contents/Resources/codex")
        let path = try script("#!/usr/bin/env node\n")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        XCTAssertFalse(CodexAppDiscovery.isNativeMachO(path))
        XCTAssertTrue(CodexAppDiscovery.isNativeMachO(URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertFalse(CodexAppDiscovery.isOpenAISigned(URL(fileURLWithPath: "/usr/bin/true")))
    }
    func testObservedMultiBucketShapeWithNullLegacy() throws {
        let data = Data(#"{"rateLimits":null,"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":43,"windowDurationMins":10080}},"codex_bengalfox":{"primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"usedPercent":100,"windowDurationMins":10080}}}}"#.utf8)
        let windows = try CodexNormalizer.normalize(data, accountID: "synthetic", alias: "Codex", now: Date())
        XCTAssertEqual(windows.map(\.remainingBps), [5700, 10000, 0])
        XCTAssertEqual(windows.map(\.window.durationSeconds), [604800, 18000, 604800])
        XCTAssertTrue(windows.allSatisfy { $0.amount == nil && $0.limit == nil })
    }
    func testMissingSecondaryAndMapDoesNotDoubleCountLegacy() throws {
        let legacy = Data(#"{"rateLimits":{"primary":{"usedPercent":32,"windowDurationMins":300}}}"#.utf8)
        let windows = try CodexNormalizer.normalize(legacy, accountID: "local_account", alias: "Test", now: Date())
        XCTAssertEqual(windows.count, 1); XCTAssertEqual(windows[0].remainingBps, 6800)
        XCTAssertNil(windows[0].amount); XCTAssertNil(windows[0].window.resetsAt)
        let multi = Data(#"{"rateLimits":{"primary":{"usedPercent":32}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":10},"secondary":{"usedPercent":70}}}}"#.utf8)
        let buckets = try CodexNormalizer.normalize(multi, accountID: "local_account", alias: "Test", now: Date())
        XCTAssertEqual(buckets.map(\.remainingBps), [9000, 3000])
        XCTAssertThrowsError(try CodexNormalizer.normalize(Data(#"{"rateLimits":{"primary":{"usedPercent":101}}}"#.utf8), accountID: "test", alias: "Test", now: Date()))
    }
    func testCodexCreditsAndResetCountSurviveSnapshotRoundTrip() throws {
        // Codex CLI 0.153.2 generated GetAccountRateLimitsResponse contract.
        let data = Data(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":32},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"}},"spark":{"primary":{"usedPercent":10},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"}}},"rateLimitResetCredits":{"availableCount":4,"credits":[]}}"#.utf8)
        let now = Date()
        let windows = try CodexNormalizer.normalize(data, accountID: "test", alias: "Test", now: now)
        XCTAssertEqual(windows.count, 4)
        let snapshot = try Snapshot.make(windows: windows, deviceID: "test", epoch: "test", sequence: 1, capturedAt: now)
        let decoded = try SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        let balance = try XCTUnwrap(decoded.windows.first { $0.quotaKey == "credit-balance" })
        XCTAssertEqual(balance.amount, "12.50")
        XCTAssertNil(balance.remainingBps)
        XCTAssertEqual(balance.shortDisplayName, "Credit 余额")
        let resets = try XCTUnwrap(decoded.windows.first { $0.quotaKey == "rate-limit-reset-credits" })
        XCTAssertEqual(QuotaPresentation(window: resets, now: now).number, "4 次")
        XCTAssertEqual(resets.shortDisplayName, "可用重置次数")
        XCTAssertEqual(resets.amount, "4", "Inventory length is not the authoritative count")
    }

    func testCodexCreditZeroMissingUnlimitedAndInvalidValues() throws {
        func normalize(_ payload: String) throws -> [QuotaWindow] {
            try CodexNormalizer.normalize(Data(payload.utf8), accountID: "test", alias: "Test", now: Date())
        }
        let zero = try normalize(#"{"rateLimits":{"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}},"rateLimitResetCredits":{"availableCount":0}}"#)
        XCTAssertEqual(zero.map(\.amount), ["0", "0"])
        XCTAssertEqual(QuotaPresentation(window: zero[0], now: Date()).state, .exhausted)
        let unknown = try normalize(#"{"rateLimits":{"primary":{"usedPercent":0},"credits":{"hasCredits":false,"unlimited":false,"balance":null}}}"#)
        XCTAssertEqual(unknown.count, 1)
        let unlimited = try normalize(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":true,"balance":null}}}"#)
        XCTAssertEqual(unlimited[0].availability, .unlimited)
        XCTAssertNil(unlimited[0].amount)
        for value in ["-1", "NaN", "1e3", "12 dollars", "01", "0.1234567890123", String(repeating: "9", count: 49)] {
            XCTAssertThrowsError(try normalize("{\"rateLimits\":{\"credits\":{\"hasCredits\":true,\"unlimited\":false,\"balance\":\"\(value)\"}}}"))
        }
        XCTAssertThrowsError(try normalize(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":-1}}"#))
    }

    func script(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("rpc.py")
        try body.write(to: path, atomically: true, encoding: .utf8)
        return path
    }
    func testBoundedHandshakeAndNotifications() async throws {
        let path = try script("""
        import json,sys
        initial=json.loads(sys.stdin.readline())
        assert initial['method']=='initialize'
        print(json.dumps({'id':0,'result':{}}),flush=True)
        assert json.loads(sys.stdin.readline())['method']=='initialized'
        read=json.loads(sys.stdin.readline())
        assert read['method']=='account/read'
        print(json.dumps({'id':2,'result':{'account':{'type':'chatgpt','email':'synthetic@example.invalid'}}}),flush=True)
        read=json.loads(sys.stdin.readline())
        assert read['method']=='account/rateLimits/read'
        print(json.dumps({'method':'notice','params':{}}),flush=True)
        print(json.dumps({'id':1,'result':{'rateLimits':{'primary':{'usedPercent':32}}}}),flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let data = try await BoundedRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 2)
        XCTAssertEqual(data.identityFingerprint, SHA256.hash(data: Data("chatgpt:synthetic@example.invalid\nunspecified".utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try CodexNormalizer.normalize(data.limits, accountID: "test", alias: "Test", now: Date()).first?.remainingBps, 6800)
    }
    func testNullableEmailRequiresStableIdentity() async throws {
        for hasID in [true, false] {
            let path = try script("""
            import json,sys
            json.loads(sys.stdin.readline())
            print(json.dumps({'id':0,'result':{}}),flush=True)
            json.loads(sys.stdin.readline()); json.loads(sys.stdin.readline())
            print(json.dumps({'id':2,'result':{'account':{'type':'chatgpt','email':None}}}),flush=True)
            json.loads(sys.stdin.readline())
            result={'rateLimits':{'primary':{'usedPercent':32}}}
            if \(hasID ? "True" : "False"): result['accountId']='synthetic-stable-account'
            print(json.dumps({'id':1,'result':result}),flush=True)
            """)
            defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
            do {
                let result = try await BoundedRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 2)
                XCTAssertTrue(hasID, "Missing identity must fail closed")
                XCTAssertEqual(result.identityFingerprint.count, 64)
            } catch ProviderFailure.authRequired { XCTAssertFalse(hasID) }
        }
    }
    func testTimeoutAndCancellationAreBounded() async throws {
        let path = try script("import time\ntime.sleep(30)\n")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let begin = Date()
        do { _ = try await BoundedRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 0.15); XCTFail("no timeout") }
        catch ProviderFailure.timeout {}
        XCTAssertLessThan(Date().timeIntervalSince(begin), 2)
        let task = Task { try await BoundedRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 15) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("no cancellation") } catch ProviderFailure.cancelled {}
        XCTAssertLessThan(Date().timeIntervalSince(begin), 3)
    }
    func testExcessOutputIsRejected() async throws {
        let path = try script("import sys,time\nsys.stdout.write('x'*300000)\nsys.stdout.flush()\ntime.sleep(30)\n")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        do { _ = try await BoundedRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 2); XCTFail("accepted oversized output") }
        catch ProviderFailure.outputLimit {}
    }
    func testEmptyMapUsesLegacyAndEmptyResponseDoesNotEraseWindows() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":32}},"rateLimitsByLimitId":{}}"#.utf8)
        XCTAssertEqual(try CodexNormalizer.normalize(data, accountID: "test", alias: "Test", now: Date()).first?.remainingBps, 6800)
        XCTAssertThrowsError(try CodexNormalizer.normalize(Data(#"{"rateLimits":{}}"#.utf8), accountID: "test", alias: "Test", now: Date()))
    }
    func testEarlyExitAndPartialOutputFailWithoutWaitingFullTimeout() async throws {
        let path = try script("print('{partial',flush=True)\n")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let start = Date()
        do { _ = try await BoundedRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 15); XCTFail("partial accepted") }
        catch ProviderFailure.parseChanged {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testUnsignedExecutablesCannotBeApprovedOrRestoredForLaunch() throws {
        // RPC protocol tests may spawn synthetic scripts directly. The saved
        // Codex connection path must still enforce native OpenAI signing.
        let scriptPath = try script("#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: scriptPath.deletingLastPathComponent()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath.path)
        XCTAssertThrowsError(try ApprovedExecutable(userSelectedURL: scriptPath))

        let fixture = try JSONSerialization.data(withJSONObject: [
            "path": scriptPath.absoluteString, "digest": "AA==",
        ])
        let restored = try JSONDecoder().decode(ApprovedExecutable.self, from: fixture)
        XCTAssertThrowsError(try restored.verifiedURL()) { XCTAssertEqual($0 as? ProviderFailure, .permissionDenied) }

        // Native Mach-O alone is insufficient: the enclosing OpenAI app
        // signature must be verified again for each persisted launch.
        let unsignedBinary = try JSONDecoder().decode(ApprovedExecutable.self,
            from: Data(#"{"path":"file:///usr/bin/true","digest":"AA=="}"#.utf8))
        XCTAssertThrowsError(try unsignedBinary.verifiedURL()) { XCTAssertEqual($0 as? ProviderFailure, .permissionDenied) }
    }

}
