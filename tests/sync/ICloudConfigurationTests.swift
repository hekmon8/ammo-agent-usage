import XCTest
import QuotaCore
@testable import QuotaSync

final class ICloudConfigurationTests: XCTestCase {
    func testContainerIdentifierRequiresExplicitResolvedConfiguration() {
        XCTAssertNil(ICloudSnapshotSync.containerIdentifier)
        XCTAssertEqual(ICloudSnapshotSync.configuredContainerIdentifier("iCloud.org.example.ammo"), "iCloud.org.example.ammo")
        for value: String? in [nil, "", "$(QI_ICLOUD_CONTAINER)", "org.example.ammo", "iCloud.",
                              "iCloud.org..ammo", "iCloud.org.example. ammo"] {
            XCTAssertNil(ICloudSnapshotSync.configuredContainerIdentifier(value))
        }
    }

    func testMissingContainerFailsBeforeCloudKitAccess() async throws {
        let service = ICloudSnapshotSync(containerIdentifier: nil)
        do {
            _ = try await service.accountIdentifier()
            XCTFail("Missing container configuration was accepted")
        } catch ICloudSyncError.configuration {} catch { XCTFail("Unexpected error: \(type(of: error))") }
        do {
            _ = try await service.fetch()
            XCTFail("Unconfigured CloudKit fetch was accepted")
        } catch ICloudSyncError.configuration {} catch { XCTFail("Unexpected error: \(type(of: error))") }
        let snapshot = try Snapshot.make(windows: [], deviceID: "test", epoch: "test", sequence: 1, capturedAt: Date())
        do {
            try await service.upload(snapshot)
            XCTFail("Unconfigured CloudKit upload was accepted")
        } catch ICloudSyncError.configuration {} catch { XCTFail("Unexpected error: \(type(of: error))") }
    }
}
