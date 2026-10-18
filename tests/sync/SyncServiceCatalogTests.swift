import XCTest
import QuotaSync

final class SyncServiceCatalogTests: XCTestCase {
    private let hosted = URL(string: "https://sync.example.invalid")!

    func testOpenSourceBuildRequiresExplicitServiceConfiguration() {
        XCTAssertNil(SyncServiceCatalog.officialEndpoint)
        XCTAssertEqual(SyncServiceCatalog.defaultMode, .selfHosted)
        XCTAssertEqual(SyncServiceCatalog.availableModes, [.selfHosted])
        XCTAssertNil(SyncServiceCatalog.endpoint(for: .official))
        XCTAssertFalse(SyncServiceCatalog.isOfficial(hosted))
    }

    func testConfiguredEndpointRequiresHTTPSOriginWithoutCredentials() throws {
        XCTAssertEqual(SyncServiceCatalog.configuredEndpoint(hosted.absoluteString), hosted)
        XCTAssertNoThrow(try SyncTransport(baseURL: XCTUnwrap(SyncServiceCatalog.configuredEndpoint(hosted.absoluteString))))
        let invalid: [String?] = [nil, "", "$(QI_HOSTED_SYNC_ENDPOINT)", "http://sync.example.invalid",
            "https://sync.example.invalid/path", "https://sync.example.invalid?token=synthetic",
            "https://sync.example.invalid#fragment", "https://synthetic@sync.example.invalid",
            "https://sync.example.invalid:8443"]
        for value in invalid { XCTAssertNil(SyncServiceCatalog.configuredEndpoint(value), "accepted invalid service origin") }
    }

    func testDetectsConfiguredOriginStrictly() {
        XCTAssertTrue(SyncServiceCatalog.isOfficial(hosted, officialEndpoint: hosted))
        XCTAssertTrue(SyncServiceCatalog.isOfficial(URL(string: "https://sync.example.invalid/")!, officialEndpoint: hosted))
        for address in ["http://sync.example.invalid", "https://sync.example.invalid.attacker.example",
                        "https://sync.example.invalid:8443", "https://sync.example.invalid/path",
                        "https://sync.example.invalid?token=synthetic", "https://sync.example.invalid#fragment",
                        "https://synthetic@sync.example.invalid", "https://worker.example.invalid"] {
            XCTAssertFalse(SyncServiceCatalog.isOfficial(URL(string: address)!, officialEndpoint: hosted))
        }
    }

    func testEndpointResolutionNeverFallsBackForSelfHosted() {
        XCTAssertNil(SyncServiceCatalog.endpoint(for: .selfHosted), "Self-hosting requires an explicit address")
        let custom = URL(string: "https://worker.example.invalid")!
        XCTAssertEqual(SyncServiceCatalog.endpoint(for: .selfHosted, custom: custom), custom)
    }

    func testModeRoundTrip() throws {
        XCTAssertEqual(SyncServiceMode.allCases, [.official, .selfHosted])
        for mode in SyncServiceMode.allCases {
            XCTAssertEqual(try JSONDecoder().decode(SyncServiceMode.self, from: JSONEncoder().encode(mode)), mode)
        }
        XCTAssertNotEqual(SyncServiceMode.official.rawValue, SyncServiceMode.selfHosted.rawValue)
    }

    func testPairingInvitationPreservesExplicitEndpoint() throws {
        let invitation = PairingInvitation(endpoint: hosted, pairingId: "pair-1",
            secret: Base64URL.encode(Data(repeating: 1, count: 32)),
            sourcePublicKey: Base64URL.encode(Data(repeating: 2, count: 32)))
        XCTAssertEqual(invitation.endpoint, hosted)
        XCTAssertFalse(SyncServiceCatalog.isOfficial(invitation.endpoint))
        XCTAssertTrue(SyncServiceCatalog.isOfficial(invitation.endpoint, officialEndpoint: hosted))
    }
}
