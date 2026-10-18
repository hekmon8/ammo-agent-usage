import XCTest
import Foundation
import CryptoKit
import QuotaCore
import QuotaStore
@testable import QuotaSync

final class SyncTransportTests: XCTestCase {
    func testEarlyReplacementCancellationKeepsOldWriterButProtectsReceivedTarget() async throws {
        final class MemoryVault: SecretStoring, @unchecked Sendable {
            let lock = NSLock(); var values: [String: Data] = [:]
            func load(_ account: String) throws -> Data {
                lock.lock(); defer { lock.unlock() }
                guard let value = values[account] else { throw VaultError.unavailable }
                return value
            }
            func save(_ data: Data, account: String) {
                lock.lock(); defer { lock.unlock() }; values[account] = data
            }
            func remove(_ account: String) {
                lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account)
            }
        }
        let vault = MemoryVault(), oldEndpoint = URL(string: "https://old.example.invalid")!, newEndpoint = URL(string: "https://new.example.invalid")!
        let old = WriterCredentials(endpoint: oldEndpoint, workspaceID: "old", deviceID: "device", epoch: "epoch",
            token: "old-token", keyID: "key", signingPrivateKey: Data(repeating: 1, count: 32), snapshotKey: Data(repeating: 2, count: 32))
        try vault.save(JSONEncoder().encode(old), account: "writer")
        let unavailable = try SyncTransport(baseURL: newEndpoint) { _ in throw TransportError.unavailable }
        do {
            _ = try await SyncWriter.bootstrap(endpoint: newEndpoint, token: "bad-token", vault: vault,
                transport: unavailable, supersedingStored: true, persist: false)
            XCTFail("unavailable service accepted")
        } catch TransportError.unavailable {}
        XCTAssertTrue(try SyncWriter.canCancelPendingReplacementBootstrap(vault: vault))
        try vault.save(Data("received token".utf8), account: "bootstrap-response")
        XCTAssertFalse(try SyncWriter.canCancelPendingReplacementBootstrap(vault: vault))
        XCTAssertThrowsError(try SyncWriter.cancelPendingReplacementBootstrap(vault: vault))
        try vault.remove("bootstrap-response")
        try vault.save(Data("target".utf8), account: "switch-target")
        XCTAssertFalse(try SyncWriter.canCancelPendingReplacementBootstrap(vault: vault))
        XCTAssertThrowsError(try SyncWriter.cancelPendingReplacementBootstrap(vault: vault))
        try vault.remove("switch-target")
        try SyncWriter.cancelPendingReplacementBootstrap(vault: vault)
        XCTAssertNil(try SyncWriter.pendingReplacementBootstrap(vault: vault))
        XCTAssertEqual(try JSONDecoder().decode(WriterCredentials.self, from: vault.load("writer")).workspaceID, "old")
    }
    func testRetiredServiceRevocationSurvivesSwitchAndCannotBeOverwritten() throws {
        final class MemoryVault: SecretStoring, @unchecked Sendable {
            let lock = NSLock(); var values: [String: Data] = [:]
            func load(_ account: String) throws -> Data {
                lock.lock(); defer { lock.unlock() }
                guard let value = values[account] else { throw VaultError.unavailable }
                return value
            }
            func save(_ data: Data, account: String) {
                lock.lock(); defer { lock.unlock() }; values[account] = data
            }
            func remove(_ account: String) {
                lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account)
            }
        }
        let vault = MemoryVault()
        func credentials(_ host: String) -> WriterCredentials {
            WriterCredentials(endpoint: URL(string: "https://\(host).example.invalid")!, workspaceID: host,
                deviceID: "device", epoch: "epoch", token: "secret-\(host)", keyID: "key",
                signingPrivateKey: Data(repeating: 1, count: 32), snapshotKey: Data(repeating: 2, count: 32))
        }
        let old = credentials("old"), next = credentials("new")
        try vault.save(JSONEncoder().encode(old), account: "writer")
        try RetiredServiceRevocation.retain(old, vault: vault)
        try vault.save(JSONEncoder().encode(next), account: "writer")
        let pending = try XCTUnwrap(RetiredServiceRevocation.pending(vault: vault))
        XCTAssertTrue(pending.matches(old))
        XCTAssertFalse(pending.matches(next))
        XCTAssertThrowsError(try RetiredServiceRevocation.retain(next, vault: vault))
        XCTAssertTrue(try XCTUnwrap(RetiredServiceRevocation.pending(vault: vault)).matches(old))
        try RetiredServiceRevocation.clear(vault: vault)
        XCTAssertNil(try RetiredServiceRevocation.pending(vault: vault))
    }
    func testDeferredServiceBootstrapKeepsOldWriterUntilExplicitCommit() async throws {
        final class MemoryVault: SecretStoring, @unchecked Sendable {
            let lock = NSLock(); var values: [String: Data] = [:]
            func load(_ account: String) throws -> Data {
                lock.lock(); defer { lock.unlock() }
                guard let value = values[account] else { throw VaultError.unavailable }
                return value
            }
            func save(_ data: Data, account: String) {
                lock.lock(); defer { lock.unlock() }; values[account] = data
            }
            func remove(_ account: String) {
                lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account)
            }
        }
        let vault = MemoryVault()
        let oldEndpoint = URL(string: "https://old.example.invalid")!
        let newEndpoint = URL(string: "https://new.example.invalid")!
        let old = WriterCredentials(endpoint: oldEndpoint, workspaceID: "old-ws", deviceID: "old-device", epoch: "old-epoch",
            token: "old-token", keyID: "old-key", signingPrivateKey: Data(repeating: 1, count: 32), snapshotKey: Data(repeating: 2, count: 32))
        try vault.save(JSONEncoder().encode(old), account: "writer")
        let transport = try SyncTransport(baseURL: newEndpoint) { request in
            (Data(#"{"workspaceId":"new-ws","deviceId":"new-device","deviceToken":"new-token","sourceEpoch":"new-epoch"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let target = try await SyncWriter.bootstrap(endpoint: newEndpoint, token: "bootstrap", vault: vault,
            transport: transport, supersedingStored: true, persist: false)
        XCTAssertEqual(try JSONDecoder().decode(WriterCredentials.self, from: vault.load("writer")).workspaceID, old.workspaceID)
        XCTAssertFalse(try vault.load("bootstrap-draft").isEmpty)
        XCTAssertEqual(try SyncWriter.pendingReplacementBootstrap(vault: vault)?.token, "bootstrap")
        XCTAssertFalse(try vault.load("bootstrap-response").isEmpty)
        let unavailableTransport = try SyncTransport(baseURL: newEndpoint) { _ in throw TransportError.unavailable }
        let recovered = try await SyncWriter.bootstrap(endpoint: newEndpoint, token: "bootstrap", vault: vault,
            transport: unavailableTransport, supersedingStored: true, persist: false)
        XCTAssertEqual(recovered.workspaceID, target.workspaceID)
        XCTAssertEqual(recovered.token, target.token)
        try SyncWriter.commitBootstrap(target, vault: vault)
        XCTAssertEqual(try JSONDecoder().decode(WriterCredentials.self, from: vault.load("writer")).workspaceID, target.workspaceID)
        XCTAssertThrowsError(try vault.load("bootstrap-draft"))
        XCTAssertThrowsError(try vault.load("bootstrap-response"))
    }
    private func snapshot(_ sequence: Int64, epoch: String = "epoch-a") throws -> Snapshot {
        try Snapshot.make(windows: [], deviceID: "mac-test", epoch: epoch, sequence: sequence, capturedAt: Date(timeIntervalSince1970: 1788572460))
    }
    func testApprovedNewTrustHasIndependentCacheAndCannotPoisonOldTrust() async throws {
        let directory = URL(fileURLWithPath: "/tmp/qi-sync-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let signer = Curve25519.Signing.PrivateKey(), key = SymmetricKey(size: .bits256)
        let a = SourceTrust(workspaceID: "ws", deviceID: "mac-test", epoch: "epoch-a", keyID: "key-a", publicKey: signer.publicKey.rawRepresentation)
        let b = SourceTrust(workspaceID: "ws", deviceID: "mac-test", epoch: "epoch-b", keyID: "key-b", publicKey: signer.publicKey.rawRepresentation)
        let old = try VerifiedCache(directory: directory, trust: a), next = try VerifiedCache(directory: directory, trust: b)
        _ = try await old.accept(EnvelopeCodec.seal(snapshot(42), workspaceID: "ws", keyID: "key-a", key: key, signingKey: signer), key: key)
        _ = try await next.accept(EnvelopeCodec.seal(snapshot(1, epoch: "epoch-b"), workspaceID: "ws", keyID: "key-b", key: key, signingKey: signer), key: key)
        let oldSequence = try await old.latest(key: key)?.sourceSequence
        let nextSequence = try await next.latest(key: key)?.sourceSequence
        XCTAssertEqual(oldSequence, 42); XCTAssertEqual(nextSequence, 1)
    }
    func testConcurrentUploadsDrainNewerSequenceAndDoNotReencryptAcknowledgedSequence() async throws {
        actor Requests {
            var sequences: [Int64] = []
            func receive(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let envelope = try EnvelopeCodec.decode(request.httpBody!)
                sequences.append(envelope.sequence)
                try await Task.sleep(for: .milliseconds(60))
                let data = try JSONSerialization.data(withJSONObject: ["contentHash": envelope.contentHash, "sourceSequence": envelope.sequence])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let directory = URL(fileURLWithPath: "/tmp/qi-writer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = Requests(), signer = Curve25519.Signing.PrivateKey()
        let endpoint = URL(string: "https://quota.example.invalid")!
        let transport = try SyncTransport(baseURL: endpoint) { try await requests.receive($0) }
        let credentials = WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "mac-test", epoch: "epoch-a", token: "synthetic", keyID: "key", signingPrivateKey: signer.rawRepresentation, snapshotKey: Data(repeating: 7, count: 32))
        let writer = try SyncWriter(credentials: credentials, directory: directory, transport: transport)
        let first = try snapshot(42), second = try snapshot(43)
        let task = Task { try await writer.upload(first) }
        try await Task.sleep(for: .milliseconds(10))
        try await writer.upload(second); try await task.value
        try await writer.upload(second)
        let sequences = await requests.sequences
        XCTAssertEqual(sequences, [42, 43])
    }
    func testACKRequiresTrueAndInvitationRejectsUnsafeOrigin() async throws {
        let endpoint = URL(string: "https://quota.example.invalid")!
        let invite = PairingInvitation(endpoint: endpoint, pairingId: "pair", secret: Base64URL.encode(Data(repeating: 1, count: 32)), sourcePublicKey: Base64URL.encode(Data(repeating: 2, count: 32)))
        XCTAssertEqual(try PairingInvitation.parse(invite.encodedURL()).endpoint, endpoint)
        let claim = PairingClaim(invitation: invite, claimID: "claim", claimToken: "synthetic", recipientPrivateKey: Data(repeating: 3, count: 32))
        let transport = try SyncTransport(baseURL: endpoint) { request in (Data("{\"ok\":false}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        do { try await PairingClient.acknowledge(claim, transport: transport); XCTFail("false ACK accepted") } catch TransportError.malformed {}
        XCTAssertThrowsError(try SyncTransport(baseURL: URL(string: "http://localhost")!))
        XCTAssertThrowsError(try SyncTransport(baseURL: URL(string: "https://user:password@example.invalid")!))
    }
    func testAmbiguousBootstrapReusesPersistedIdentityAndRequestID() async throws {
        final class MemoryVault: SecretStoring, @unchecked Sendable {
            let lock = NSLock(); var values: [String: Data] = [:]
            func load(_ account: String) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let value = values[account] else { throw VaultError.unavailable }; return value }
            func save(_ data: Data, account: String) { lock.lock(); defer { lock.unlock() }; values[account] = data }
            func remove(_ account: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
        }
        actor AmbiguousServer {
            var bodies: [Data] = []
            func receive(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                bodies.append(request.httpBody!)
                if bodies.count == 1 { throw TransportError.unavailable }
                let response = Data(#"{"workspaceId":"ws","deviceId":"mac-test","deviceToken":"synthetic","sourceEpoch":"epoch"}"#.utf8)
                return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let server = AmbiguousServer(), vault = MemoryVault(), endpoint = URL(string: "https://quota.example.invalid")!
        let transport = try SyncTransport(baseURL: endpoint) { try await server.receive($0) }
        do { _ = try await SyncWriter.bootstrap(endpoint: endpoint, token: "synthetic", vault: vault, transport: transport); XCTFail("ambiguous response accepted") } catch TransportError.unavailable {}
        let draft = try vault.load("bootstrap-draft")
        let recovered = try await SyncWriter.recoverInitialBootstrap(vault: vault, transport: transport)
        let credentials = try XCTUnwrap(recovered)
        let bodies = await server.bodies
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bodies[0]) as? NSDictionary, try JSONSerialization.jsonObject(with: bodies[1]) as? NSDictionary)
        XCTAssertFalse(draft.isEmpty)
        XCTAssertEqual(credentials.workspaceID, "ws")
        XCTAssertThrowsError(try vault.load("bootstrap-draft"))
        XCTAssertFalse(try vault.load("writer").isEmpty)
    }

    func testServiceSwitchSupersedesStoredCredentialsOnlyAfterSuccess() async throws {
        final class MemoryVault: SecretStoring, @unchecked Sendable {
            let lock = NSLock(); var values: [String: Data] = [:]
            func load(_ account: String) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let value = values[account] else { throw VaultError.unavailable }; return value }
            func save(_ data: Data, account: String) { lock.lock(); defer { lock.unlock() }; values[account] = data }
            func remove(_ account: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
        }
        actor BootstrapServer {
            let url: URL
            var bodies: [Data] = []
            var rejectNext = false
            init(_ url: URL) { self.url = url }
            func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                bodies.append(request.httpBody!)
                if rejectNext { throw TransportError.unavailable }
                let reply = Data(#"{"workspaceId":"ws","deviceId":"mac-test","deviceToken":"synthetic","sourceEpoch":"epoch"}"#.utf8)
                return (reply, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            func setRejected(_ value: Bool) { rejectNext = value }
        }
        func transport(for server: BootstrapServer, endpoint: URL) throws -> SyncTransport {
            try SyncTransport(baseURL: endpoint) { try await server.handle($0) }
        }
        func storedEndpoint(_ vault: MemoryVault) throws -> URL {
            try JSONDecoder().decode(WriterCredentials.self, from: vault.load("writer")).endpoint
        }
        let vault = MemoryVault()
        let endpointA = URL(string: "https://a.example.invalid")!
        let endpointB = URL(string: "https://b.example.invalid")!
        let endpointC = URL(string: "https://c.example.invalid")!
        let serverA = BootstrapServer(endpointA), serverB = BootstrapServer(endpointB), serverC = BootstrapServer(endpointC)

        let first = try await SyncWriter.bootstrap(endpoint: endpointA, token: "synthetic", vault: vault, transport: transport(for: serverA, endpoint: endpointA))
        XCTAssertEqual(first.endpoint, endpointA)

        // Plain bootstrap refuses a different endpoint while credentials are stored.
        do {
            _ = try await SyncWriter.bootstrap(endpoint: endpointB, token: "synthetic", vault: vault, transport: transport(for: serverB, endpoint: endpointB))
            XCTFail("switched service without supersedingStored")
        } catch SyncError.configuration {}

        // A failing new service changes nothing and keeps the bootstrap draft.
        await serverB.setRejected(true)
        do {
            _ = try await SyncWriter.bootstrap(endpoint: endpointB, token: "synthetic", vault: vault, transport: transport(for: serverB, endpoint: endpointB), supersedingStored: true)
            XCTFail("failed switch accepted")
        } catch TransportError.unavailable {}
        XCTAssertEqual(try storedEndpoint(vault), endpointA)
        XCTAssertFalse(try vault.load("bootstrap-draft").isEmpty)

        // A draft left by an abandoned attempt for another endpoint is regenerated, not fatal.
        let switched = try await SyncWriter.bootstrap(endpoint: endpointC, token: "synthetic", vault: vault, transport: transport(for: serverC, endpoint: endpointC), supersedingStored: true)
        XCTAssertEqual(switched.endpoint, endpointC)
        XCTAssertEqual(try storedEndpoint(vault), endpointC)
        XCTAssertThrowsError(try vault.load("bootstrap-draft"))

        // Retrying the same target reuses the persisted identity and one-time request ID.
        await serverB.setRejected(true)
        do {
            _ = try await SyncWriter.bootstrap(endpoint: endpointB, token: "synthetic", vault: vault, transport: transport(for: serverB, endpoint: endpointB), supersedingStored: true)
            XCTFail("failed switch accepted")
        } catch TransportError.unavailable {}
        await serverB.setRejected(false)
        _ = try await SyncWriter.bootstrap(endpoint: endpointB, token: "synthetic", vault: vault, transport: transport(for: serverB, endpoint: endpointB), supersedingStored: true)
        // bodies[0] belongs to the abandoned first switch attempt whose draft was
        // regenerated for endpoint C; the retry pair must share one identity.
        let bodies = await serverB.bodies
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bodies[1]) as? NSDictionary, try JSONSerialization.jsonObject(with: bodies[2]) as? NSDictionary)
        XCTAssertNotEqual(try JSONSerialization.jsonObject(with: bodies[0]) as? NSDictionary, try JSONSerialization.jsonObject(with: bodies[1]) as? NSDictionary)
        XCTAssertEqual(try storedEndpoint(vault), endpointB)
        XCTAssertThrowsError(try vault.load("bootstrap-draft"))

        // Once connected to it, plain bootstrap idempotently returns the stored credentials.
        let again = try await SyncWriter.bootstrap(endpoint: endpointB, token: "synthetic", vault: vault, transport: transport(for: serverB, endpoint: endpointB))
        XCTAssertEqual(again.workspaceID, switched.workspaceID)
        let finalCount = await serverB.bodies.count
        XCTAssertEqual(finalCount, 3)
    }

    func testRotationAuthenticatesNewPinAndWrapForOnlyApprovedRecipient() throws {
        let signer = Curve25519.Signing.PrivateKey(), recipient = Curve25519.KeyAgreement.PrivateKey()
        let endpoint = URL(string: "https://quota.example.invalid")!
        let writer = WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "mac-test", epoch: "old-epoch", token: "writer-test", keyID: "old-key", signingPrivateKey: signer.rawRepresentation, snapshotKey: Data(repeating: 7, count: 32))
        let device = PairedDevice(deviceId: "viewer-test", name: "Test", role: "viewer", revoked: false, recipientPublicKey: Base64URL.encode(recipient.publicKey.rawRepresentation))
        let removed = PairedDevice(deviceId: "viewer-removed", name: "Removed", role: "viewer", revoked: false, recipientPublicKey: Base64URL.encode(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation))
        let draft = try SourceRotation.prepare(writer, devices: [device, removed], revoking: [removed.deviceId])
        XCTAssertEqual(draft.revokedDeviceIDs, [removed.deviceId])
        let body = try JSONSerialization.jsonObject(with: draft.request) as! [String: Any]
        let wraps = body["wraps"] as! [[String: String]]
        XCTAssertEqual(wraps.map { $0["deviceId"] }, [device.deviceId])
        var proof: [String: Any] = ["oldSourceEpoch":writer.epoch,"sourceEpoch":draft.next.epoch,"keyId":draft.next.keyID,"wrappedSnapshotKey":wraps[0]["wrappedSnapshotKey"]!,"newSourcePublicKey":body["newSourcePublicKey"]!,"trustSignature":body["trustSignature"]!,"sourceDeviceId":writer.deviceID]
        let viewer = ViewerCredentials(endpoint: endpoint, deviceID: device.deviceId, token: "viewer-test", trust: SourceTrust(workspaceID: writer.workspaceID, deviceID: writer.deviceID, epoch: writer.epoch, keyID: writer.keyID, publicKey: signer.publicKey.rawRepresentation), snapshotKey: writer.snapshotKey, recipientPrivateKey: recipient.rawRepresentation)
        let next = try SourceRotation.verifyViewerProposal(JSONSerialization.data(withJSONObject: proof), current: viewer)
        XCTAssertEqual(next.snapshotKey, draft.next.snapshotKey)
        XCTAssertEqual(next.trust.publicKey, try Curve25519.Signing.PrivateKey(rawRepresentation: draft.next.signingPrivateKey).publicKey.rawRepresentation)
        proof["newSourcePublicKey"] = Base64URL.encode(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        XCTAssertThrowsError(try SourceRotation.verifyViewerProposal(JSONSerialization.data(withJSONObject: proof), current: viewer))
    }

    func testRotationRetryKeepsRevocationIntentAndRevokesBeforeSubmitting() async throws {
        final class MemoryVault: SecretStoring, @unchecked Sendable {
            let lock = NSLock(); var values: [String: Data] = [:]
            func load(_ account: String) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let value = values[account] else { throw VaultError.unavailable }; return value }
            func save(_ data: Data, account: String) { lock.lock(); defer { lock.unlock() }; values[account] = data }
            func remove(_ account: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
        }
        actor AmbiguousRotationServer {
            var requests: [(String, String)] = []
            var firstDelete = true
            func receive(_ request: URLRequest, receipt: Data) throws -> (Data, HTTPURLResponse) {
                requests.append((request.httpMethod ?? "", request.url!.path))
                if request.httpMethod == "DELETE", firstDelete {
                    firstDelete = false
                    throw TransportError.unavailable
                }
                let body = request.httpMethod == "DELETE" ? Data(#"{"ok":true}"#.utf8) : receipt
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let endpoint = URL(string: "https://quota.example.invalid")!, signer = Curve25519.Signing.PrivateKey()
        let writer = WriterCredentials(endpoint: endpoint, workspaceID: "ws", deviceID: "mac-test", epoch: "old-epoch", token: "writer-test", keyID: "old-key", signingPrivateKey: signer.rawRepresentation, snapshotKey: Data(repeating: 7, count: 32))
        let removed = PairedDevice(deviceId: "viewer-removed", name: "Removed", role: "viewer", revoked: false, recipientPublicKey: Base64URL.encode(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation))
        let draft = try SourceRotation.prepare(writer, devices: [removed], revoking: [removed.deviceId])
        let receipt = try JSONSerialization.data(withJSONObject: ["workspaceId": draft.next.workspaceID, "sourceEpoch": draft.next.epoch, "keyId": draft.next.keyID])
        let server = AmbiguousRotationServer(), vault = MemoryVault()
        let transport = try SyncTransport(baseURL: endpoint) { try await server.receive($0, receipt: receipt) }

        do { _ = try await SourceRotation.submit(draft, vault: vault, transport: transport); XCTFail("ambiguous revoke accepted") }
        catch TransportError.unavailable {}
        let persisted = try JSONDecoder().decode(RotationDraft.self, from: vault.load("rotation-draft"))
        XCTAssertEqual(persisted.revokedDeviceIDs, [removed.deviceId])
        _ = try await SourceRotation.submit(persisted, vault: vault, transport: transport)
        let requests = await server.requests.map { $0.0 + " " + $0.1 }
        XCTAssertEqual(requests, [
            "DELETE /v1/devices/viewer-removed",
            "DELETE /v1/devices/viewer-removed",
            "POST /v1/source-key-rotations"
        ])
        XCTAssertThrowsError(try vault.load("rotation-draft"))
        XCTAssertFalse(try vault.load("writer").isEmpty)
    }

}
