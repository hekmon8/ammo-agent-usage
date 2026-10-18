import Foundation
import CSQLite
import QuotaCore
import Darwin

// Private to SnapshotStore actor. SQLite also serializes independent process writers.
private final class Connection: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw StoreError.invalidFile }
        } else {
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw StoreError.io(errno) }; close(fd)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw StoreError.database
        }
        handle = db
        sqlite3_busy_timeout(handle, 3000)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.database }
    }
    func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw StoreError.database }
        return stmt
    }
    func integer(_ sql: String) throws -> Int {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.database }
        return Int(sqlite3_column_int64(stmt, 0))
    }
    @discardableResult func deleteObservations(before cutoff: Date) throws -> Int {
        let stmt = try statement("DELETE FROM observations WHERE julianday(observed_at) < julianday(?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, ISO8601DateFormatter().string(from: cutoff), -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.database }
        return Int(sqlite3_changes(handle))
    }
    func oldestObservationHourEnd() throws -> Date? {
        let stmt = try statement("SELECT strftime('%Y-%m-%dT%H:00:00Z', min(julianday(observed_at)), '+1 hour') FROM observations")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.database }
        guard let text = sqlite3_column_text(stmt, 0) else {
            guard try integer("SELECT count(*) FROM observations") == 0 else { throw StoreError.database }
            return nil
        }
        guard let date = ISO8601DateFormatter().date(from: String(cString: text)) else { throw StoreError.database }
        return date
    }
    func oldestHourlyHourEnd() throws -> Date? {
        let stmt = try statement("SELECT min(hour) FROM hourly_observations")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.database }
        guard let value = sqlite3_column_text(stmt, 0) else { return nil }
        guard let date = ISO8601DateFormatter().date(from: String(cString: value)) else { throw StoreError.database }
        return date.addingTimeInterval(3600)
    }
    func deleteHourly(before cutoff: Date) throws {
        let stmt = try statement("DELETE FROM hourly_observations WHERE julianday(hour) < julianday(?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, ISO8601DateFormatter().string(from: cutoff), -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.database }
    }
    func storedRetentionFloors() throws -> (fine: Date, hourly: Date)? {
        // Older databases do not have retention state until a cap trim occurs.
        guard try integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='retention_state'") > 0 else { return nil }
        let stmt = try statement("SELECT fine_floor,hourly_floor FROM retention_state WHERE id=1")
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let fineValue = sqlite3_column_text(stmt, 0),
                  let hourlyValue = sqlite3_column_text(stmt, 1),
                  let fine = ISO8601DateFormatter().date(from: String(cString: fineValue)),
                  let hourly = ISO8601DateFormatter().date(from: String(cString: hourlyValue)) else { throw StoreError.database }
            return (fine, hourly)
        default: throw StoreError.database
        }
    }
    func saveRetentionFloors(fine: Date, hourly: Date) throws {
        try execute("CREATE TABLE IF NOT EXISTS retention_state(id INTEGER PRIMARY KEY CHECK(id=1), fine_floor TEXT NOT NULL, hourly_floor TEXT NOT NULL)")
        let stmt = try statement("INSERT INTO retention_state(id,fine_floor,hourly_floor) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET fine_floor=excluded.fine_floor,hourly_floor=excluded.hourly_floor")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, ISO8601DateFormatter().string(from: fine), -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, ISO8601DateFormatter().string(from: hourly), -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.database }
    }
    func insertHistoricalHourlyObservation(_ q: QuotaWindow, observedAt: String, date: Date) throws {
        let stmt = try statement("""
        INSERT OR IGNORE INTO hourly_observations
        (identity,hour,segment,first_at,last_at,first_bps,last_bps,min_bps,max_bps,sample_count,max_gap_seconds)
        VALUES(?,?,?,?,?,?,?,?,?,1,0)
        """)
        defer { sqlite3_finalize(stmt) }
        let hour = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3600) * 3600)
        let values = ["\(q.providerId)/\(q.accountId)/\(q.quotaKey)", ISO8601DateFormatter().string(from: hour),
                      q.window.periodId ?? "unknown", observedAt, observedAt]
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(index + 1), value, -1,
                                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw StoreError.database }
        }
        for index in 6...9 {
            if let bps = q.remainingBps { sqlite3_bind_int(stmt, Int32(index), Int32(bps)) }
            else { sqlite3_bind_null(stmt, Int32(index)) }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.database }
    }
    func latestData() throws -> Data? {
        let stmt = try statement("SELECT body FROM latest_snapshot WHERE id=1")
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_blob(stmt, 0) else { throw StoreError.database }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
        default: throw StoreError.database
        }
    }
}

public actor SnapshotStore {
    private let db: Connection
    public nonisolated let directory: URL
    public init(directory: URL) throws {
        try PrivateFile.prepareDirectory(directory)
        self.directory = directory
        let connection = try Connection(directory.appendingPathComponent("quota.sqlite"))
        let version = try connection.statement("PRAGMA user_version")
        let versionOK = sqlite3_step(version) == SQLITE_ROW && [0, 1].contains(sqlite3_column_int(version, 0))
        sqlite3_finalize(version)
        guard versionOK else { throw StoreError.conflict }
        try connection.execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA max_page_count=12800;")
        try connection.execute("""
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS latest_snapshot(id INTEGER PRIMARY KEY CHECK(id=1), body BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS observations(identity TEXT NOT NULL, observed_at TEXT NOT NULL, segment TEXT NOT NULL, bps INTEGER, source_sequence INTEGER NOT NULL, PRIMARY KEY(identity,observed_at,segment,source_sequence));
        CREATE TABLE IF NOT EXISTS hourly_observations(identity TEXT NOT NULL, hour TEXT NOT NULL, segment TEXT NOT NULL,
            first_at TEXT NOT NULL, last_at TEXT NOT NULL, first_bps INTEGER, last_bps INTEGER, min_bps INTEGER, max_bps INTEGER,
            sample_count INTEGER NOT NULL, max_gap_seconds REAL NOT NULL, PRIMARY KEY(identity,hour,segment));
        PRAGMA user_version=1;
        COMMIT;
        """)
        db = connection
        // Recover a crash after SQLite commit but before public projection rename.
        try connection.execute("BEGIN IMMEDIATE")
        do {
            if let data = try connection.latestData() {
                _ = try SnapshotCodec.decode(data)
                try PrivateFile.write(data, to: directory.appendingPathComponent("latest-public.json"))
            } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("latest-public.json").path) {
                // A missing authoritative database is a recovery error, never silent data deletion/adoption.
                throw StoreError.conflict
            }
            try connection.execute("COMMIT")
        } catch { try? connection.execute("ROLLBACK"); throw error }
    }
    public func latest() throws -> Snapshot? { try db.latestData().map(SnapshotCodec.decode) }

    public func historyCounts() throws -> (observations: Int, hours: Int) {
        let stmt = try db.statement("SELECT (SELECT count(*) FROM observations),(SELECT count(*) FROM hourly_observations)")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.database }
        return (Int(sqlite3_column_int(stmt, 0)), Int(sqlite3_column_int(stmt, 1)))
    }
    public func history(for window: QuotaWindow, since: Date, limit: Int = 48) throws -> [HistoryPoint] {
        guard limit > 0, limit <= 48 else { throw StoreError.conflict }
        let stmt = try db.statement("""
        SELECT observed_at,bps,segment FROM (
          SELECT observed_at,bps,segment,row_number() OVER(PARTITION BY observed_at ORDER BY source_sequence DESC) AS correction
          FROM observations WHERE identity=? AND julianday(observed_at)>=julianday(?)
        ) WHERE correction=1 ORDER BY julianday(observed_at) DESC LIMIT ?
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "\(window.providerId)/\(window.accountId)/\(window.quotaKey)", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, ISO8601DateFormatter().string(from: since), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var points: [HistoryPoint] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let date = sqlite3_column_text(stmt, 0), let segment = sqlite3_column_text(stmt, 2) else { throw StoreError.database }
            points.append(.observation(at: String(cString: date), remainingBps: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 1)), segmentID: String(cString: segment)))
        }
        return points.reversed()
    }
    public func publish(_ input: Data, retainHistory: Bool = true) throws {
        let snapshot = try SnapshotCodec.decode(input)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        // Prune complete UTC hours so recomputing the remaining hours never
        // replaces a full hourly rollup with a partial fine-history subset.
        let sevenDayCutoff = QuotaRules.date(snapshot.capturedAt)!.addingTimeInterval(-7 * 86400)
        let fineCutoff = Date(timeIntervalSince1970: floor(sevenDayCutoff.timeIntervalSince1970 / 3600) * 3600)
        let ninetyDayCutoff = QuotaRules.date(snapshot.capturedAt)!.addingTimeInterval(-90 * 86400)
        let hourlyCutoff = Date(timeIntervalSince1970: floor(ninetyDayCutoff.timeIntervalSince1970 / 3600) * 3600)
        try db.execute("BEGIN IMMEDIATE")
        do {
            if let oldData = try db.latestData() {
                let old = try SnapshotCodec.decode(oldData)
                guard old.sourceDeviceId == snapshot.sourceDeviceId, old.sourceEpoch == snapshot.sourceEpoch,
                      snapshot.sourceSequence >= old.sourceSequence else { throw StoreError.conflict }
                if snapshot.sourceSequence == old.sourceSequence {
                    guard try encoder.encode(old) == data else { throw StoreError.conflict }
                }
            }
            let storedFloors = try db.storedRetentionFloors()
            var fineHistoryFloor = max(fineCutoff, storedFloors?.fine ?? fineCutoff)
            var hourlyHistoryFloor = max(hourlyCutoff, storedFloors?.hourly ?? hourlyCutoff)
            if retainHistory {
                // Reclaim fine history before any inserts. Once the 50 MiB page cap
                // is reached, inserting first would prevent even the latest
                // snapshot from being published.
                try db.deleteObservations(before: fineCutoff)
                try db.deleteHourly(before: hourlyCutoff)
                // The seven-day target yields to the storage cap. Every committed
                // fine observation has already been represented in hourly history.
                let reserve = 1024 // 4 MiB for the new snapshot and hourly rollup.
                var didCapTrim = false
                while try db.integer("PRAGMA max_page_count") - db.integer("PRAGMA page_count")
                    + db.integer("PRAGMA freelist_count") < reserve {
                    if let hourEnd = try db.oldestObservationHourEnd() {
                        guard try db.deleteObservations(before: hourEnd) > 0 else { throw StoreError.database }
                        fineHistoryFloor = max(fineHistoryFloor, hourEnd)
                        didCapTrim = true
                    } else {
                        // The hourly rollups are the last reclaimable history.
                        // This path runs only after fine observations are gone.
                        guard let hourEnd = try db.oldestHourlyHourEnd() else { break }
                        let trimHour = try db.statement("DELETE FROM hourly_observations WHERE hour = (SELECT min(hour) FROM hourly_observations)")
                        defer { sqlite3_finalize(trimHour) }
                        guard sqlite3_step(trimHour) == SQLITE_DONE else { throw StoreError.database }
                        if sqlite3_changes(db.handle) == 0 { break }
                        hourlyHistoryFloor = max(hourlyHistoryFloor, hourEnd)
                        fineHistoryFloor = max(fineHistoryFloor,
                            Date(timeIntervalSince1970: floor(QuotaRules.date(snapshot.capturedAt)!.timeIntervalSince1970 / 3600) * 3600))
                        didCapTrim = true
                    }
                }
                if didCapTrim { try db.saveRetentionFloors(fine: fineHistoryFloor, hourly: hourlyHistoryFloor) }
            } else {
                // No-history mode must release the old pages before replacing
                // the latest snapshot, especially when the database is full.
                try db.execute("DELETE FROM observations; DELETE FROM hourly_observations")
            }
            let stmt = try db.statement("INSERT INTO latest_snapshot(id,body) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body")
            defer { sqlite3_finalize(stmt) }
            let bound = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard bound == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.database }
            if retainHistory {
                for q in snapshot.windows {
                    guard q.fetchOutcome == .ok, let observed = q.observedAt,
                          let observedDate = QuotaRules.date(observed) else { continue }
                    if observedDate < fineHistoryFloor {
                        // After fine history expires, its committed hourly rollup
                        // is authoritative. A late sample fills an empty hour
                        // only, and cannot restore a cap-evicted hour.
                        if observedDate < fineCutoff && observedDate >= hourlyHistoryFloor {
                            try db.insertHistoricalHourlyObservation(q, observedAt: observed, date: observedDate)
                        }
                        continue
                    }
                    let insert = try db.statement("INSERT OR IGNORE INTO observations VALUES(?,?,?,?,?)")
                    defer { sqlite3_finalize(insert) }
                    for (index, value) in ["\(q.providerId)/\(q.accountId)/\(q.quotaKey)", observed, q.window.periodId ?? "unknown"].enumerated() {
                        guard sqlite3_bind_text(insert, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw StoreError.database }
                    }
                    if let bps = q.remainingBps { sqlite3_bind_int(insert, 4, Int32(bps)) } else { sqlite3_bind_null(insert, 4) }
                    sqlite3_bind_int64(insert, 5, snapshot.sourceSequence)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw StoreError.database }
                }
                // Preserve aggregate extrema and largest gap; never interpolate over missing intervals.
                try db.execute("""
                INSERT INTO hourly_observations
                WITH corrected AS (
                    SELECT *, row_number() OVER(PARTITION BY identity, observed_at ORDER BY source_sequence DESC) AS correction FROM observations
                ), samples AS (
                    SELECT identity,observed_at,segment,bps,strftime('%Y-%m-%dT%H:00:00Z',observed_at) AS hour,
                    lag(julianday(observed_at)) OVER(PARTITION BY identity,segment ORDER BY julianday(observed_at)) AS previous
                    FROM corrected WHERE correction=1
                ), grouped AS (
                    SELECT *, first_value(bps) OVER(PARTITION BY identity,hour,segment ORDER BY observed_at) AS first_bps,
                    first_value(bps) OVER(PARTITION BY identity,hour,segment ORDER BY observed_at DESC) AS last_bps FROM samples
                )
                SELECT identity,hour,segment,min(observed_at),max(observed_at),first_bps,last_bps,min(bps),max(bps),count(*),
                    max(coalesce((julianday(observed_at)-previous)*86400,0)) FROM grouped WHERE true GROUP BY identity,hour,segment
                ON CONFLICT(identity,hour,segment) DO UPDATE SET
                    first_at=excluded.first_at, last_at=excluded.last_at,
                    first_bps=excluded.first_bps, last_bps=excluded.last_bps,
                    min_bps=excluded.min_bps, max_bps=excluded.max_bps,
                    sample_count=excluded.sample_count,
                    max_gap_seconds=max(hourly_observations.max_gap_seconds, excluded.max_gap_seconds);
                """)
                try db.deleteHourly(before: hourlyCutoff)
                // A provider may return an older observation in this publish.
                // Keep its hourly rollup, then remove its fine sample immediately.
                try db.deleteObservations(before: fineCutoff)
            }
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
        // Keep the cross-process SQLite writer lock while projecting the committed latest value.
        try db.execute("BEGIN IMMEDIATE")
        do {
            if let current = try db.latestData() { try PrivateFile.write(current, to: directory.appendingPathComponent("latest-public.json")) }
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
    }
}
