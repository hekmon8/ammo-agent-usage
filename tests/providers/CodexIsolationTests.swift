import Foundation
import XCTest
@testable import QuotaProviders

private final class AuthorizationURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?

    func set(_ url: URL) { lock.lock(); value = url; lock.unlock() }
    func get() -> URL? { lock.lock(); defer { lock.unlock() }; return value }
}

final class CodexIsolationTests: XCTestCase {
    private func script(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("server.py")
        try source.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-profiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    func testProfilesUseDistinctPrivateHomesAndDoNotForwardAmbientCredentials() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deletedID = UUID()
        let deleted = try CodexInstanceProfile(root: root, id: deletedID.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.directory.path))
        try deleted.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.directory.path))
        let first = try CodexInstanceProfile(root: root)
        let second = try CodexInstanceProfile(root: root)
        try first.prepare()
        try second.prepare()

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.codexHome, second.codexHome)
        XCTAssertEqual(try first.environment(base: ["PATH": "/test/bin", "OPENAI_API_KEY": "must-not-pass"]), [
            "PATH": "/test/bin", "LANG": "en_US.UTF-8", "HOME": first.home.path,
            "CODEX_HOME": first.codexHome.path, "TMPDIR": first.temporaryDirectory.path + "/",
        ])
        XCTAssertEqual(CodexInstanceProfile.appServerArguments, [
            "-s", "read-only", "-a", "never", "-c", "cli_auth_credentials_store=\"file\"", "app-server",
        ])

        for directory in [first.directory, first.home, first.codexHome, first.temporaryDirectory] {
            let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o077, 0)
        }
    }

    func testScopedEnvironmentSelectsDifferentAppServerAccounts() async throws {
        let path = try script("""
        import json,os,sys
        json.loads(sys.stdin.readline())
        print(json.dumps({'id':0,'result':{}}),flush=True)
        json.loads(sys.stdin.readline())
        request=json.loads(sys.stdin.readline()); assert request['method']=='account/read'
        print(json.dumps({'id':2,'result':{'account':{'type':'chatgpt','email':'profile@example.invalid'}}}),flush=True)
        request=json.loads(sys.stdin.readline()); assert request['method']=='account/rateLimits/read'
        print(json.dumps({'id':1,'result':{'accountId':os.environ['CODEX_HOME'],'rateLimits':{'primary':{'usedPercent':32}}}}),flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try CodexInstanceProfile(root: root)
        let second = try CodexInstanceProfile(root: root)
        try first.prepare()
        try second.prepare()

        let one = try await BoundedRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 2,
                                            environment: try first.environment(base: ["PATH": "/usr/bin:/bin"]))
        let two = try await BoundedRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 2,
                                            environment: try second.environment(base: ["PATH": "/usr/bin:/bin"]))
        XCTAssertNotEqual(one.identityFingerprint, two.identityFingerprint)
        let repeatOne = try await BoundedRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 2,
            environment: try first.environment())
        XCTAssertEqual(one.identityFingerprint, repeatOne.identityFingerprint)
        try first.remove()
        let repeatTwo = try await BoundedRPC.read(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path], timeout: 2,
            environment: try second.environment())
        XCTAssertEqual(two.identityFingerprint, repeatTwo.identityFingerprint)
        XCTAssertThrowsError(try first.environment())
    }

    func testProfileRejectsSymlinkAndPublicAuthAndCleansPartialDraft() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try CodexInstanceProfile(root: root)
        try profile.prepare()
        try Data("synthetic-auth".utf8).write(to: profile.authFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: profile.authFile.path)
        XCTAssertThrowsError(try profile.environment())
        try FileManager.default.removeItem(at: profile.authFile)
        let other = root.appendingPathComponent("unrelated")
        try Data("untouched".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: profile.authFile, withDestinationURL: other)
        XCTAssertThrowsError(try profile.environment())
        try profile.remove()
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "untouched")
        let partial = try CodexInstanceProfile(root: root)
        try FileManager.default.createDirectory(at: partial.directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try partial.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.directory.path))
    }

    func testLoginDeliversValidatedURLThenBindsAccount() async throws {
        let path = try script("""
        import json,sys
        json.loads(sys.stdin.readline())
        print(json.dumps({'id':0,'result':{}}),flush=True)
        assert json.loads(sys.stdin.readline())['method']=='initialized'
        start=json.loads(sys.stdin.readline()); assert start['method']=='account/login/start'; assert start['params']=={'type':'chatgpt'}
        print(json.dumps({'id':3,'result':{'authUrl':'https://auth.openai.example/authorize','loginId':'login-1'}}),flush=True)
        print(json.dumps({'method':'account/login/completed','params':{'loginId':'login-1','success':True}}),flush=True)
        account=json.loads(sys.stdin.readline()); assert account['method']=='account/read'
        print(json.dumps({'id':2,'result':{'account':{'type':'chatgpt','email':'isolated@example.invalid'}}}),flush=True)
        limits=json.loads(sys.stdin.readline()); assert limits['method']=='account/rateLimits/read'
        print(json.dumps({'id':1,'result':{'accountId':'isolated-account','rateLimits':{'primary':{'usedPercent':32}}}}),flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try CodexInstanceProfile(root: root)
        try profile.prepare()
        let callback = AuthorizationURLBox()
        let result = try await BoundedRPC.login(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path],
                                                environment: try profile.environment(base: ["PATH": "/usr/bin:/bin"]),
                                                timeout: 2, onAuthorizationURL: callback.set)
        XCTAssertEqual(callback.get()?.absoluteString, "https://auth.openai.example/authorize")
        XCTAssertEqual(result.identityFingerprint.count, 64)
    }

    func testLoginCancellationTerminatesWaitingSession() async throws {
        let path = try script("""
        import json,sys,time
        json.loads(sys.stdin.readline())
        print(json.dumps({'id':0,'result':{}}),flush=True)
        json.loads(sys.stdin.readline()); json.loads(sys.stdin.readline())
        print(json.dumps({'id':3,'result':{'authUrl':'https://auth.openai.example/authorize','loginId':'login-2'}}),flush=True)
        time.sleep(30)
        """)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try CodexInstanceProfile(root: root)
        try profile.prepare()
        let task = Task {
            try await BoundedRPC.login(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path],
                                        environment: try profile.environment(base: ["PATH": "/usr/bin:/bin"]),
                                        onAuthorizationURL: { _ in })
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch ProviderFailure.cancelled {}
    }

    func testLoginRejectsFailedAndMismatchedCompletionNotifications() async throws {
        for (loginID, success, expected) in [("other-login", true, ProviderFailure.parseChanged), ("login-3", false, ProviderFailure.authRequired)] {
            let path = try script("""
            import json,sys
            json.loads(sys.stdin.readline())
            print(json.dumps({'id':0,'result':{}}),flush=True)
            json.loads(sys.stdin.readline()); json.loads(sys.stdin.readline())
            print(json.dumps({'id':3,'result':{'authUrl':'https://auth.openai.example/authorize','loginId':'login-3'}}),flush=True)
            print(json.dumps({'method':'account/login/completed','params':{'loginId':'\(loginID)','success':\(success ? "True" : "False")}}),flush=True)
            """)
            defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
            let root = try fixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let profile = try CodexInstanceProfile(root: root)
            try profile.prepare()
            do {
                _ = try await BoundedRPC.login(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [path.path],
                                                environment: try profile.environment(base: ["PATH": "/usr/bin:/bin"]),
                                                timeout: 2, onAuthorizationURL: { _ in })
                XCTFail("expected completion rejection")
            } catch let failure as ProviderFailure {
                XCTAssertEqual(failure, expected)
            }
        }
    }
}
