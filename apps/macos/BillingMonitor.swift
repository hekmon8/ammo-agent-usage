import Foundation
import QuotaCore
import QuotaStore
import QuotaSync
import QuotaPhone
import UserNotifications
import Combine
import CryptoKit

@MainActor
protocol BillingNotificationClient {
    func authorize() async throws -> Bool
    func deliver(id: String, title: String, body: String) async throws
    func clear(ids: [String])
}

@MainActor
private struct SystemBillingNotifications: BillingNotificationClient {
    func authorize() async throws -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return try await LocalNotificationAuthorization.authorize(requestIfNeeded: true)
    }
    func deliver(id: String, title: String, body: String) async throws {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    func clear(ids: [String]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

@MainActor
final class BillingMonitor: ObservableObject {
    private struct PendingAlert: Codable {
        var title: String
        var body: String
        var severity: BillingSeverity
    }
    private struct State: Codable {
        var rules: [String: BillingRule] = [:]
        var ledger = BillingAlertLedger()
        var notificationsEnabled = false
        var phoneAlertsEnabled = false
        var pending: [String: PendingAlert] = [:]
        init() {}
        private enum CodingKeys: String, CodingKey { case rules, ledger, notificationsEnabled, phoneAlertsEnabled, pending }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            rules = try values.decodeIfPresent([String: BillingRule].self, forKey: .rules) ?? [:]
            ledger = try values.decodeIfPresent(BillingAlertLedger.self, forKey: .ledger) ?? .init()
            notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
            phoneAlertsEnabled = try values.decodeIfPresent(Bool.self, forKey: .phoneAlertsEnabled) ?? false
            pending = try values.decodeIfPresent([String: PendingAlert].self, forKey: .pending) ?? [:]
        }
    }
    @Published private(set) var rules: [String: BillingRule] = [:]
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var phoneAlertsEnabled = false
    @Published private(set) var phoneRelayConfigured = false
    @Published private(set) var message = ""
    /// Set by the host once Cloudflare sync credentials exist; nil keeps the
    /// relay switch unavailable. The Mac owns the rules and the relay switch;
    /// the iPhone keeps its own notification authorization switch.
    var phoneRelay: BillingAlertRelay? {
        didSet { phoneRelayConfigured = phoneRelay != nil }
    }
    private var state = State()
    private var storageReadable = true
    private let file: URL
    private let notifications: any BillingNotificationClient
    private var deliveries: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var authorizationRequest = UUID()

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotaIsland/billing/state.json"),
         notifications: (any BillingNotificationClient)? = nil) {
        self.file = file
        self.notifications = notifications ?? SystemBillingNotifications()
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try PrivateFile.read(file, maxBytes: 1_048_576)
                state = try JSONDecoder().decode(State.self, from: data)
                guard state.rules.allSatisfy({ $0.key == $0.value.id && $0.value.isValid }) else { throw CocoaError(.fileReadCorruptFile) }
                rules = state.rules; notificationsEnabled = state.notificationsEnabled; phoneAlertsEnabled = state.phoneAlertsEnabled
            } catch { state = State(); storageReadable = false; message = L("billing.storageError") }
        }
    }
    @discardableResult
    private func persist(_ next: State) -> Bool {
        guard storageReadable else { message = L("billing.storageError"); return false }
        do {
            try PrivateFile.write(JSONEncoder().encode(next), to: file)
            state = next; rules = next.rules; notificationsEnabled = next.notificationsEnabled; phoneAlertsEnabled = next.phoneAlertsEnabled
            message = ""
            return true
        } catch { message = L("billing.storageError"); return false }
    }
    func save(_ rule: BillingRule) -> Bool {
        guard rule.isValid else { message = L("billing.invalidRule"); return false }
        var next = state
        let changed = next.rules[rule.id] != rule
        if changed { next.ledger.reset(rule.id); next.pending.removeValue(forKey: rule.id) }
        next.rules[rule.id] = rule
        guard persist(next) else { return false }
        if changed { clear(rule.id) }
        return true
    }
    private func clear(_ id: String) {
        generations[id] = UUID()
        deliveries[id]?.cancel()
        notifications.clear(ids: ["billing-" + id])
    }
    func remove(_ windowID: String) {
        var next = state; next.rules.removeValue(forKey: windowID); next.ledger.reset(windowID); next.pending.removeValue(forKey: windowID)
        if persist(next) { clear(windowID) }
    }
    func setNotifications(_ enabled: Bool) async {
        let request = UUID(); authorizationRequest = request
        if enabled {
            do {
                let allowed = try await notifications.authorize()
                guard authorizationRequest == request else { return }
                guard allowed else {
                    message = L("billing.notificationDenied"); return
                }
            } catch {
                if authorizationRequest == request { message = L("billing.notificationUnavailable") }
                return
            }
        }
        var next = state
        if enabled && !next.notificationsEnabled { next.ledger = .init() }
        next.notificationsEnabled = enabled
        if !enabled { next.pending.removeAll() }
        if persist(next), !enabled {
            for id in Set(rules.keys).union(generations.keys) { clear(id) }
        }
    }
    /// Mac-side relay switch: controls whether fired alerts are also relayed to
    /// consented iPhones. The server switch and the local flag move together;
    /// a failed server call leaves the local flag unchanged.
    func setPhoneAlerts(_ enabled: Bool) async {
        guard let phoneRelay else { message = L("billing.phone.unavailable"); return }
        do {
            try await phoneRelay.setPhoneAlertsEnabled(enabled)
        } catch {
            message = L("billing.phone.serverError")
            phoneAlertsEnabled = state.phoneAlertsEnabled
            return
        }
        var next = state
        next.phoneAlertsEnabled = enabled
        if persist(next), !enabled { phoneAlertsEnabled = false }
        message = ""
    }
    private func relayToPhone(_ pending: PendingAlert) {
        guard state.phoneAlertsEnabled, let phoneRelay else { return }
        let digest = SHA256.hash(data: Data((pending.title + "|" + pending.body).utf8))
        let alertID = "bw-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let title = pending.title, body = pending.body
        let severity: BillingAlertSeverity = pending.severity >= .critical ? .critical : (pending.severity >= .warning ? .warning : .info)
        Task {
            // Best effort: a relay failure never affects the local notification.
            _ = try? await phoneRelay.publish(alertID: alertID, title: title, body: body, severity: severity)
        }
    }
    func severity(for window: QuotaWindow, now: Date = Date()) -> BillingSeverity {
        guard let rule = rules[window.id], let value = rule.value(for: window, now: now) else { return .normal }
        return rule.severity(for: value)
    }
    func observe(_ windows: [QuotaWindow], now: Date = Date()) {
        var next = state
        var events: [(QuotaWindow, BillingSeverity)] = []
        for window in windows {
            guard let rule = next.rules[window.id] else { continue }
            if let level = next.ledger.evaluate(rule, window: window, now: now) { events.append((window, level)) }
        }
        let obsolete = next.ledger.entries.compactMap { id, entry -> String? in
            guard let previous = state.ledger.entries[id],
                  entry.observedAt != previous.observedAt,
                  entry.severity < previous.severity || entry.periodStart != previous.periodStart else { return nil }
            return id
        }
        for id in obsolete { next.pending.removeValue(forKey: id) }
        if next.notificationsEnabled {
            for (window, level) in events {
                let presentation = QuotaPresentation(window: window, now: now)
                next.pending[window.id] = PendingAlert(
                    title: ProviderCatalog.identity(for: window.providerId).displayName + " · " + L(level == .critical ? "billing.critical" : "billing.warning"),
                    body: window.accountAlias + " · " + presentation.valueHeading + " " + presentation.number,
                    severity: level)
            }
        }
        guard !next.rules.isEmpty, persist(next) else { return }
        for id in Set(obsolete + events.map { $0.0.id }) { clear(id) }
        guard notificationsEnabled else { return }
        for window in windows {
            guard let pending = state.pending[window.id], deliveries[window.id] == nil,
                  let rule = rules[window.id], let value = rule.value(for: window, now: now),
                  rule.severity(for: value) >= pending.severity,
                  state.ledger.entries[window.id]?.observedAt == window.observedAt else { continue }
            let generation = UUID()
            generations[window.id] = generation
            deliveries[window.id]?.cancel()
            deliveries[window.id] = Task {
                defer { deliveries.removeValue(forKey: window.id) }
                guard !Task.isCancelled else { return }
                do {
                    try await notifications.deliver(id: "billing-" + window.id, title: pending.title, body: pending.body)
                    // A disable/removal/recovery may occur while the OS accepts it.
                    if generations[window.id] != generation {
                        notifications.clear(ids: ["billing-" + window.id])
                    } else {
                        relayToPhone(pending)
                        var delivered = state; delivered.pending.removeValue(forKey: window.id)
                        _ = persist(delivered)
                    }
                } catch {
                    if generations[window.id] == generation { message = L("billing.notificationUnavailable") }
                }
            }
        }
    }
}
