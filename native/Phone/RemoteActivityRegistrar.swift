import Foundation
import Combine
import CryptoKit
import QuotaCore
import QuotaSync
import QuotaWidgets
import QuotaPhone
@preconcurrency import ActivityKit

/// The phone grants remote disclosure per monitoring session. Tokens are kept by
/// ActivityKit and sent directly over the paired HTTPS transport, never to defaults.
@MainActor
final class RemoteActivityRegistrar: ObservableObject, ActivityTokenRegistering {
    @Published private(set) var available = false
    /// The APNs environment this build registers push tokens under, surfaced in
    /// settings so sandbox/production mismatches are diagnosable.
    var pushEnvironment: APNSEnvironment? { environment }
    /// Stored as key + arguments so a language switch re-renders the label.
    @Published private(set) var status = LocalizedStatus("phone.remote.status.unconfigured")
    @Published private(set) var sessionStatus: [String: String] = [:]
    private var client: LiveActivityClient?
    private var environment: APNSEnvironment?
    private var credentialScope: String?
    private var registrationGeneration = UUID()
    private var configurationGeneration = UUID()
    private var transitionGeneration = UUID()
    private var transitionTask: Task<Void, Never>?
    private var disabling = false
    private let sourceBinding = LegacyActivitySourceBinding()
    private var retiringSessions: Set<String> = []
    private struct Registration {
        let windowID: String
        let endsAt: Date
        let generation: UUID
        let sourceIsCurrent: @MainActor () -> Bool
    }
    private struct RegistrationRequest {
        let id: UUID
        let sessionID: String
        let task: Task<Bool, Never>
    }
    private var pending: [String: Registration] = [:]
    private var registrationRequests: [UUID: RegistrationRequest] = [:]

    static func scope(_ credentials: ViewerCredentials) -> String {
        let identity = credentials.endpoint.absoluteString + "|" + credentials.deviceID + "|" + credentials.trust.workspaceID + "|" + credentials.trust.deviceID
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func configure(_ credentials: ViewerCredentials, sourceIsCurrent: @escaping @MainActor (String) -> Bool) async {
        let scope = Self.scope(credentials)
        sourceBinding.configure(scope: scope, isCurrent: sourceIsCurrent)
        let configuration = UUID()
        let transition = UUID()
        configurationGeneration = configuration
        transitionGeneration = transition
        registrationGeneration = UUID()
        available = false
        disabling = true
        credentialScope = scope
        let oldClient = client
        let oldIDs = Array(pending.keys)
        let oldRequests = Array(registrationRequests.values)
        pending.removeAll(); sessionStatus.removeAll()
        client = nil; environment = nil

        let predecessor = transitionTask
        let task = Task { @MainActor [weak self] in
            _ = await predecessor?.value
            guard let self else { return }
            await self.drain(oldRequests)
            for id in oldIDs { try? await oldClient?.end(activityID: id) }
            guard self.configurationGeneration == configuration else {
                self.finishTransition(transition)
                return
            }
            do {
                let next = try LiveActivityClient(credentials: credentials)
                let nextEnvironment = (Bundle.main.object(forInfoDictionaryKey: "QuotaAPNSEnvironment") as? String).flatMap(APNSEnvironment.init(rawValue:))
                let capability = try await next.capabilities()
                guard self.configurationGeneration == configuration else {
                    self.finishTransition(transition)
                    return
                }
                self.client = next; self.environment = nextEnvironment
                self.available = capability.canRegister && nextEnvironment != nil
                self.status = LocalizedStatus(self.available ? "phone.remote.status.configured" : "phone.remote.status.missingPush")
            } catch {
                guard self.configurationGeneration == configuration else {
                    self.finishTransition(transition)
                    return
                }
                self.available = false; self.status = LocalizedStatus("phone.remote.status.checkFailed")
            }
            self.finishTransition(transition)
        }
        transitionTask = task
        await task.value
    }

    func refreshSource(scope: String, sourceIsCurrent: @escaping @MainActor (String) -> Bool) {
        guard scope == credentialScope else { return }
        sourceBinding.refresh(scope: scope, isCurrent: sourceIsCurrent)
    }

    @discardableResult
    func prepare(sessionID: String, windowID: String, endsAt: Date) -> Bool {
        guard available, !disabling, !retiringSessions.contains(sessionID),
              client != nil, environment != nil, let sourceIsCurrent = sourceBinding.capture(windowID: windowID) else { return false }
        // Re-preparing a live session extends its remote coverage; each
        // registration is bounded to a rolling window on the service side.
        pending[sessionID] = Registration(windowID: windowID, endsAt: endsAt, generation: registrationGeneration, sourceIsCurrent: sourceIsCurrent)
        sessionStatus[sessionID] = L("phone.remote.session.waitingToken")
        return true
    }

    func replacePushToken(_ token: Data, sessionID: String) async {
        await submitPushToken(token, sessionID: sessionID, isCurrent: { true })
    }
    private func submitPushToken(_ token: Data, sessionID: String, isCurrent: @escaping @MainActor () -> Bool) async {
        guard let registration = pending[sessionID], registration.generation == registrationGeneration,
              !disabling, !retiringSessions.contains(sessionID), let client, let environment else { return }
        let predecessors = registrationRequests.values.filter { $0.sessionID == sessionID }.map(\.task)
        let requestID = UUID()
        let requestTask = Task {
            await LegacyActivityRegistrationPolicy.submit(after: predecessors,
                isCurrent: { isCurrent() && registration.sourceIsCurrent() &&
                    self.registrationGeneration == registration.generation && !self.disabling &&
                    !self.retiringSessions.contains(sessionID) && SingleActivityDisplayIntentStore.load() == nil },
                request: {
                    do {
                        try await client.register(activityID: sessionID, windowID: registration.windowID, pushToken: token,
                            environment: environment, endsAt: registration.endsAt, consent: true)
                        return true
                    } catch { return false }
                })
        }
        registrationRequests[requestID] = RegistrationRequest(
            id: requestID,
            sessionID: sessionID,
            task: requestTask
        )
        let accepted = await requestTask.value
        registrationRequests.removeValue(forKey: requestID)
        guard pending[sessionID]?.generation == registration.generation,
              registrationGeneration == registration.generation,
              !disabling, !retiringSessions.contains(sessionID),
              isCurrent(), registration.sourceIsCurrent(), SingleActivityDisplayIntentStore.load() == nil else { return }
        sessionStatus[sessionID] = accepted
            ? L("phone.remote.session.registered")
            : L("phone.remote.session.fallbackLocal")
    }

    func endActivity(sessionID: String) async {
        guard retiringSessions.insert(sessionID).inserted else { return }
        let previousClient = client
        let requests = registrationRequests.values.filter { $0.sessionID == sessionID }
        pending.removeValue(forKey: sessionID)
        sessionStatus.removeValue(forKey: sessionID)
        await drain(Array(requests))
        try? await previousClient?.end(activityID: sessionID)
        retiringSessions.remove(sessionID)
    }

    /// Called at a foreground opportunity, only when the persisted phone opt-in
    /// is still enabled. Local activities never acquire a push token retroactively.
    func recover(sessionID: String, windowID: String, isCurrent: @escaping @MainActor () -> Bool) async {
        guard available, !disabling, isCurrent(), SingleActivityDisplayIntentStore.load() == nil,
              MonitoringSelectionStore.windows()?.contains(windowID) == true,
              let activity = Activity<QuotaActivityAttributes>.activities.first(where: {
                  $0.attributes.sessionID == sessionID && $0.attributes.windowID == windowID
              }), QuotaActivityCoordinator.isRunning(activity), let token = activity.pushToken else { return }
        let a = activity.attributes
        guard prepare(sessionID: a.sessionID, windowID: a.windowID,
            endsAt: Date(timeIntervalSince1970: Double(a.endsAt))) else { return }
        await submitPushToken(token, sessionID: a.sessionID, isCurrent: isCurrent)
    }

    func disable() async {
        markDisabled()
        let transition = UUID()
        transitionGeneration = transition
        registrationGeneration = UUID()
        disabling = true
        let ids = Set(pending.keys).union(Activity<QuotaActivityAttributes>.activities.filter { $0.pushToken != nil }.map { $0.attributes.sessionID })
        let capturedClient = client
        let requests = Array(registrationRequests.values)
        pending.removeAll(); sessionStatus.removeAll()

        let predecessor = transitionTask
        let task = Task { @MainActor [weak self] in
            _ = await predecessor?.value
            guard let self else { return }
            await self.drain(requests)
            let cleanupClient = capturedClient ?? self.client
            for id in ids { try? await cleanupClient?.end(activityID: id) }
            self.finishTransition(transition)
        }
        transitionTask = task
        await task.value
    }

    func markDisabled() {
        configurationGeneration = UUID(); registrationGeneration = UUID()
        available = false; disabling = true
    }

    private func drain(_ requests: [RegistrationRequest]) async {
        for request in requests {
            _ = await request.task.value
            registrationRequests.removeValue(forKey: request.id)
        }
    }

    private func finishTransition(_ transition: UUID) {
        guard transitionGeneration == transition else { return }
        disabling = false
        transitionTask = nil
    }
}

/// ActivityKit and localized presentation bridge for the tested v2 controller.
@MainActor
final class RemoteGroupRegistrar: ObservableObject, ActivityTokenRegistering {
    @Published private(set) var available = false
    @Published private(set) var cleanupPending = false
    @Published private(set) var sessionStatus: [String: String] = [:]
    private lazy var controller: ActivityGroupRemoteController = {
        let controller = ActivityGroupRemoteController(store: DefaultsActivityGroupJournalStore())
        controller.onChange = { [weak self, weak controller] in
            guard let self, let controller else { return }
            available = controller.available; cleanupPending = controller.cleanupPending
            sessionStatus = controller.sessionStatus.mapValues { status in
                switch status {
                case .waitingToken: L("phone.remote.session.waitingToken")
                case .registered: L("phone.remote.session.registered")
                case .waiting: L("phone.remote.group.waiting")
                case .restartRequired: L("phone.remote.group.restartRequired")
                }
            }
        }
        controller.matchesLocalDisplay = { journal in
            guard let id = journal.groupID,
                  let intent = SingleActivityDisplayIntentStore.load(), intent.phase == .active, intent.sessionID == id,
                  MonitoringSelectionStore.windows() == journal.windowIDs,
                  let activity = Activity<QuotaGroupActivityAttributes>.activities.first(where: {
                      $0.attributes.sessionID == id && QuotaGroupActivityCoordinator.isRunning($0)
                  }) else { return false }
            let a = activity.attributes
            return a.remoteUpdates && a.sourceDeviceID == journal.sourceDeviceID && a.sourceEpoch == journal.sourceEpoch &&
                a.descriptors.map(\.windowID) == journal.windowIDs && a.endsAt == Int64(journal.endsAt.timeIntervalSince1970)
        }
        controller.existingToken = { journal in
            Activity<QuotaGroupActivityAttributes>.activities.first { $0.attributes.sessionID == journal.groupID }?.pushToken
        }
        controller.retireLocalDisplay = { id in
            if var intent = SingleActivityDisplayIntentStore.load(), intent.sessionID == id {
                intent.needsRestart(); SingleActivityDisplayIntentStore.save(intent)
            }
            if let activity = Activity<QuotaGroupActivityAttributes>.activities.first(where: { $0.attributes.sessionID == id }) {
                await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
        return controller
    }()
    func configure(_ credentials: ViewerCredentials) async {
        guard let service = try? PairedActivityGroupService(credentials: credentials) else { await controller.disable(); return }
        let environment = (Bundle.main.object(forInfoDictionaryKey: "QuotaAPNSEnvironment") as? String).flatMap(APNSEnvironment.init(rawValue:))
        await controller.configure(scope: RemoteActivityRegistrar.scope(credentials), service: service, environment: environment)
    }
    func restoreCleanup(_ credentials: ViewerCredentials) async {
        guard let service = try? PairedActivityGroupService(credentials: credentials) else { controller.markDisabled(); return }
        await controller.restoreCleanup(scope: RemoteActivityRegistrar.scope(credentials), service: service)
    }
    func prepare(attributes: QuotaGroupActivityAttributes) async -> Bool {
        await controller.prepare(.init(groupID: attributes.sessionID, windowIDs: attributes.descriptors.map(\.windowID),
            sourceDeviceID: attributes.sourceDeviceID, sourceEpoch: attributes.sourceEpoch,
            endsAt: Date(timeIntervalSince1970: Double(attributes.endsAt))))
    }
    func localCreated(sessionID: String) { controller.localCreated(sessionID: sessionID) }
    func replacePushToken(_ token: Data, sessionID: String) async { await controller.replacePushToken(token, sessionID: sessionID) }
    func markStopped() { controller.markStopped() }
    func markDisabled() { controller.markDisabled() }
    func stop(abandon: Bool = false) async { await controller.stop(abandon: abandon) }
    func endActivity(sessionID: String) async { await controller.endActivity(sessionID: sessionID) }
    func disable() async { await controller.disable() }
    func recover() async { await controller.recover() }
}
