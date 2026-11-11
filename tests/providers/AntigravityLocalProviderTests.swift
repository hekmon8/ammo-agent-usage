import Foundation
import XCTest
import QuotaCore
@testable import QuotaProviders

final class AntigravityLocalProviderTests: XCTestCase {
    private func report(_ buckets: String, status: String = "SUCCESS", command: String = "usage") -> Data {
        Data("""
        {"status":"\(status)","command":{"name":"\(command)","data":{"groups":[{"buckets":[\(buckets)]}]}}}
        """.utf8)
    }

    func testWeeklyOnlyAndFourPoolReportsPreserveMeasuredFractionsAndResetTimes() throws {
        let weekly = #"{"id":"gemini-weekly","remaining_fraction":0.73,"reset_time":"2026-11-17T14:14:05Z"},{"id":"3p-weekly","remaining_fraction":0}"#
        let usage = try AntigravityLocalProvider.parseReport(report(weekly))
        XCTAssertEqual(usage.extraWindows.count, 2)
        XCTAssertEqual(usage.extraWindows[0].usedPercent, 27, accuracy: 0.0001)
        XCTAssertEqual(usage.extraWindows[1].usedPercent, 100)
        XCTAssertEqual(usage.extraWindows.map(\.windowMinutes), [10_080, 10_080])
        XCTAssertEqual(usage.extraWindows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-11-17T14:14:05Z"))
        XCTAssertNil(usage.primary, "Weekly-only accounts must not invent five-hour quotas")
        let all = try AntigravityLocalProvider.parseReport(report(weekly + #",{"id":"gemini-5h","remaining_fraction":1},{"id":"3p-5h","remaining_fraction":0.125}"#))
        XCTAssertEqual(all.extraWindows.map(\.id), ["antigravity-quota-summary-gemini-weekly", "antigravity-quota-summary-3p-weekly",
                                                    "antigravity-quota-summary-gemini-5h", "antigravity-quota-summary-3p-5h"])
        XCTAssertEqual(all.extraWindows.map(\.windowMinutes), [10_080, 10_080, 300, 300])
        XCTAssertEqual(all.extraWindows[2].usedPercent, 0)
        XCTAssertEqual(all.extraWindows[3].usedPercent, 87.5)
    }

    func testUnknownDisabledMalformedAndUnsuccessfulReportsCannotBecomeFullQuota() throws {
        let valid = #"{"id":"gemini-weekly","remaining_fraction":0.4}"#
        let mixed = valid + #",{"id":"3p-weekly"},{"id":"gemini-5h","remaining_fraction":1,"enabled":false},{"id":"3p-5h","remaining_fraction":1,"disabled":true},{"id":"future-pool","remaining_fraction":1}"#
        XCTAssertEqual(try AntigravityLocalProvider.parseReport(report(mixed)).extraWindows.count, 1)
        for fraction in ["-0.01", "1.01", "true", #""0.5""#] {
            XCTAssertThrowsError(try AntigravityLocalProvider.parseReport(report(#"{"id":"gemini-weekly","remaining_fraction":\#(fraction)}"#)))
        }
        for data in [report(""), report(#"{"id":"gemini-weekly"}"#), report(valid, status: "ERROR"),
                     report(valid, command: "other"), report(valid + "," + valid),
                     report(#"{"id":"gemini-weekly","remaining_fraction":0.4,"reset_time":"invalid"}"#)] {
            XCTAssertThrowsError(try AntigravityLocalProvider.parseReport(data))
        }
    }

    func testLocalTokenFormatsNeverSubstituteIDOrRefreshToken() throws {
        let nested = Data(#"{"token":{"access_token":"access-A","refresh_token":"do-not-use"},"id_token":"not-an-access-token"}"#.utf8)
        XCTAssertEqual(try AntigravityLocalProvider.accessToken(from: nested), "access-A")
        let wrapped = Data(("go-keyring-base64:" + nested.base64EncodedString() + "\n").utf8)
        XCTAssertEqual(try AntigravityLocalProvider.accessToken(from: wrapped), "access-A")
        XCTAssertEqual(try AntigravityLocalProvider.accessToken(from: Data(#"{"accessToken":"access-B"}"#.utf8)), "access-B")
        for invalid in [#"{"token":{"refresh_token":"secret"},"id_token":"identity"}"#,
                        #"{"access_token":"bad\nheader"}"#, "go-keyring-base64:!", "{}"] {
            XCTAssertThrowsError(try AntigravityLocalProvider.accessToken(from: Data(invalid.utf8)))
        }
    }

    func testRenewalDiscardsOldReportAndAccountSwitchCannotOverwritePinnedAccount() async throws {
        let data = report(#"{"id":"gemini-weekly","remaining_fraction":0.73}"#)
        let first = try await AntigravityLocalProvider.read(alias: "Synthetic", expectedIdentity: nil,
            token: { "old-token" }, report: { data }, identity: { _ in "google-sub-A" })
        XCTAssertEqual(first.windows[0].remainingBps, 7300)
        var reads = 0
        let renewed = try await AntigravityLocalProvider.read(alias: "Synthetic", expectedIdentity: first.identityFingerprint,
            token: { reads += 1; return reads == 1 ? "old-token" : "renewed-token" },
            report: { reads == 1 ? Data("invalid stale report".utf8) : data }, identity: { _ in "google-sub-A" })
        XCTAssertEqual(renewed.accountID, first.accountID)
        XCTAssertEqual(renewed.windows[0].remainingBps, 7300)
        do {
            _ = try await AntigravityLocalProvider.read(alias: "Synthetic", expectedIdentity: first.identityFingerprint,
                token: { "other-token" }, report: { data }, identity: { _ in "google-sub-B" })
            XCTFail("Changed account must require reconnecting")
        } catch { XCTAssertEqual(error as? ProviderFailure, .authRequired) }
        var changes = 0
        do {
            _ = try await AntigravityLocalProvider.read(alias: "Synthetic", expectedIdentity: nil,
                token: { changes += 1; return "changing-\(changes)" }, report: { data }, identity: { _ in "google-sub-A" })
            XCTFail("Unstable credentials cannot identify a report")
        } catch { XCTAssertEqual(error as? ProviderFailure, .authRequired) }
        do {
            _ = try await AntigravityLocalProvider.read(alias: "Synthetic", expectedIdentity: nil,
                token: { "token" }, report: { data }, identity: { _ in throw NativeHTTP.Failure.httpStatus(401) })
            XCTFail("Unverified identity cannot identify a report")
        } catch { XCTAssertEqual(error as? ProviderFailure, .authRequired) }
    }

    func testLocalConnectionRoundTripsWithoutVaultAndRejectsOtherProviders() throws {
        let pin = String(repeating: "a", count: 64)
        let record = ProviderConnectionRecord(id: "local-antigravity-test", kind: .antigravityLocalLogin,
            providerID: "antigravity", accountID: "native-test", accountAlias: "Synthetic", expectedIdentity: pin)
        let configuration = ProviderConnectionsConfiguration(deviceID: "test", epoch: "test", connections: [record])
        let decoded = try ProviderConnectionsConfiguration.decodeMigrating(JSONEncoder().encode(configuration)).configuration
        XCTAssertTrue(try XCTUnwrap(decoded.connections.first).isEnabled)
        XCTAssertEqual(decoded.connections.first?.kind, .antigravityLocalLogin)
        XCTAssertNil(decoded.connections.first?.instanceID)
        for (provider, instance) in [("claude", nil), ("antigravity", UUID().uuidString)] {
            XCTAssertThrowsError(try ProviderConnectionRecord(id: "bad", kind: .antigravityLocalLogin,
                providerID: provider, accountID: "native-test", accountAlias: "Synthetic", expectedIdentity: pin,
                instanceID: instance).validated())
        }
    }

    func testVersionGateAndEnvironmentPreventPromptAndCredentialOverrides() async throws {
        for version in ["1.1.11", "1.2.2", "1.4.3\n", "2.0.0"] { XCTAssertTrue(AntigravityLocalProvider.supportsUsageReport(version)) }
        for version in ["1.1.10", "1.0.99", "unknown", "1.4", ""] { XCTAssertFalse(AntigravityLocalProvider.supportsUsageReport(version)) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = AntigravityLocalProvider.environment(home: "/synthetic", guardDirectory: directory,
            inherited: ["JETSKI_OAUTH_TOKEN": "other-account", "GEMINI_CLI_HOME": "/other", "SSH_TTY": "x",
                        "PATH": "/untrusted", "BROWSER": "/usr/bin/open", "AGY_CLI_DISABLE_AUTO_UPDATE": "false"])
        XCTAssertNil(env["JETSKI_OAUTH_TOKEN"]); XCTAssertNil(env["GEMINI_CLI_HOME"]); XCTAssertNil(env["SSH_TTY"])
        XCTAssertEqual(env["AGY_CLI_DISABLE_AUTO_UPDATE"], "true")
        XCTAssertEqual(env["BROWSER"], directory.appendingPathComponent("open").path)
        let result = try await GitHubCLIProcess.run(binary: URL(fileURLWithPath: "/bin/pwd"), arguments: [],
            environment: env, workingDirectory: directory)
        XCTAssertEqual(result.exitCode, 0)
        let path = try XCTUnwrap(String(data: result.output, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: directory.path).resolvingSymlinksInPath().path)
    }
}
