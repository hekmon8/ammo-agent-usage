import Foundation
import XCTest
@testable import QuotaPhone

final class BackgroundRefreshCompletionTests: XCTestCase {
    func testExpirationBeforeTaskAttachmentCancelsLateWorkAndCannotReportSuccess() async {
        let completion = BackgroundTaskCompletion()
        XCTAssertTrue(completion.expire())
        let work = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        completion.attach(work)
        XCTAssertTrue(work.isCancelled)
        await work.value
        XCTAssertFalse(completion.claim())
        XCTAssertFalse(completion.expire())
    }

    func testExpirationCancelsAttachedRefreshExactlyOnce() async {
        let completion = BackgroundTaskCompletion()
        let work = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        completion.attach(work)
        XCTAssertTrue(completion.expire())
        XCTAssertTrue(work.isCancelled)
        await work.value
        XCTAssertFalse(completion.expire())
        XCTAssertFalse(completion.claim())
    }

    func testCompletedRefreshDoesNotAcceptLateExpiration() async {
        let completion = BackgroundTaskCompletion()
        let work = Task {}
        completion.attach(work)
        await work.value
        XCTAssertTrue(completion.claim())
        XCTAssertFalse(completion.expire())
        XCTAssertFalse(work.isCancelled)
    }

    func testConcurrentCompletionAndExpirationHasOneWinner() async {
        for _ in 0..<100 {
            let completion = BackgroundTaskCompletion()
            async let finished = Task.detached { completion.claim() }.value
            async let expired = Task.detached { completion.expire() }.value
            let results = await [finished, expired]
            XCTAssertEqual(results.filter { $0 }.count, 1)
        }
    }
}
