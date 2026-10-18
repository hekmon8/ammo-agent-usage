import XCTest
import QuotaCore
@testable import AmmoMac

@MainActor
private final class Notifications: BillingNotificationClient {
    var authorized = true
    var authorizationResume: CheckedContinuation<Bool, Never>?
    var onAuthorization: (() -> Void)?
    var fails = false
    var delivered: Set<String> = []
    var clears: [String] = []
    var attempts = 0
    var suspend = false
    var resume: CheckedContinuation<Void, Never>?
    var onStarted: (() -> Void)?
    var onDelivery: (() -> Void)?
    func authorize() async throws -> Bool {
        if onAuthorization != nil {
            return await withCheckedContinuation { continuation in
                authorizationResume = continuation; onAuthorization?()
            }
        }
        return authorized
    }
    func deliver(id: String, title: String, body: String) async throws {
        attempts += 1
        if suspend {
            await withCheckedContinuation { continuation in
                resume = continuation; onStarted?()
            }
        }
        defer { onDelivery?() }
        if fails { throw CocoaError(.fileWriteUnknown) }
        delivered.insert(id)
    }
    func clear(ids: [String]) { clears += ids; delivered.subtract(ids) }
}

final class BillingMonitorTests: XCTestCase {
    @MainActor
    func testNotificationRecoveryDisableRemovalAndRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = Notifications()
        let file = directory.appendingPathComponent("rules.json")
        let monitor = BillingMonitor(file: file, notifications: client)
        var rule = BillingRule(windowID: "wallet", kind: .lowBalance, currency: "USD", warning: "10", critical: "3")
        XCTAssertTrue(monitor.save(rule))
        await monitor.setNotifications(true)
        let now = Date()
        func window(_ amount: String, _ offset: Double) -> QuotaWindow {
            .providerValue(id: "wallet", providerID: "fal", accountID: "synthetic", alias: "Test",
                key: "balance", unit: .money, currency: "USD", remainingBps: nil, amount: amount, limit: nil,
                quality: .reported, source: .officialAPI, outcome: .ok,
                observedAt: now.addingTimeInterval(offset), staleAt: now.addingTimeInterval(600),
                windowKind: .unknown, duration: nil, resetsAt: nil)
        }
        func observeAndWait(_ amount: String, _ offset: Double, using subject: BillingMonitor) async {
            await withCheckedContinuation { continuation in
                client.onDelivery = { continuation.resume(); client.onDelivery = nil }
                subject.observe([window(amount, offset)], now: now.addingTimeInterval(offset))
            }
        }
        await observeAndWait("8", 0, using: monitor)
        XCTAssertEqual(client.delivered, ["billing-wallet"])
        monitor.observe([window("30", 1)], now: now.addingTimeInterval(1))
        XCTAssertTrue(client.delivered.isEmpty)
        client.fails = true
        await observeAndWait("2", 2, using: monitor)
        XCTAssertFalse(monitor.message.isEmpty)
        // A failed OS add remains pending across an application restart.
        let restarted = BillingMonitor(file: file, notifications: client)
        client.fails = false
        await observeAndWait("2", 3, using: restarted)
        XCTAssertEqual(client.attempts, 3)
        XCTAssertEqual(client.delivered, ["billing-wallet"])
        rule.enabled = false
        XCTAssertTrue(restarted.save(rule))
        XCTAssertTrue(client.delivered.isEmpty)
        rule.enabled = true
        XCTAssertTrue(restarted.save(rule))
        await observeAndWait("2", 4, using: restarted)
        restarted.remove("wallet")
        XCTAssertTrue(client.delivered.isEmpty)
        XCTAssertTrue(restarted.save(rule))
        await observeAndWait("2", 5, using: restarted)
        await restarted.setNotifications(false)
        XCTAssertTrue(client.delivered.isEmpty)
        XCTAssertFalse(BillingMonitor(file: file, notifications: client).notificationsEnabled)
    }
    @MainActor
    func testRecoveryWhileSystemAcceptsNotificationClearsLateDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = Notifications(); client.suspend = true
        let monitor = BillingMonitor(file: directory.appendingPathComponent("rules.json"), notifications: client)
        XCTAssertTrue(monitor.save(.init(windowID: "wallet", kind: .lowBalance, currency: "USD", warning: "10", critical: "3")))
        await monitor.setNotifications(true)
        let now = Date()
        func window(_ amount: String, _ offset: Double) -> QuotaWindow {
            .providerValue(id: "wallet", providerID: "fal", accountID: "synthetic", alias: "Test",
                key: "balance", unit: .money, currency: "USD", remainingBps: nil, amount: amount, limit: nil,
                quality: .reported, source: .officialAPI, outcome: .ok,
                observedAt: now.addingTimeInterval(offset), staleAt: now.addingTimeInterval(600),
                windowKind: .unknown, duration: nil, resetsAt: nil)
        }
        await withCheckedContinuation { continuation in
            client.onStarted = { continuation.resume() }
            monitor.observe([window("2", 0)], now: now)
        }
        monitor.observe([window("50", 1)], now: now.addingTimeInterval(1))
        await withCheckedContinuation { continuation in
            client.onDelivery = { continuation.resume() }
            client.resume?.resume()
        }
        XCTAssertTrue(client.delivered.isEmpty)
    }

    @MainActor
    func testPrivateStorageRejectsWideFilesAndSymlinksWithoutOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("rules.json")
        let original = Data("{}".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let rule = BillingRule(windowID: "wallet", kind: .lowBalance, currency: "USD", warning: "10", critical: "3")
        let rejected = BillingMonitor(file: file, notifications: Notifications())
        XCTAssertFalse(rejected.message.isEmpty)
        XCTAssertFalse(rejected.save(rule))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertFalse(BillingMonitor(file: link, notifications: Notifications()).save(rule))
        let safe = directory.appendingPathComponent("private.json")
        XCTAssertTrue(BillingMonitor(file: safe, notifications: Notifications()).save(rule))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: safe.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testDisableWinsWhileAuthorizationIsSuspended() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = Notifications()
        let file = directory.appendingPathComponent("rules.json")
        let monitor = BillingMonitor(file: file, notifications: client)
        var enable: Task<Void, Never>?
        await withCheckedContinuation { continuation in
            client.onAuthorization = { continuation.resume() }
            enable = Task { await monitor.setNotifications(true) }
        }
        await monitor.setNotifications(false)
        client.authorizationResume?.resume(returning: true)
        await enable?.value
        XCTAssertFalse(monitor.notificationsEnabled)
        XCTAssertFalse(BillingMonitor(file: file, notifications: client).notificationsEnabled)
        XCTAssertTrue(client.delivered.isEmpty)
    }

}
