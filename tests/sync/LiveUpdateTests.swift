import XCTest
import Foundation
import QuotaCore
@testable import QuotaSync

final class LiveUpdateTests: XCTestCase {
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

    private let now = Date(timeIntervalSince1970: 1_788_572_460)

    private func window(_ id: String = "claude-weekly") -> QuotaWindow {
        .reported(id: id, providerID: "claude", accountID: "private-account", alias: "Private alias",
                  key: "weekly", remainingBps: 4200, observedAt: now, staleAt: now.addingTimeInterval(600),
                  duration: 604800, resetsAt: nil, source: .userDefined)
    }

    func testProjectionContainsOnlyAllowedFieldsAndCanonicalTimes() throws {
        let projection = try XCTUnwrap(LiveQuotaProjection(window: window(), sequence: 7, now: now))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sequence", "windowId", "label", "remainingBps", "displayState", "observedAt", "staleAt", "resetsAt"])
        XCTAssertEqual(object["label"] as? String, "claude · weekly")
        XCTAssertEqual(object["remainingBps"] as? Int, 4200)
        XCTAssertTrue((object["observedAt"] as? String)?.hasSuffix(".000Z") == true)
        XCTAssertTrue(object["resetsAt"] is NSNull)
        XCTAssertEqual(projection.displayState, "fresh")
        XCTAssertEqual(LiveQuotaProjection(window: window().withOutcome(.error), sequence: 8, now: now)?.displayState, "stale")
        XCTAssertNil(LiveQuotaProjection(window: window(), sequence: 8, now: now.addingTimeInterval(-180)))
        let unauthorized = try XCTUnwrap(LiveQuotaProjection(window: window().withOutcome(.authRequired), sequence: 8, now: now))
        XCTAssertEqual(unauthorized.remainingBps, 4200)
        XCTAssertEqual(unauthorized.displayState, "authRequired")
    }

    func testUnverifiedQualityIsNotPublishedAsRemoteReportedQuota() throws {
        for quality in ["estimated", "unknown"] {
            let data = try JSONEncoder().encode(window())
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["quality"] = quality
            let value = try JSONDecoder().decode(QuotaWindow.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(LiveQuotaProjection(window: value, sequence: 7, now: now))
            XCTAssertTrue(QuotaPresentation(window: value, now: now).status.contains(quality == "estimated" ? "估算" : "来源未确认"))
        }
    }

    func testRegistrationRequiresConsentAndAcknowledgementAndEncodesTokenAsHex() async throws {
        actor Recorder {
            var count = 0
            func receive(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                count += 1
                XCTAssertEqual(request.url?.path, "/v1/activities/session")
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                XCTAssertEqual(body["activityToken"] as? String, "00abff")
                XCTAssertEqual(body["environment"] as? String, "sandbox")
                XCTAssertEqual(body["projectionConsent"] as? Bool, true)
                return (Data(#"{"ok":true}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let recorder = Recorder()
        let transport = try SyncTransport(baseURL: URL(string: "https://quota.example.invalid")!) { try await recorder.receive($0) }
        let client = LiveActivityClient(transport: transport, token: "synthetic")
        do {
            try await client.register(activityID: "session", windowID: "window", pushToken: Data([0, 171, 255]), environment: .sandbox, endsAt: now.addingTimeInterval(600), consent: false, now: now)
            XCTFail("Registration accepted without consent")
        } catch SyncError.configuration {}
        let before = await recorder.count
        XCTAssertEqual(before, 0)
        try await client.register(activityID: "session", windowID: "window", pushToken: Data([0, 171, 255]), environment: .sandbox, endsAt: now.addingTimeInterval(600), consent: true, now: now)
        let after = await recorder.count
        XCTAssertEqual(after, 1)
    }

    func testLongSessionRegistrationIsBoundedToTheRollingServiceWindow() async throws {
        actor Recorder {
            var endsAt: String?
            func receive(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                endsAt = body["endsAt"] as? String
                return (Data(#"{"ok":true}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let recorder = Recorder()
        let transport = try SyncTransport(baseURL: URL(string: "https://quota.example.invalid")!) { try await recorder.receive($0) }
        let client = LiveActivityClient(transport: transport, token: "synthetic")
        // An 8-hour session registers its first coverage slice instead of being
        // rejected; the service re-registration path extends it later.
        try await client.register(activityID: "session", windowID: "window", pushToken: Data([0, 171, 255]), environment: .sandbox, endsAt: now.addingTimeInterval(8 * 60 * 60), consent: true, now: now)
        let recordedValue = await recorder.endsAt
        let recorded = try XCTUnwrap(recordedValue)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try XCTUnwrap(formatter.date(from: recorded))
        XCTAssertEqual(parsed.timeIntervalSince(now), 4 * 60 * 60, accuracy: 1)
    }

    func testConsentDefaultsOffAndConcurrentPublicationsRemainOrdered() async throws {
        actor Recorder {
            var sequences: [Int] = []
            func receive(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                sequences.append(try XCTUnwrap(object["sequence"] as? Int))
                try await Task.sleep(for: .milliseconds(20))
                return (Data(#"{"ok":true}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let recorder = Recorder()
        let transport = try SyncTransport(baseURL: URL(string: "https://quota.example.invalid")!) { try await recorder.receive($0) }
        let client = LiveProjectionClient(transport: transport, token: "synthetic")
        let first = try Snapshot.make(windows: [window()], deviceID: "mac", epoch: "epoch", sequence: 1, capturedAt: now)
        let next = try Snapshot.make(windows: [window()], deviceID: "mac", epoch: "epoch", sequence: 2, capturedAt: now)
        let disabled = await client.upload(first, now: now)
        XCTAssertEqual(disabled.accepted, 0)
        await client.setConsent(true)
        let observationTime = now
        let task = Task { await client.upload(first, now: observationTime) }
        try await Task.sleep(for: .milliseconds(5))
        _ = await client.upload(next, now: now)
        _ = await task.value
        _ = await client.upload(first, now: now)
        let sequences = await recorder.sequences
        XCTAssertEqual(sequences, [1, 2])
        await client.setConsent(false)
        _ = await client.upload(next, now: now)
        let count = await recorder.sequences.count
        XCTAssertEqual(count, 2)
    }

    func testMalformedAcknowledgementAndUnavailablePushAreNotSuccess() async throws {
        let transport = try SyncTransport(baseURL: URL(string: "https://quota.example.invalid")!) { request in
            (Data(#"{"ok":false}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = LiveProjectionClient(transport: transport, token: "synthetic")
        await client.setConsent(true)
        let snapshot = try Snapshot.make(windows: [window()], deviceID: "mac", epoch: "epoch", sequence: 1, capturedAt: now)
        let result = await client.upload(snapshot, now: now)
        XCTAssertEqual(result.accepted, 0)
        XCTAssertEqual(result.failed, 1)
    }
}
