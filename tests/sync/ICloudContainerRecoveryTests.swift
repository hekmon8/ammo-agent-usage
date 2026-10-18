import CloudKit
import XCTest
@testable import QuotaSync

final class ICloudContainerRecoveryTests: XCTestCase {
    private enum Outcome: Sendable {
        case record, cloud(CKError.Code), partialRejection, cancelled
    }

    private actor Requests {
        var events: [String] = []
        var outcomes: [Outcome]
        let bootstrapFailure: Outcome?
        let cancelAfterBootstrap: Bool

        init(_ outcomes: [Outcome], bootstrapFailure: Outcome? = nil, cancelAfterBootstrap: Bool = false) {
            self.outcomes = outcomes
            self.bootstrapFailure = bootstrapFailure
            self.cancelAfterBootstrap = cancelAfterBootstrap
        }

        func fetch() throws -> CKRecord {
            events.append("private-record")
            guard !outcomes.isEmpty else { throw CKError(.internalError) }
            try fail(outcomes.removeFirst())
            return CKRecord(recordType: "QuotaSnapshot", recordID: CKRecord.ID(recordName: "latest-quota-v1"))
        }

        func bootstrap() throws {
            events.append("public-zone-metadata")
            if let bootstrapFailure { try fail(bootstrapFailure) }
            if cancelAfterBootstrap { withUnsafeCurrentTask { $0?.cancel() } }
        }

        private func fail(_ outcome: Outcome) throws {
            switch outcome {
            case .record: break
            case .cloud(let code): throw CKError(code)
            case .partialRejection:
                throw CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
                    CKRecord.ID(recordName: "latest-quota-v1"): CKError(.serverRejectedRequest)
                ]])
            case .cancelled: throw CancellationError()
            }
        }
    }

    private func run(_ requests: Requests) async throws -> CKRecord {
        try await ICloudContainerRecovery.readRecord(
            fetch: { try await requests.fetch() },
            bootstrap: { try await requests.bootstrap() }
        )
    }

    func testHealthyFetchDoesNotReadPublicMetadata() async throws {
        let requests = Requests([.record])
        let record = try await run(requests)
        XCTAssertEqual(record.recordID.recordName, "latest-quota-v1")
        let events = await requests.events
        XCTAssertEqual(events, ["private-record"])
    }

    func testColdContainerReadsMetadataThenRetriesSameRecordOnce() async throws {
        let requests = Requests([.cloud(.serverRejectedRequest), .record])
        let record = try await run(requests)
        XCTAssertEqual(record.recordID.recordName, "latest-quota-v1")
        let events = await requests.events
        XCTAssertEqual(events, ["private-record", "public-zone-metadata", "private-record"])
    }

    func testOtherFailuresDoNotBootstrap() async {
        for outcome in [Outcome.cloud(.unknownItem), .cloud(.permissionFailure), .cloud(.networkFailure), .partialRejection, .cancelled] {
            let requests = Requests([outcome])
            do { _ = try await run(requests); XCTFail("Expected original failure") }
            catch {
                switch outcome {
                case .cloud(let code): XCTAssertEqual((error as? CKError)?.code, code)
                case .partialRejection: XCTAssertEqual((error as? CKError)?.code, .partialFailure)
                case .cancelled: XCTAssertTrue(error is CancellationError)
                case .record: XCTFail("Unexpected success fixture")
                }
            }
            let events = await requests.events
            XCTAssertEqual(events, ["private-record"])
        }
    }

    func testBootstrapFailureCannotBecomeMissingPrivateRecord() async {
        for code in [CKError.Code.unknownItem, .permissionFailure, .networkFailure] {
            let requests = Requests([.cloud(.serverRejectedRequest)], bootstrapFailure: .cloud(code))
            do { _ = try await run(requests); XCTFail("Expected original rejection") }
            catch { XCTAssertEqual((error as? CKError)?.code, .serverRejectedRequest) }
            let events = await requests.events
            XCTAssertEqual(events, ["private-record", "public-zone-metadata"])
        }
    }

    func testRetryFailureIsNotRetriedAgainAndMissingRecordRemainsMissing() async {
        for code in [CKError.Code.serverRejectedRequest, .unknownItem, .permissionFailure] {
            let requests = Requests([.cloud(.serverRejectedRequest), .cloud(code)])
            do { _ = try await run(requests); XCTFail("Expected retry failure") }
            catch { XCTAssertEqual((error as? CKError)?.code, code) }
            let events = await requests.events
            XCTAssertEqual(events, ["private-record", "public-zone-metadata", "private-record"])
        }
    }

    func testCancellationDuringBootstrapDoesNotRetry() async {
        for throwsCancellation in [false, true] {
            let requests = Requests([.cloud(.serverRejectedRequest)],
                                    bootstrapFailure: throwsCancellation ? .cancelled : nil,
                                    cancelAfterBootstrap: !throwsCancellation)
            let task = Task {
                try await ICloudContainerRecovery.readRecord(
                    fetch: { try await requests.fetch() },
                    bootstrap: { try await requests.bootstrap() }
                )
            }
            switch await task.result {
            case .success: XCTFail("Expected cancellation")
            case .failure(let error): XCTAssertTrue(error is CancellationError)
            }
            let events = await requests.events
            XCTAssertEqual(events, ["private-record", "public-zone-metadata"])
        }
    }

    func testAlreadyCancelledTaskDoesNotMakeRequests() async {
        let requests = Requests([.record])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ICloudContainerRecovery.readRecord(
                fetch: { try await requests.fetch() },
                bootstrap: { try await requests.bootstrap() }
            )
        }
        switch await task.result {
        case .success: XCTFail("Expected cancellation")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        let events = await requests.events
        XCTAssertEqual(events, [])
    }
}
