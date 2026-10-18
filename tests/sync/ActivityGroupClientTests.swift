import XCTest
import Foundation
import QuotaCore
@testable import QuotaSync

final class ActivityGroupClientTests: XCTestCase {
    func testV2OrderedRegistrationUsesSeparateRevisionAndFrozenCoverageClock() async throws {
        actor Recorder {
            var bodies: [Data] = []
            func receive(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                XCTAssertEqual(request.url?.path, "/v2/activities/group")
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
                let bytes = try XCTUnwrap(request.httpBody); bodies.append(bytes)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertEqual(body["windowIds"] as? [String], ["second", "first"])
                XCTAssertEqual(body["sourceDeviceId"] as? String, "mac")
                XCTAssertEqual(body["sourceEpoch"] as? String, "epoch")
                XCTAssertEqual(body["expectedRegistrationRevision"] as? Int, 2)
                XCTAssertEqual(body["expectedDisplayRevision"] as? Int, 8)
                XCTAssertEqual(body["activityToken"] as? String, "00abff")
                XCTAssertNil(body["windowId"]); XCTAssertNil(body["label"]); XCTAssertNil(body["accountId"])
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let end = try XCTUnwrap(f.date(from: try XCTUnwrap(body["endsAt"] as? String)))
                let coverage = try XCTUnwrap(f.date(from: try XCTUnwrap(body["coverageExpiresAt"] as? String)))
                XCTAssertEqual(end.timeIntervalSince(coverage), 4 * 3600, accuracy: 0.001)
                return (Data(#"{"ok":true,"displayRevision":8,"registrationRevision":3,"groupId":"group","stopped":false}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let recorder = Recorder()
        let client = LiveActivityGroupClient(transport: try SyncTransport(baseURL: URL(string: "https://quota.example.invalid")!) { try await recorder.receive($0) }, token: "synthetic")
        let now = Date(timeIntervalSince1970: 1_788_572_460)
        for _ in 0..<2 {
            _ = try await client.register(groupID: "group", expectedDisplayRevision: 8, expectedRegistrationRevision: 2,
                commandID: "same-command", windowIDs: ["second", "first"], sourceDeviceID: "mac", sourceEpoch: "epoch",
                pushToken: Data([0,171,255]), environment: .sandbox, endsAt: now.addingTimeInterval(8*3600), consent: true, now: now)
        }
        let bodies = await recorder.bodies
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bodies[0]) as? NSDictionary, try JSONSerialization.jsonObject(with: bodies[1]) as? NSDictionary)
    }
    func testMissingCapabilityMeansLocalOnlyAndUnknownContentVersionCannotEnableGroup() throws {
        for versions in ["", #", "activityContentVersions":[1]"#, #", "activityContentVersions":[3]"#] {
            let data = Data((#"{"supportsPush":true,"pushMode":"own_team","supportsAlerts":true"# + versions + "}").utf8)
            XCTAssertFalse(try JSONDecoder().decode(LiveUpdateCapabilities.self, from: data).canRegisterGroups)
        }
        let data = Data(#"{"supportsPush":true,"pushMode":"own_team","supportsAlerts":true,"activityContentVersions":[1,2]}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(LiveUpdateCapabilities.self, from: data).canRegisterGroups)
    }
    func testMalformedReceiptAndDuplicateSelectionAreRejected() async throws {
        let client = LiveActivityGroupClient(transport: try SyncTransport(baseURL: URL(string: "https://quota.example.invalid")!) { request in
            (Data(#"{"ok":true,"displayRevision":1,"registrationRevision":1,"groupId":"other","stopped":false}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, token: "synthetic")
        let now = Date()
        for ids in [["a","a"],["a"]] {
            do {
                _ = try await client.register(groupID: "group", expectedDisplayRevision: 0, expectedRegistrationRevision: 0,
                    commandID: "command", windowIDs: ids, sourceDeviceID: "mac", sourceEpoch: "epoch", pushToken: Data([1]),
                    environment: .sandbox, endsAt: now.addingTimeInterval(600), consent: true, now: now)
                XCTFail("Accepted invalid selection or a different group's acknowledgement")
            } catch { }
        }
    }
    func testStopCreatesExplicitFenceAndDeleteCannotImpersonateStop() async throws {
        actor Recorder {
            var methods: [String] = []
            func receive(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                methods.append(request.httpMethod!)
                let response: String
                if request.httpMethod == "PUT" {
                    XCTAssertEqual(request.url?.path, "/v2/activity-display")
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                    XCTAssertEqual(body["expectedDisplayRevision"] as? Int, 4)
                    XCTAssertEqual(body["action"] as? String, "abandon")
                    response = #"{"ok":true,"displayRevision":5,"groupId":null,"stopped":true}"#
                } else { response = #"{"ok":true}"# }
                return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let recorder = Recorder()
        let client = LiveActivityGroupClient(transport: try SyncTransport(baseURL: URL(string: "https://quota.example.invalid")!) { try await recorder.receive($0) }, token: "synthetic")
        let receipt = try await client.stop(expectedDisplayRevision: 4, commandID: "stop", abandon: true)
        XCTAssertTrue(receipt.stopped)
        try await client.end(groupID: "old")
        let methods = await recorder.methods; XCTAssertEqual(methods, ["PUT", "DELETE"])
    }
    func testJournalRetainsUnfinishedCreateAndFrozenCommandsAcrossProcessLoss() throws {
        var journal = ActivityGroupJournal()
        journal.begin(groupID: "group", windowIDs: ["b","a"], sourceDeviceID: "mac", sourceEpoch: "epoch", endsAt: Date().addingTimeInterval(600))
        journal.registration = .init(displayRevision: 3, registrationRevision: 2, tokenHash: "synthetic-hash")
        journal.fence = .init(expectedRevision: 3, abandon: true)
        journal.stopIntent()
        let restored = try JSONDecoder().decode(ActivityGroupJournal.self, from: JSONEncoder().encode(journal))
        XCTAssertTrue(restored.requiresAbandonment); XCTAssertTrue(restored.pendingStop)
        XCTAssertEqual(restored.registration?.commandID, journal.registration?.commandID)
        XCTAssertEqual(restored.registration?.preparedAt, journal.registration?.preparedAt)
        XCTAssertEqual(restored.fence?.commandID, journal.fence?.commandID)
        var stopped = restored; stopped.acknowledgeFence(displayRevision: 4)
        XCTAssertFalse(stopped.pendingStop); XCTAssertNil(stopped.groupID); XCTAssertNil(stopped.registration)
    }
}
