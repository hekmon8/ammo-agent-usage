import XCTest
import Foundation
import QuotaCore
@testable import QuotaSync

final class QuotaShareSelectionTests: XCTestCase {
    func testShareRevocationRequiresExplicitServerState() async throws {
        let endpoint = URL(string: "https://quota.example.invalid")!
        let credentials = WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "writer", epoch: "epoch",
            token: "synthetic", keyID: "key", signingPrivateKey: Data(), snapshotKey: Data())
        let transport = try SyncTransport(baseURL: endpoint) { request in
            (Data(#"{"state":"approved"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let writer = try ShareWriter(credentials: credentials, transport: transport)
        do { try await writer.revoke(shareId: "share-test"); XCTFail("false revocation accepted") }
        catch TransportError.malformed {}
    }
    func testShareSelectsOnlyExactProviderAndAccountBeforeRedaction() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func window(_ provider: String, _ account: String, _ amount: String) -> QuotaWindow {
            .providerValue(id: "window-\(provider)-\(account)", providerID: provider, accountID: account,
                           alias: "Private", key: "balance", unit: .money, currency: "USD",
                           remainingBps: nil, amount: amount, limit: nil, quality: .reported,
                           source: .officialAPI, observedAt: now, staleAt: now.addingTimeInterval(600),
                           windowKind: .unknown, duration: nil, resetsAt: nil)
        }
        let snapshot = try Snapshot.make(windows: [window("codex", "first", "7"),
                                                    window("codex", "second", "999"),
                                                    window("other", "first", "555")],
                                         deviceID: "mac-test", epoch: "epoch-test", sequence: 1, capturedAt: now)
        let record = try JSONDecoder().decode(ShareRecord.self, from: Data(#"{"shareId":"share-test","connectionId":"connection-test","providerId":"codex","accountId":"first","label":"Personal","state":"approved","recipientName":null,"claimId":null,"verificationCode":null,"expiresAt":"2027-01-01T00:00:00Z"}"#.utf8))
        let projection = try XCTUnwrap(ShareProjection.selected(snapshot, for: record))
        XCTAssertEqual(projection.windows.map(\.amount), ["7"])
        XCTAssertEqual(projection.windows.map(\.quotaKey), ["balance"])
        let wire = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
        XCTAssertFalse(wire.contains("accountId"))
        XCTAssertFalse(wire.contains("Private"))
        XCTAssertFalse(wire.contains("999"))
    }
}
