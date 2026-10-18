import XCTest
import Foundation
import Darwin
import QuotaCore
@testable import QuotaProviders

/// Explicitly opt-in, read-only API checks. Never used by ordinary CI.
/// Only sanitized status metadata is written; keys, account IDs and money stay in memory.
final class LiveBillingProviderTests: XCTestCase, @unchecked Sendable {
    func testOpenRouter() async throws { try await check("openrouter", keys: ["OPENROUTER_MANAGEMENT_API_KEY", "PROVIDER_OPENROUTER_SYSTEM_API", "OPENROUTER_API_KEY"]) }
    func testFal() async throws { try await check("fal", keys: ["FAL_ADMIN_API_KEY", "PROVIDER_FAL_SYSTEM_API", "FAL_API_KEY"]) }
    func testCloudflare() async throws {
        try await check("cloudflare", keys: ["CLOUDFLARE_BILLING_API_TOKEN", "CLOUDFLARE_API_TOKEN"], scopeKeys: ["CLOUDFLARE_ACCOUNT_ID"])
    }
    func testVercel() async throws {
        try await check("vercel", keys: ["VERCEL_API_TOKEN", "VERCEL_TOKEN"], scopeKeys: ["VERCEL_TEAM_ID"])
    }
    func testReplit() async throws { try await check("replit", keys: ["REPLIT_ADMIN_API_KEY", "REPLIT_API_KEY"]) }

    private func check(_ provider: String, keys: [String], scopeKeys: [String] = []) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AMMO_LIVE_BILLING"] == "1", let path = environment["AMMO_LIVE_BILLING_ENV_FILE"] else {
            throw XCTSkip("Live billing disabled; explicit opt-in and credential file required")
        }
        let variables: [String: String]
        do { variables = try readVariables(path) }
        catch { XCTFail("Credential file must be an owner-only regular UTF-8 file with simple KEY=value entries"); return }
        func first(_ names: [String]) -> String? { names.compactMap { variables[$0] }.first { !$0.isEmpty } }
        guard let key = first(keys), scopeKeys.isEmpty || first(scopeKeys) != nil else {
            try receipt(provider, result: "missing_credentials", metrics: [], environment: environment)
            throw XCTSkip("Missing credential or account/team scope for \(provider)")
        }
        let credential = NativeProviderCredential(kind: .apiKey, value: key, organizationID: first(scopeKeys))
        do {
            try credential.validated()
            let usage = try await NativeProviderAPI.fetch(providerID: provider, credential: credential)
            let normalized = try NativeProviderNormalizer.normalize(usage, providerID: provider, alias: "Live verification", source: .officialAPI)
            guard !normalized.windows.isEmpty,
                  normalized.windows.allSatisfy({ $0.fetchOutcome == .ok && $0.quality == .reported && $0.sourceMethod == .officialAPI }) else {
                throw ProviderFailure.parseChanged
            }
            let money = normalized.windows.filter { $0.unit == .money }
            let expectsSpend = ["cloudflare", "vercel", "replit"].contains(provider)
            guard !money.isEmpty, money.allSatisfy({ $0.remainingBps == nil && $0.amount != nil && $0.currency != nil && $0.isConsumptionMetric == expectsSpend }) else {
                throw ProviderFailure.parseChanged
            }
            let snapshot = try Snapshot.make(windows: normalized.windows, deviceID: "live-verification", epoch: "live", sequence: 1, capturedAt: Date())
            _ = try SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
            try receipt(provider, result: "passed", metrics: Array(Set(money.map { $0.quotaKey })).sorted(), environment: environment)
        } catch {
            let failure = NativeProvider.classify(error)
            let code = String(describing: failure)
            try receipt(provider, result: code, metrics: [], environment: environment)
            XCTFail("Live \(provider) check failed: \(code)")
        }
    }

    private func receipt(_ provider: String, result: String, metrics: [String], environment: [String: String]) throws {
        print("LIVE_BILLING provider=\(provider) result=\(result) metrics=\(metrics.joined(separator: ","))")
        guard let directory = environment["AMMO_LIVE_BILLING_REPORT_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record: [String: Any] = ["provider": provider, "result": result, "metrics": metrics,
            "checkedAt": ISO8601DateFormatter().string(from: Date()), "readOnly": true]
        let file = root.appendingPathComponent(provider + ".json")
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func readVariables(_ path: String) throws -> [String: String] {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProviderFailure.permissionDenied }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 1_048_576, info.st_size >= 0 else {
            throw ProviderFailure.permissionDenied
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { throw ProviderFailure.parseChanged }
        var variables: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { continue }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value.removeFirst(); value.removeLast()
            } else if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
            variables[name] = value
        }
        return variables
    }
}
