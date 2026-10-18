import Foundation
import XCTest
import QuotaCore
@testable import QuotaStore

final class StoreTests: XCTestCase {
    func fixture(_ sequence: Int64 = 42) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("contracts/fixtures/01-fresh.json"))) as! [String: Any]
        object["sourceSequence"] = sequence
        return try JSONSerialization.data(withJSONObject: object)
    }
    func testPublishSurvivesRestartAndRejectsCorruptReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        let input = try fixture()
        try await store.publish(input)
        do { try await store.publish(Data("{partial".utf8)); XCTFail("accepted corruption") } catch {}
        let read = try AtomicSnapshotReader(directory: directory).latest()
        XCTAssertEqual(read?.sourceSequence, 42)
        let reopened = try SnapshotStore(directory: directory)
        let latest = try await reopened.latest()
        XCTAssertEqual(latest?.sourceSequence, 42)
    }
    func testMonotonicAdmissionAndSameSequenceRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        try await store.publish(fixture(42))
        try await store.publish(fixture(42))
        do { try await store.publish(fixture(41)); XCTFail("accepted old sequence") } catch StoreError.conflict {}
        var changed = try JSONSerialization.jsonObject(with: fixture(42)) as! [String: Any]
        changed["snapshotId"] = "conflict"
        do { try await store.publish(JSONSerialization.data(withJSONObject: changed)); XCTFail("accepted conflict") } catch StoreError.conflict {}
        try await store.publish(fixture(43))
        XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.sourceSequence, 43)
    }
    func testInterruptedProjectionRecoversAndFilePermissionsArePrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        try await store.publish(fixture())
        let output = directory.appendingPathComponent("latest-public.json")
        try Data("half-json".utf8).write(to: output)
        XCTAssertThrowsError(try AtomicSnapshotReader(directory: directory).latest())
        _ = try SnapshotStore(directory: directory)
        XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.sourceSequence, 42)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: output.path)
        XCTAssertThrowsError(try AtomicSnapshotReader(directory: directory).latest())
    }
    func testOnlyOneCollectorLeaseAndReadersDoNotAcquireIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try CollectorLease(directory: directory)
        try withExtendedLifetime(lease) {
            XCTAssertThrowsError(try CollectorLease(directory: directory))
            XCTAssertNil(try AtomicSnapshotReader(directory: directory).latest())
        }
    }
    func testConcurrentStoresNeverRegressPublicSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try SnapshotStore(directory: directory), b = try SnapshotStore(directory: directory)
        let first = try fixture(42), second = try fixture(43)
        async let x: Void = a.publish(first)
        async let y: Void = b.publish(second)
        // If 43 commits first, 42 must conflict. Await 43 independently:
        // a tuple await can short-circuit on that expected conflict while 43
        // is still projecting the committed row to latest-public.json.
        do { try await x }
        catch StoreError.conflict { }
        catch { throw error }
        try await y
        XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.sourceSequence, 43)
    }
    func testOrphanedPublicSnapshotIsNotSilentlyAdopted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try fixture()
        try PrivateFile.write(data, to: directory.appendingPathComponent("latest-public.json"))
        XCTAssertThrowsError(try SnapshotStore(directory: directory))
        XCTAssertEqual(try PrivateFile.read(directory.appendingPathComponent("latest-public.json"), maxBytes: SnapshotCodec.maxBytes), data)
    }

    func testCorrectionHistoryAndSevenDayRawNinetyDayAggregateRetention() async throws {
        let directory = URL(fileURLWithPath: "/tmp/qi-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        try await store.publish(fixture(42))
        var object = try JSONSerialization.jsonObject(with: fixture(43)) as! [String: Any]
        var windows = object["windows"] as! [[String: Any]]
        windows[0]["remainingBps"] = 5000; object["windows"] = windows
        let corrected = try JSONSerialization.data(withJSONObject: object)
        try await store.publish(corrected)
        let snapshot = try SnapshotCodec.decode(corrected)
        let points = try await store.history(for: snapshot.windows[0], since: .distantPast)
        XCTAssertEqual(points.count, 1); XCTAssertEqual(points[0].remainingBps, 5000)
        let captured = QuotaRules.date(snapshot.capturedAt)!
        object["capturedAt"] = ISO8601DateFormatter().string(from: captured.addingTimeInterval(8 * 86400)); object["sourceSequence"] = 44
        try await store.publish(JSONSerialization.data(withJSONObject: object))
        var counts = try await store.historyCounts()
        XCTAssertEqual(counts.observations, 0); XCTAssertGreaterThan(counts.hours, 0)
        object["capturedAt"] = ISO8601DateFormatter().string(from: captured.addingTimeInterval(91 * 86400)); object["sourceSequence"] = 45
        try await store.publish(JSONSerialization.data(withJSONObject: object))
        counts = try await store.historyCounts()
        XCTAssertEqual(counts.observations, 0); XCTAssertEqual(counts.hours, 0)
    }

}
