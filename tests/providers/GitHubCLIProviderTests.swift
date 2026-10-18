import Darwin
import Foundation
import XCTest
import QuotaCore
@testable import QuotaProviders

private actor GitHubRequestTrace {
    var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}

final class GitHubCLIProviderTests: XCTestCase, @unchecked Sendable {
    private let now = QuotaRules.date("2026-10-08T02:00:00Z")!
    private static let user = Data(#"{"id":123,"login":"demo-user","type":"User"}"#.utf8)
    private static let usage = Data(#"{"timePeriod":{"year":2026,"month":10},"user":"demo-user","usageItems":[{"product":"Actions","sku":"runner","unitType":"minute","netAmount":8,"currency":"USD"}]}"#.utf8)

    func testCLIUsesSameMinimalWindowAndPinAsManualReaderWithoutAuthorizationHeader() async throws {
        let trace = GitHubRequestTrace()
        let report = try await GitHubCLIProvider.read(organization: nil, includeBudgets: false, now: now) { url, headers in
            XCTAssertNil(headers["Authorization"])
            let args = try GitHubCLIProvider.arguments(url: url, headers: headers)
            XCTAssertEqual(Array(args.prefix(7)), ["api", "--hostname", "github.com", "--method", "GET", "--include", "--header"])
            XCTAssertFalse(args.contains("auth")); XCTAssertFalse(args.contains("token"))
            await trace.record(url.path)
            return url.path == "/user" ? Self.user : Self.usage
        }
        let pin = try GitHubCLIProvider.normalized(report, alias: "Synthetic")
        let manual = try GitHubBillingReader.parseUsage(Self.usage,
            identity: GitHubBillingReader.parseIdentity(Self.user, organization: nil), organization: false, now: now)
        let expected = try NativeProviderNormalizer.normalize(manual, providerID: "github-actions", alias: "Synthetic", source: .officialAPI)
        XCTAssertEqual(pin.identityFingerprint, expected.identityFingerprint)
        XCTAssertEqual(pin.windows.first?.amount, "8")
        XCTAssertNil(pin.windows.first?.remainingBps); XCTAssertNil(pin.windows.first?.limit)
        XCTAssertNil(pin.windows.first?.window.resetsAt)
        let paths = await trace.paths
        XCTAssertEqual(paths.count, 2); XCTAssertFalse(paths.contains { $0.contains("budgets") })
    }

    func testCLIAccountSwitchFailsBeforeBillingRequest() async throws {
        let trace = GitHubRequestTrace()
        do {
            _ = try await GitHubCLIProvider.read(organization: nil, includeBudgets: true,
                now: now, expectedIdentity: String(repeating: "f", count: 64)) { url, _ in
                    await trace.record(url.path); return Self.user
                }
            XCTFail("Account change was accepted")
        } catch { XCTAssertEqual(error as? ProviderFailure, .authRequired) }
        let paths = await trace.paths
        XCTAssertEqual(paths, ["/user"])
    }

    func testOfficialHostArgumentsRejectHeaderCredentialAndOwnerInjection() throws {
        let headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": GitHubBillingReader.apiVersion]
        for url in ["http://api.github.com/user", "https://evil.test/user", "https://api.github.com:444/user",
                    "https://api.github.com/user#token", "https://api.github.com/repos/demo/secrets"] {
            XCTAssertThrowsError(try GitHubCLIProvider.arguments(url: URL(string: url)!, headers: headers))
        }
        var unsafe = headers; unsafe["Authorization"] = "SYNTHETIC_MUST_NOT_FORWARD"
        XCTAssertThrowsError(try GitHubCLIProvider.arguments(url: URL(string: "https://api.github.com/user")!, headers: unsafe))
        XCTAssertFalse(GitHubBillingReader.validOwner("demo/../user?x=1"))
    }

    func testResponseKeepsHTTPFailuresSeparateAndNeverExposesBodies() throws {
        for (status, expected) in [(401, GitHubCLIFailure.notLoggedIn), (403, .billingDenied), (404, .billingUnavailable)] {
            let output = Data("HTTP/2.0 \(status) Failure\r\nContent-Type: application/json\r\n\r\nSECRET_UPSTREAM_ERROR".utf8)
            XCTAssertThrowsError(try GitHubCLIProvider.response(.init(output: output, exitCode: 1))) {
                XCTAssertEqual($0 as? GitHubCLIFailure, expected)
                XCTAssertFalse(GitHubBillingReader.localizedError($0).contains("SECRET_UPSTREAM_ERROR"))
            }
        }
        XCTAssertThrowsError(try GitHubCLIProvider.response(.init(output: Data(), exitCode: 4))) {
            XCTAssertEqual($0 as? GitHubCLIFailure, .notLoggedIn)
        }
        XCTAssertThrowsError(try GitHubCLIProvider.response(.init(output: Data("HTTP/2.0 429 Rate limited\n\n{}".utf8), exitCode: 1))) {
            XCTAssertEqual(GitHubBillingReader.classify($0), .rateLimited(seconds: 60))
        }
        XCTAssertEqual(try GitHubCLIProvider.response(.init(output: Data("HTTP/2.0 200 OK\nContent-Type: application/json\n\n{}".utf8), exitCode: 0)), Data("{}".utf8))
    }

    func testGUIEnvironmentExcludesTokenHostDebugAndPromptOverrides() {
        let env = GitHubCLIProcess.environment(home: "/Users/synthetic", inherited: [
            "GH_TOKEN": "SECRET", "GITHUB_TOKEN": "SECRET", "GH_DEBUG": "api", "GH_HOST": "evil.test",
            "GIT_ASKPASS": "/tmp/evil", "GH_CONFIG_DIR": "/Users/synthetic/custom-gh", "PATH": "/tmp/evil"])
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_DEBUG", "GH_HOST", "GIT_ASKPASS"] { XCTAssertNil(env[key]) }
        XCTAssertEqual(env["GH_CONFIG_DIR"], "/Users/synthetic/custom-gh")
        XCTAssertEqual(env["GH_PROMPT_DISABLED"], "1")
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        XCTAssertNil(GitHubCLIProcess.verifiedBinary(at: URL(fileURLWithPath: "/bin/sh")))
    }

    func testConfigDirectoriesRetainGHPrecedenceWithoutSecrets() {
        let env = GitHubCLIProcess.environment(home: "/Users/synthetic", inherited: [
            "GH_CONFIG_DIR": "/custom/gh", "XDG_CONFIG_HOME": "/custom/xdg", "GH_TOKEN": "SYNTHETIC"])
        XCTAssertEqual(env["GH_CONFIG_DIR"], "/custom/gh")
        XCTAssertEqual(env["XDG_CONFIG_HOME"], "/custom/xdg")
        XCTAssertNil(env["GH_TOKEN"])
        let invalid = GitHubCLIProcess.environment(home: "/Users/synthetic", inherited: [
            "GH_CONFIG_DIR": "relative", "XDG_CONFIG_HOME": "/bad\0path"])
        XCTAssertNil(invalid["GH_CONFIG_DIR"]); XCTAssertNil(invalid["XDG_CONFIG_HOME"])
    }

    func testExecutableLocationRejectsWritableParentAndSymlinkChain() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = try XCTUnwrap(GitHubCLIProcess.canonical(root))
        let file = canonicalRoot.appendingPathComponent("binary")
        try Data("SYNTHETIC".utf8).write(to: file)
        XCTAssertTrue(GitHubCLIProcess.secureLocation(file))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        XCTAssertFalse(GitHubCLIProcess.secureLocation(file))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let first = canonicalRoot.appendingPathComponent("first"), second = canonicalRoot.appendingPathComponent("second")
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: file)
        XCTAssertTrue(GitHubCLIProcess.secureLocation(second))
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
        XCTAssertFalse(GitHubCLIProcess.secureLocation(first))
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow write,delete_child", root.path]
        try chmod.run(); chmod.waitUntilExit(); XCTAssertEqual(chmod.terminationStatus, 0)
        XCTAssertFalse(GitHubCLIProcess.secureLocation(file))
    }

    func testRunnerStopsDescendantThatRedirectedBothPipes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await GitHubCLIProcess.run(binary: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 10 >/dev/null 2>&1 & echo $! > \"$1\"; exit 0", "synthetic", file.path])
        XCTAssertEqual(result.exitCode, 0)
        let child = try XCTUnwrap(Int32(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<20 {
            if kill(child, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Runner left its own redirected descendant alive")
    }

    func testRunnerDrainsOutputAndBoundsStderrTimeoutAndCancellation() async throws {
        let r = try await GitHubCLIProcess.run(binary: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["SYNTHETIC_ONLY"])
        XCTAssertEqual(String(decoding: r.output, as: UTF8.self), "SYNTHETIC_ONLY")
        XCTAssertEqual(r.exitCode, 0)
        do {
            _ = try await GitHubCLIProcess.run(binary: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while :; do printf SYNTHETIC >&2; done"], timeout: 2, maxBytes: 128)
            XCTFail("Output was unbounded")
        } catch { XCTAssertEqual(error as? ProviderFailure, .outputLimit) }
        let start = Date()
        do {
            _ = try await GitHubCLIProcess.run(binary: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
            XCTFail("Timeout ignored")
        } catch { XCTAssertEqual(error as? ProviderFailure, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        do {
            // An exited leader must not strand a child that still holds pipes.
            _ = try await GitHubCLIProcess.run(binary: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 10 & exit 0"], timeout: 0.1)
            XCTFail("Inherited output pipes escaped timeout")
        } catch { XCTAssertEqual(error as? ProviderFailure, .timeout) }
        let task = Task { try await GitHubCLIProcess.run(binary: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
        try await Task.sleep(for: .milliseconds(40)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertEqual(error as? ProviderFailure, .cancelled) }
    }

    func testCLILocalRecordOwnsNoVaultInstanceAndRoundTripsOrganization() throws {
        let record = ProviderConnectionRecord(id: "local-github-test", kind: .githubCLILogin,
            providerID: "github-actions", accountID: "native-test", accountAlias: "Synthetic",
            expectedIdentity: String(repeating: "f", count: 64), organizationID: "demo-org")
        let original = try ProviderConnectionsConfiguration(deviceID: "test", epoch: "test", connections: [record]).validated()
        let result = try ProviderConnectionsConfiguration.decodeMigrating(JSONEncoder().encode(original))
        XCTAssertFalse(result.migrated); XCTAssertTrue(result.configuration.connections[0].isEnabled)
        XCTAssertTrue(record.kind.usesLocalLogin); XCTAssertNil(record.instanceID)
        XCTAssertEqual(result.configuration.connections[0].organizationID, "demo-org")
        XCTAssertThrowsError(try ProviderConnectionRecord(id: record.id, kind: .githubCLILogin,
            providerID: "copilot", accountID: record.accountID, accountAlias: record.accountAlias,
            expectedIdentity: record.expectedIdentity).validated())
    }

    func testOptionalOrgBudgetDenialKeepsValidCostAndNormalRefreshNeverFetchesBudgets() async throws {
        let trace = GitHubRequestTrace()
        let report = try await GitHubCLIProvider.read(organization: "demo-org", includeBudgets: true, now: now) { url, _ in
            await trace.record(url.path)
            if url.path == "/user" { return Self.user }
            if url.path == "/orgs/demo-org" { return Data(#"{"id":456,"login":"demo-org","type":"Organization"}"#.utf8) }
            if url.path.hasSuffix("budgets") { throw GitHubCLIFailure.billingDenied }
            return Data(#"{"timePeriod":{"year":2026,"month":10},"organization":"demo-org","usageItems":[{"product":"Actions","sku":"runner","unitType":"minute","netAmount":8}]}"#.utf8)
        }
        XCTAssertEqual(report.budgetState, .permissionDenied)
        XCTAssertEqual(try GitHubCLIProvider.normalized(report, alias: "Synthetic").windows.first?.amount, "8")
        let paths = await trace.paths
        XCTAssertEqual(paths.count, 4)
    }

    /// Explicit opt-in observation, never enabled on CI. No model or state writes.
    func testObserveExistingGHOnlyWhenExplicitlyRequested() async throws {
        guard let file = ProcessInfo.processInfo.environment["AMMO_GH_CLI_PROBE_RECEIPT"] else {
            throw XCTSkip("Live local gh probe requires an explicit private receipt path")
        }
        var receipt = ["source": "actual GitHubCLIProvider with sanitized GUI environment", "credentialCopied": "false"]
        do {
            _ = try GitHubCLIProcess.executable()
            let result = try await GitHubCLIProvider.probe(alias: "Local GitHub Actions", organization: nil)
            receipt["status"] = "successfulRead"
            receipt["windowCount"] = String(result.windows.count)
        } catch {
            receipt["status"] = "unavailable"
            receipt["diagnosticType"] = String(describing: error)
            receipt["localizedDiagnostic"] = GitHubBillingReader.localizedError(error)
        }
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: file))
    }
}
