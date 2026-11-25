import CryptoKit
import Foundation
import XCTest
@testable import QuotaSync

final class RemoteMCPClientTests: XCTestCase, @unchecked Sendable {
    func testLifetimeAndReceivedShareRequestsStayOnWriterServiceAndUseOnlyHashes() async throws {
        let endpoint = URL(string: "https://quota.example.invalid")!
        let writer = WriterCredentials(endpoint: endpoint, workspaceID: "test", deviceID: "test-mac", epoch: "test-epoch",
                                       token: "writer-test", keyID: "test-key", signingPrivateKey: Data(), snapshotKey: Data())
        let viewer = "synthetic-viewer-ticket"
        let reader = "synthetic-mcp-reader"
        let expectedHash = SHA256.hash(data: Data(viewer.utf8)).map { String(format: "%02x", $0) }.joined()
        let readerHash = SHA256.hash(data: Data(reader.utf8)).map { String(format: "%02x", $0) }.joined()
        let transport = try SyncTransport(baseURL: endpoint) { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, endpoint.host)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer writer-test")
            let bytes = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains(viewer))
            XCTAssertFalse(text.contains(reader))
            XCTAssertEqual(body["tokenHash"] as? String, readerHash)
            switch url.path {
            case "/v1/mcp-access":
                XCTAssertEqual(request.httpMethod, "PATCH")
                XCTAssertEqual(body["lifetime"] as? String, "until_revoked")
            case "/v1/mcp-shares":
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(body["shares"] as? [[String: String]],
                               [["shareId": "same-service", "viewerTokenHash": expectedHash]])
            default: XCTFail("Unexpected settings route")
            }
            return (Data("{\"accepted\":true}".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = try RemoteMCPClient(credentials: writer, transport: transport)
        try await client.keepKeyUntilRevoked(token: reader)
        try await client.setReceivedShares([
            ShareGrant(endpoint: URL(string: "https://quota.example.invalid:443/")!, shareId: "same-service", token: viewer),
            ShareGrant(endpoint: URL(string: "https://other.example.invalid")!, shareId: "other-service", token: viewer),
            ShareGrant(endpoint: URL(string: "https://quota.example.invalid:8443/")!, shareId: "other-port", token: viewer)
        ], token: reader)
    }
}
