import Foundation

/// Authenticate/validate outside the process-shared lock, then recheck the exact
/// bytes under the lock before replacing. Atomic rename makes unlocked reads
/// complete snapshots; a competing writer requires a fresh admission decision.
public enum OptimisticFileUpdate {
    public static func update<Result>(at file: URL, lockName: String, maxBytes: Int,
                                      prepare: (Data?) throws -> (Data, Result)) throws -> Result {
        func read() throws -> Data? {
            do { return try PrivateFile.read(file, maxBytes: maxBytes) }
            catch StoreError.unavailable { return nil }
        }
        for _ in 0..<8 {
            try Task.checkCancellation()
            let previous = try read()
            let (replacement, result) = try prepare(previous)
            let committed = try FileTransaction.withLock(directory: file.deletingLastPathComponent(), name: lockName) { transaction in
                guard try read() == previous else { return false }
                try transaction.checkCancellation()
                try PrivateFile.write(replacement, to: file, checkCancellation: transaction.checkCancellation)
                return true
            }
            if committed { return result }
        }
        // Preserve the newest committed data rather than overwrite on contention.
        throw StoreError.conflict
    }
}
