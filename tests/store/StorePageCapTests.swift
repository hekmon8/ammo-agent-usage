import Foundation
import XCTest
import CSQLite
import QuotaCore
import QuotaStore

final class StorePageCapTests: XCTestCase {
    func testPruningAnOldHourPreservesTheNextHoursCrossHourGap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        let now = Date()
        let first = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600 - 7 * 86400 - 3600)
        let second = first.addingTimeInterval(5400)
        func snapshot(_ sequence: Int64, observedAt: Date, capturedAt: Date) throws -> Snapshot {
            let window = QuotaWindow.reported(
                id: "zcode-gap", providerID: "zcode", accountID: "native-test", alias: "ZCode",
                key: "rate-limit-reset-credits", remainingBps: 5000,
                observedAt: observedAt, staleAt: observedAt.addingTimeInterval(600),
                duration: nil, resetsAt: nil, source: .officialAPI)
            return try Snapshot.make(windows: [window], deviceID: "test-device", epoch: "test-epoch",
                                     sequence: sequence, capturedAt: capturedAt)
        }
        let initialCapture = now.addingTimeInterval(-86400)
        try await store.publish(SnapshotCodec.encode(try snapshot(1, observedAt: first, capturedAt: initialCapture)))
        try await store.publish(SnapshotCodec.encode(try snapshot(2, observedAt: second, capturedAt: initialCapture.addingTimeInterval(1))))
        let hour = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: floor(second.timeIntervalSince1970 / 3600) * 3600))
        let before = try hourlyGap(directory: directory, hour: hour)
        XCTAssertGreaterThan(before, 5399)
        try await store.publish(SnapshotCodec.encode(try snapshot(3, observedAt: second, capturedAt: now)))
        let after = try hourlyGap(directory: directory, hour: hour)
        XCTAssertGreaterThanOrEqual(after, before - 0.01)
    }

    func testPublishTrimsFineHistoryWhenDatabaseReachesPageCap() async throws {
        try await runAtPageCap(retainHistory: true)
    }

    func testPublishWithoutHistoryReleasesPagesBeforeWriting() async throws {
        try await runAtPageCap(retainHistory: false)
    }

    func testHourlyCapTrimCannotBeRepopulatedByAnOldSample() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        let now = Date()
        let old = Date(timeIntervalSince1970:
            floor(now.addingTimeInterval(-8 * 86400).timeIntervalSince1970 / 3600) * 3600 + 120)
        let oldHour = ISO8601DateFormatter().string(from:
            Date(timeIntervalSince1970: floor(old.timeIntervalSince1970 / 3600) * 3600))
        func publish(_ sequence: Int64, observedAt: Date, capturedAt: Date) async throws {
            let window = QuotaWindow.reported(
                id: "zcode-hourly", providerID: "zcode", accountID: "native-test", alias: "ZCode",
                key: "rate-limit-reset-credits", remainingBps: 5000,
                observedAt: observedAt, staleAt: observedAt.addingTimeInterval(600),
                duration: nil, resetsAt: nil, source: .officialAPI)
            let snapshot = try Snapshot.make(windows: [window], deviceID: "test-device", epoch: "test-epoch",
                                             sequence: sequence, capturedAt: capturedAt)
            try await store.publish(SnapshotCodec.encode(snapshot))
        }
        try await publish(1, observedAt: now, capturedAt: now)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent("quota.sqlite").path,
                                       &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        let sql = """
        INSERT INTO hourly_observations VALUES('zcode/native-test/rate-limit-reset-credits',
        '\(oldHour)','unknown',zeroblob(46*1024*1024),'\(oldHour)',NULL,NULL,NULL,NULL,1,0)
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        try await publish(2, observedAt: now.addingTimeInterval(1), capturedAt: now.addingTimeInterval(1))
        XCTAssertEqual(try hourlyBucketCount(directory: directory, hour: oldHour), 0)

        let reopened = try SnapshotStore(directory: directory)
        let lateWindow = QuotaWindow.reported(
            id: "zcode-hourly", providerID: "zcode", accountID: "native-test", alias: "ZCode",
            key: "rate-limit-reset-credits", remainingBps: 5000,
            observedAt: old.addingTimeInterval(60), staleAt: old.addingTimeInterval(660),
            duration: nil, resetsAt: nil, source: .officialAPI)
        let late = try Snapshot.make(windows: [lateWindow], deviceID: "test-device", epoch: "test-epoch",
                                     sequence: 3, capturedAt: now.addingTimeInterval(2))
        try await reopened.publish(SnapshotCodec.encode(late))
        XCTAssertEqual(try hourlyBucketCount(directory: directory, hour: oldHour), 0)
        let latest = try await store.latest()
        XCTAssertEqual(latest?.sourceSequence, 3)
    }

    func testFirstSeenOldObservationGetsHourlyRollupWithoutFineHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        let now = Date()
        let observed = Date(timeIntervalSince1970:
            floor(now.addingTimeInterval(-8 * 86400).timeIntervalSince1970 / 3600) * 3600 + 120)
        let window = QuotaWindow.reported(
            id: "zcode-old", providerID: "zcode", accountID: "native-test", alias: "ZCode",
            key: "rate-limit-reset-credits", remainingBps: 5000,
            observedAt: observed, staleAt: observed.addingTimeInterval(600),
            duration: nil, resetsAt: nil, source: .officialAPI)
        let snapshot = try Snapshot.make(windows: [window], deviceID: "test-device", epoch: "test-epoch",
                                         sequence: 1, capturedAt: now)
        try await store.publish(SnapshotCodec.encode(snapshot))
        let counts = try await store.historyCounts()
        XCTAssertEqual(counts.observations, 0)
        XCTAssertEqual(counts.hours, 1)
        let oldHour = ISO8601DateFormatter().string(from:
            Date(timeIntervalSince1970: floor(observed.timeIntervalSince1970 / 3600) * 3600))
        let secondObserved = observed.addingTimeInterval(60)
        let secondWindow = QuotaWindow.reported(
            id: "zcode-old", providerID: "zcode", accountID: "native-test", alias: "ZCode",
            key: "rate-limit-reset-credits", remainingBps: 1000,
            observedAt: secondObserved, staleAt: secondObserved.addingTimeInterval(600),
            duration: nil, resetsAt: nil, source: .officialAPI)
        let second = try Snapshot.make(windows: [secondWindow], deviceID: "test-device", epoch: "test-epoch",
                                       sequence: 2, capturedAt: now.addingTimeInterval(1))
        try await store.publish(SnapshotCodec.encode(second))
        // The first committed historical rollup is authoritative after its
        // fine samples have expired; late samples do not inflate its count.
        XCTAssertEqual(try hourlyBucketCount(directory: directory, hour: oldHour), 1)
    }

    private func runAtPageCap(retainHistory: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(directory: directory)
        let now = Date()
        func snapshot(sequence: Int64, observedAt: Date, capturedAt: Date? = nil) throws -> Snapshot {
            let window = QuotaWindow.providerValue(
                id: "zcode-test-reset", providerID: "zcode", accountID: "native-test",
                alias: "ZCode", key: "rate-limit-reset-credits", unit: .requests,
                currency: nil, remainingBps: nil, amount: "1", limit: nil,
                quality: .reported, source: .officialAPI, observedAt: observedAt,
                staleAt: observedAt.addingTimeInterval(600), windowKind: .unknown,
                duration: nil, resetsAt: nil)
            return try Snapshot.make(windows: [window], deviceID: "test-device", epoch: "test-epoch",
                                     sequence: sequence, capturedAt: capturedAt ?? observedAt)
        }
        try await store.publish(SnapshotCodec.encode(try snapshot(sequence: 1, observedAt: now)))

        // Fill the database with a recent fine observation. It is too new for
        // normal seven-day expiry, so publishing must release it under the cap.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent("quota.sqlite").path,
                                       &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO observations VALUES(?,?,?,?,?)", -1,
                                          &statement, nil), SQLITE_OK)
        let insert = try XCTUnwrap(statement)
        sqlite3_bind_text(insert, 1, "old-fine-history", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(insert, 2, ISO8601DateFormatter().string(from: now.addingTimeInterval(-6 * 86400)),
                          -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(insert, 3, "unknown", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_zeroblob(insert, 4, 46 * 1024 * 1024)
        sqlite3_bind_int64(insert, 5, 0)
        XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE)
        sqlite3_finalize(insert)

        let next = try snapshot(sequence: 2, observedAt: now.addingTimeInterval(1))
        try await store.publish(SnapshotCodec.encode(next), retainHistory: retainHistory)
        let latest = try await store.latest()
        let counts = try await store.historyCounts()
        XCTAssertEqual(latest?.sourceSequence, 2)
        XCTAssertEqual(latest?.windows.first?.amount, "1")
        if retainHistory { XCTAssertLessThan(counts.observations, 3) }
        else { XCTAssertEqual(counts.observations, 0) }
        XCTAssertEqual(counts.hours > 0, retainHistory)
        XCTAssertEqual(try AtomicSnapshotReader(directory: directory).latest()?.sourceSequence, 2)
        if retainHistory {
            // The trim boundary survives reopening; replaying an older sample
            // must not recreate the deleted fine hour.
            let reopened = try SnapshotStore(directory: directory)
            let oldSample = try snapshot(sequence: 3, observedAt: now.addingTimeInterval(-6 * 86400),
                                         capturedAt: now.addingTimeInterval(2))
            try await reopened.publish(SnapshotCodec.encode(oldSample))
            let reopenedCounts = try await reopened.historyCounts()
            XCTAssertEqual(reopenedCounts.observations, counts.observations)
        }
    }

    private func hourlyGap(directory: URL, hour: String) throws -> Double {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent("quota.sqlite").path,
                                       &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db,
            "SELECT max_gap_seconds FROM hourly_observations WHERE identity=? AND hour=?", -1,
            &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, "zcode/native-test/rate-limit-reset-credits", -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(query, 2, hour, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        return sqlite3_column_double(query, 0)
    }

    private func hourlyBucketCount(directory: URL, hour: String) throws -> Int {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent("quota.sqlite").path,
                                       &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM hourly_observations WHERE hour=?", -1,
                                          &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, hour, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        return Int(sqlite3_column_int(query, 0))
    }
}
