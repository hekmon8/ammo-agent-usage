import Foundation
import UIKit
import UserNotifications
import QuotaPhone
import Combine
import QuotaCore
import QuotaSync

/// Opt-in relay of Mac balance/budget alerts as standard iOS notifications.
/// The iPhone owns the authorization switch: enabling requests notification
/// permission, registers for remote notifications, and uploads the system
/// token (encrypted at rest) to the paired sync service. Disabling removes
/// both the system registration and the stored token.
@MainActor
final class AlertPushRegistrar: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var status = LocalizedStatus("phone.alerts.status.off")
    private var client: LiveActivityClient?
    private var environment: APNSEnvironment?
    private var credentialScope: String?
    private var pendingToken: Data?

    private static let defaultsKey = "phone.alerts.enabled"
    static let deviceTokenNotification = Notification.Name("phone.alerts.apnsToken")

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        if enabled { status = LocalizedStatus("phone.alerts.status.waitingService") }
        NotificationCenter.default.publisher(for: Self.deviceTokenNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self else { return }
                if let token = note.object as? Data { self.handleDeviceToken(token) }
                else { self.handleRegistrationFailure() }
            }
            .store(in: &cancellables)
    }
    private var cancellables: Set<AnyCancellable> = []

    func configure(_ credentials: ViewerCredentials) async {
        let scope = RemoteActivityRegistrar.scope(credentials)
        guard credentialScope != scope else { return }
        credentialScope = scope
        client = try? LiveActivityClient(credentials: credentials)
        environment = (Bundle.main.object(forInfoDictionaryKey: "QuotaAPNSEnvironment") as? String).flatMap(APNSEnvironment.init(rawValue:))
        if enabled { await refreshTokenIfAvailable() }
    }

    func deconfigure() {
        credentialScope = nil
        client = nil
        if enabled { status = LocalizedStatus("phone.alerts.status.waitingService") }
    }

    func setEnabled(_ on: Bool) async {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.defaultsKey)
        guard on else {
            status = LocalizedStatus("phone.alerts.status.off")
            UIApplication.shared.unregisterForRemoteNotifications()
            if let client = client { try? await client.removeAlertToken() }
            return
        }
        let granted = (try? await LocalNotificationAuthorization.authorize(requestIfNeeded: true, options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            status = LocalizedStatus("phone.alerts.status.denied")
            return
        }
        status = LocalizedStatus("phone.alerts.status.waitingToken")
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called from the AppDelegate adaptor via the shared notification.
    func handleDeviceToken(_ token: Data) {
        guard enabled else { return }
        pendingToken = token
        Task { await refreshTokenIfAvailable() }
    }

    func handleRegistrationFailure() {
        guard enabled else { return }
        status = LocalizedStatus("phone.alerts.status.failed")
    }

    private func refreshTokenIfAvailable() async {
        guard let client, let environment else {
            status = LocalizedStatus("phone.alerts.status.waitingService")
            return
        }
        guard let token = pendingToken else {
            status = LocalizedStatus("phone.alerts.status.waitingToken")
            UIApplication.shared.registerForRemoteNotifications()
            return
        }
        do {
            try await client.registerAlertToken(token, environment: environment)
            status = LocalizedStatus("phone.alerts.status.registered")
        } catch {
            status = LocalizedStatus("phone.alerts.status.failed")
        }
    }
}
