import XCTest
import QuotaCore
import QuotaStore
import CryptoKit
import CloudKit
@testable import QuotaSync

final class ICloudAndMCPTests: XCTestCase {
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

    func testMissingRecordHandlesDirectAndPerItemErrorsOnly() {
        let id = CKRecord.ID(recordName: "latest-quota-v1")
        let missing = CKError(.unknownItem)
        XCTAssertEqual(ICloudRecordFailure.code(missing, recordID: id), .unknownItem)
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: missing]])
        XCTAssertEqual(ICloudRecordFailure.code(partial, recordID: id), .unknownItem)
        XCTAssertNil(ICloudRecordFailure.code(partial, recordID: CKRecord.ID(recordName: "other")))
        let denied = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.permissionFailure)]])
        XCTAssertEqual(ICloudRecordFailure.code(denied, recordID: id), .permissionFailure)
        XCTAssertNil(ICloudRecordFailure.code(CKError(.partialFailure), recordID: id))
    }

    func testCloudFeedbackDoesNotMislabelNetworkOrLeakServerDetails() {
        let network = CKError(.networkFailure, userInfo: [NSLocalizedDescriptionKey: "private-server-detail"])
        XCTAssertTrue(ICloudSyncFeedback.message(for: network).text.contains("网络"))
        XCTAssertFalse(ICloudSyncFeedback.message(for: network).text.contains("权限"))
        XCTAssertFalse(ICloudSyncFeedback.message(for: network).text.contains("private-server-detail"))
        XCTAssertTrue(ICloudSyncFeedback.message(for: CKError(.missingEntitlement)).text.contains("版本"))
        XCTAssertTrue(ICloudSyncFeedback.message(for: CKError(.permissionFailure)).text.contains("权限"))
        XCTAssertTrue(ICloudSyncFeedback.message(for: CKError(.serverRejectedRequest)).text.contains("服务"))
        XCTAssertFalse(ICloudSyncFeedback.message(for: CKError(.serverRejectedRequest)).text.contains("权限"))
    }

    private func snapshot(sequence: Int64 = 1, time: TimeInterval = 1788572460, epoch: String = "epoch") throws -> Snapshot {
        try Snapshot.make(windows: [], deviceID: "mac", epoch: epoch, sequence: sequence, capturedAt: Date(timeIntervalSince1970: time))
    }
    func testDualSyncChoosesWholeNewestObservationAndRejectsSequenceRollback() throws {
        let older = try snapshot(sequence: 4), newer = try snapshot(sequence: 5, time: 1788572461)
        XCTAssertEqual(SyncSnapshotSelection.newest([newer, older])?.sourceSequence, 5)
        XCTAssertFalse(SyncSnapshotSelection.accepts(older, after: newer))
        XCTAssertTrue(SyncSnapshotSelection.accepts(newer, after: older))
        XCTAssertNil(SyncSnapshotSelection.newest([]))
        let tied = try snapshot(sequence: 1, epoch: "other-source")
        XCTAssertEqual(SyncSnapshotSelection.newest([older, tied])?.sourceEpoch, "epoch")
        let rotated = try snapshot(sequence: 1, time: 1788572462, epoch: "next")
        XCTAssertTrue(SyncSnapshotSelection.accepts(rotated, after: newer))
        XCTAssertEqual(SyncSnapshotSelection.newest([newer, rotated])?.sourceEpoch, "next")
    }
    func testICloudCacheEncryptsAndRejectsTampering() throws {
        final class Vault: SecretStoring, @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String: Data] = [:]
            func load(_ account: String) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let d = values[account] else { throw VaultError.unavailable }; return d }
            func save(_ data: Data, account: String) { lock.lock(); defer { lock.unlock() }; values[account] = data }
            func remove(_ account: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
        }
        let directory = URL(fileURLWithPath: "/tmp/qi-icloud-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ICloudSnapshotCache(directory: directory, vault: Vault())
        try cache.save(snapshot(sequence: 7), accountID: "apple-account-a")
        XCTAssertEqual(try cache.load(accountID: "apple-account-a").sourceSequence, 7)
        XCTAssertThrowsError(try cache.load(accountID: "apple-account-b"))
        let file = directory.appendingPathComponent("icloud-snapshot.enc")
        var bytes = try Data(contentsOf: file)
        XCTAssertNil(String(data: bytes, encoding: .utf8))
        bytes[20] ^= 1
        try PrivateFile.write(bytes, to: file)
        XCTAssertThrowsError(try cache.load(accountID: "apple-account-a"))
        try cache.clear()
        XCTAssertThrowsError(try cache.load(accountID: "apple-account-a"))
    }
    func testRemoteProjectionExcludesIdentityAndHistory() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let snapshot = try SnapshotCodec.decode(Data(contentsOf: root.appendingPathComponent("contracts/fixtures/01-fresh.json")))
        let data = try RemoteMCPProjection.encode(snapshot, sourceEpoch: "server-epoch")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, snapshot.windows.count)
        for (index, window) in windows.enumerated() {
            XCTAssertNil(window["accountAlias"]); XCTAssertNil(window["accountId"]); XCTAssertNil(window["history"])
            XCTAssertNotEqual(window["id"] as? String, snapshot.windows[index].id)
            XCTAssertEqual(window["providerId"] as? String, snapshot.windows[index].providerId)
        }
        XCTAssertNil(object["sourceDeviceId"])
    }
    func testMCPHasNoNetworkBeforeConsentAndAfterDisable() async throws {
        actor Recorder {
            var paths: [String] = []
            func receive(_ request: URLRequest) -> (Data, HTTPURLResponse) {
                paths.append(request.httpMethod! + " " + request.url!.path)
                return (Data(#"{"accepted":true}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let recorder = Recorder(), endpoint = URL(string: "https://quota.example.invalid")!
        let transport = try SyncTransport(baseURL: endpoint) { await recorder.receive($0) }
        let credentials = WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "mac", epoch: "epoch", token: "synthetic", keyID: "key", signingPrivateKey: Data(), snapshotKey: Data())
        let client = try RemoteMCPClient(credentials: credentials, transport: transport)
        try await client.upload(snapshot())
        var paths = await recorder.paths; XCTAssertTrue(paths.isEmpty)
        try await client.enable(token: String(repeating: "x", count: 43))
        try await client.upload(snapshot())
        try await client.disable()
        try await client.upload(snapshot())
        paths = await recorder.paths
        XCTAssertEqual(paths, ["PUT /v1/mcp-access", "PUT /v1/mcp-snapshot", "DELETE /v1/mcp-access"])
    }
    func testMCPRejectsFalseAcknowledgementAndKeepsUploadsDisabled() async throws {
        actor Recorder {
            var count = 0
            func receive(_ request: URLRequest) -> (Data, HTTPURLResponse) {
                count += 1
                return (Data(#"{"accepted":false}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let recorder = Recorder(), endpoint = URL(string: "https://quota.example.invalid")!
        let transport = try SyncTransport(baseURL: endpoint) { await recorder.receive($0) }
        let credentials = WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "mac", epoch: "epoch", token: "synthetic", keyID: "key", signingPrivateKey: Data(), snapshotKey: Data())
        let client = try RemoteMCPClient(credentials: credentials, transport: transport)
        do { try await client.enable(token: String(repeating: "x", count: 43)); XCTFail("false receipt accepted") } catch {}
        try await client.upload(snapshot())
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }
    func testMCPRevocationCanRunWithoutLocalConsentAndRequiresAcknowledgement() async throws {
        actor Recorder {
            var methods: [String] = []
            func receive(_ request: URLRequest) -> (Data, HTTPURLResponse) {
                methods.append((request.httpMethod ?? "") + " " + (request.url?.path ?? ""))
                return (Data(#"{"accepted":false}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let recorder = Recorder(), endpoint = URL(string: "https://quota.example.invalid")!
        let transport = try SyncTransport(baseURL: endpoint) { await recorder.receive($0) }
        let credentials = WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "mac", epoch: "epoch", token: "synthetic", keyID: "key", signingPrivateKey: Data(), snapshotKey: Data())
        let client = try RemoteMCPClient(credentials: credentials, transport: transport)
        do { try await client.disable(); XCTFail("false revocation receipt accepted") } catch SyncError.configuration {}
        let methods = await recorder.methods
        XCTAssertEqual(methods, ["DELETE /v1/mcp-access"])
    }
    func testMCPDisableDrainsInFlightEnableAndCannotResurrectConsent() async throws {
        actor Recorder {
            var paths: [String] = []
            var startedWaiter: CheckedContinuation<Void, Never>?
            func waitForPUT() async {
                if !paths.isEmpty { return }
                await withCheckedContinuation { startedWaiter = $0 }
            }
            func receive(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                paths.append(request.httpMethod!)
                if request.httpMethod == "PUT" {
                    startedWaiter?.resume(); startedWaiter = nil
                    try await Task.sleep(for: .milliseconds(100))
                }
                return (Data(#"{"accepted":true}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let recorder = Recorder(), endpoint = URL(string: "https://quota.example.invalid")!
        let transport = try SyncTransport(baseURL: endpoint) { try await recorder.receive($0) }
        let credentials = WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "mac", epoch: "epoch", token: "synthetic", keyID: "key", signingPrivateKey: Data(), snapshotKey: Data())
        let client = try RemoteMCPClient(credentials: credentials, transport: transport)
        let enabling = Task { try await client.enable(token: String(repeating: "x", count: 43)) }
        await recorder.waitForPUT()
        try await client.disable()
        do { try await enabling.value; XCTFail("superseded enable accepted") } catch is CancellationError {} catch { XCTFail("unexpected error") }
        try await client.upload(snapshot())
        let paths = await recorder.paths
        XCTAssertEqual(paths, ["PUT", "DELETE"])
    }

    func testCFWriterExplicitlyDisabledDoesNotSendSnapshot() async throws {
        let endpoint = URL(string: "https://quota.example.invalid")!
        let transport = try SyncTransport(baseURL: endpoint) { _ in XCTFail("disabled sync sent request"); throw SyncError.unavailable }
        let directory = URL(fileURLWithPath: "/tmp/qi-disabled-writer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "mac", epoch: "epoch", token: "synthetic", keyID: "key", signingPrivateKey: Data(), snapshotKey: Data())
        let writer = try SyncWriter(credentials: credentials, directory: directory, transport: transport)
        await writer.setSyncEnabled(false)
        do { try await writer.upload(snapshot()); XCTFail("disabled upload accepted") } catch SyncError.unavailable {} catch { XCTFail("unexpected error") }
    }

}
