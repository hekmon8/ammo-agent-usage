import CloudKit

/// Isolated request sequencing so cold-container recovery can be tested without iCloud.
enum ICloudContainerRecovery {
    static func readRecord(
        fetch: @Sendable () async throws -> CKRecord,
        bootstrap: @Sendable () async throws -> Void
    ) async throws -> CKRecord {
        try Task.checkCancellation()
        do { return try await fetch() }
        catch let rejection as CKError where rejection.code == .serverRejectedRequest {
            // A cold container can reject private reads until public zone metadata
            // has been requested. This reads no public records and writes no data.
            try Task.checkCancellation()
            do { try await bootstrap() }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                // A missing *public zone* must not become a missing private record.
                throw rejection
            }
            try Task.checkCancellation()
            // Deliberately outside a retry loop: propagate any second failure.
            return try await fetch()
        }
    }
}
