import XCTest
import Foundation
@testable import QuotaSync

private actor GroupTestGate {
    private var entered = false
    private var opened = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        entered = true; arrival?.resume(); arrival = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func open() { opened = true; release?.resume(); release = nil }
}
private actor GroupTestService: ActivityGroupServing {
    enum RegistrationMode { case normal, transientFailure, committedResponseLoss, conflict }
    var capGate: GroupTestGate?
    var registerGate: GroupTestGate?
    var stopGate: GroupTestGate?
    var capFails = false
    var capSupported = true
    var capCount = 0
    var stopFails = false
    var registrationMode = RegistrationMode.normal
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    var display = Int64(0)
    var registration = Int64(0)
    var group: String?
    var stopCount = 0
    var registrationRequests: [ActivityGroupJournal] = []
    var accepted: [String: ActivityGroupReceipt] = [:]
    var pendingCreate: ActivityGroupJournal?
    func set(capGate: GroupTestGate? = nil, registerGate: GroupTestGate? = nil, stopGate: GroupTestGate? = nil, capFails: Bool = false,
             stopFails: Bool = false, mode: RegistrationMode = .normal, now: Date? = nil, supported: Bool = true) {
        self.capGate = capGate; self.registerGate = registerGate; self.stopGate = stopGate; self.capFails = capFails
        self.stopFails = stopFails; registrationMode = mode; if let now { self.now = now }
        capSupported = supported
    }
    func supportsGroups() async throws -> Bool {
        capCount += 1
        if let capGate { await capGate.wait() }
        if capFails { throw TransportError.unavailable }; return capSupported
    }
    func displayState() async throws -> ActivityDisplayState { .init(displayRevision: display, groupId: group, stopped: group == nil) }
    func stop(_ fence: ActivityGroupJournal.Fence) async throws -> ActivityGroupReceipt {
        stopCount += 1
        if let stopGate { await stopGate.wait() }
        if stopFails { throw TransportError.unavailable }
        if let receipt = accepted[fence.commandID] { return receipt }
        guard fence.expectedRevision == display else { throw TransportError.rejected(409) }
        display += 1; group = nil
        let receipt = ActivityGroupReceipt(ok: true, displayRevision: display, registrationRevision: nil, groupId: nil, stopped: true)
        accepted[fence.commandID] = receipt; return receipt
    }
    func register(_ journal: ActivityGroupJournal, token: Data, environment: APNSEnvironment) async throws -> ActivityGroupReceipt {
        registrationRequests.append(journal)
        if let registerGate { await registerGate.wait() }
        guard let request = journal.registration else { throw TransportError.malformed }
        if let receipt = accepted[request.commandID] { return receipt }
        if registrationMode == .transientFailure { pendingCreate = journal; throw TransportError.unavailable }
        if registrationMode == .conflict { throw TransportError.rejected(409) }
        guard min(journal.endsAt, request.preparedAt.addingTimeInterval(4*3600)) > now else { throw TransportError.rejected(400) }
        guard request.expectedDisplayRevision == display, request.expectedRegistrationRevision == registration else { throw TransportError.rejected(409) }
        if request.expectedRegistrationRevision == 0 { display += 1 }
        registration += 1; group = journal.groupID
        let receipt = ActivityGroupReceipt(ok: true, displayRevision: display, registrationRevision: registration, groupId: group, stopped: false)
        accepted[request.commandID] = receipt
        if registrationMode == .committedResponseLoss { throw TransportError.unavailable }
        return receipt
    }
    func commitDelayedCreate() {
        guard let pendingCreate, let request = pendingCreate.registration, request.expectedDisplayRevision == display else { return }
        group = pendingCreate.groupID; display += 1; registration = 1
    }
    func stageDelayedCreate(_ journal: ActivityGroupJournal) { pendingCreate = journal }
    func end(groupID: String) async throws { }
}
@MainActor
private final class GroupTestStore: ActivityGroupJournalStoring {
    var journals: [String: ActivityGroupJournal] = [:]
    var failSave = false
    func load(scope: String) -> ActivityGroupJournal { journals[scope] ?? .init() }
    func save(_ journal: ActivityGroupJournal, scope: String) throws {
        if failSave { throw TransportError.unavailable }; journals[scope] = journal
    }
}
@MainActor
private final class GroupTestClock { var now = Date(timeIntervalSince1970: 1_790_000_000) }

@MainActor
final class ActivityGroupControllerTests: XCTestCase {
    private func configured(_ store: GroupTestStore, _ service: GroupTestService, _ clock: GroupTestClock) async -> ActivityGroupRemoteController {
        let controller = ActivityGroupRemoteController(store: store, clock: { clock.now })
        controller.matchesLocalDisplay = { _ in true }; controller.existingToken = { _ in Data([1]) }
        await controller.configure(scope: "A", service: service, environment: .sandbox)
        return controller
    }
    private func prepare(_ controller: ActivityGroupRemoteController, _ clock: GroupTestClock) async {
        let prepared = await controller.prepare(.init(groupID: "group", windowIDs: ["A", "B"], sourceDeviceID: "mac", sourceEpoch: "epoch", endsAt: clock.now.addingTimeInterval(8*3600)))
        XCTAssertTrue(prepared); controller.localCreated(sessionID: "group")
    }
    func testFailedStopIsRetriedByOrdinaryRecoveryAndFencesLateCreate() async throws {
        let store = GroupTestStore(), service = GroupTestService(), clock = GroupTestClock()
        let controller = await configured(store, service, clock); await prepare(controller, clock)
        await service.set(mode: .transientFailure)
        await controller.replacePushToken(Data([1]), sessionID: "group")
        await service.set(stopFails: true)
        await controller.stop()
        XCTAssertTrue(controller.cleanupPending); XCTAssertFalse(controller.available)
        await service.commitDelayedCreate()
        await service.set()
        await controller.recover()
        XCTAssertFalse(controller.cleanupPending); XCTAssertNil(store.journals["A"]?.groupID)
        let state = try await service.displayState()
        XCTAssertTrue(state.stopped); XCTAssertEqual(state.displayRevision, 2)
    }
    func testScopeCapabilityFailureCannotAcknowledgeBJournalWithAClient() async {
        let store = GroupTestStore(), a = GroupTestService(), b = GroupTestService(), clock = GroupTestClock()
        let controller = await configured(store, a, clock)
        var pending = ActivityGroupJournal(); pending.begin(groupID: "pending-B", windowIDs: ["A"], sourceDeviceID: "mac-B", sourceEpoch: "epoch-B", endsAt: clock.now.addingTimeInterval(600)); pending.stopIntent()
        store.journals["B"] = pending
        await b.set(capFails: true)
        await controller.configure(scope: "B", service: b, environment: .sandbox)
        XCTAssertFalse(controller.available); XCTAssertTrue(controller.cleanupPending)
        await controller.recover()
        let aStops = await a.stopCount, bStops = await b.stopCount
        XCTAssertEqual(aStops, 1); XCTAssertEqual(bStops, 1)
        XCTAssertEqual(store.journals["B"]?.displayRevision, 1)
        XCTAssertFalse(store.journals["B"]!.pendingStop)
    }
    func testDisableInvalidatesSuspendedConfigurationAndRapidReenableUsesNewOne() async {
        let store = GroupTestStore(), service = GroupTestService(), gate = GroupTestGate(), clock = GroupTestClock()
        await service.set(capGate: gate)
        let controller = ActivityGroupRemoteController(store: store, clock: { clock.now })
        let configure = Task { await controller.configure(scope: "A", service: service, environment: .sandbox) }
        await gate.waitUntilEntered()
        let disabled = GroupTestGate()
        controller.onChange = { if !controller.available { Task { await disabled.open() } } }
        let disable = Task { await controller.disable() }
        await disabled.wait(); await gate.open(); await configure.value; await disable.value
        XCTAssertFalse(controller.available)
        await service.set()
        await controller.configure(scope: "A", service: service, environment: .sandbox)
        XCTAssertTrue(controller.available)
    }
    func testCommittedResponseLossReplaysFrozenCommandThenRenewsKnownRegistration() async throws {
        let store = GroupTestStore(), service = GroupTestService(), clock = GroupTestClock()
        let controller = await configured(store, service, clock); await prepare(controller, clock)
        await service.set(mode: .committedResponseLoss)
        await controller.replacePushToken(Data([1]), sessionID: "group")
        let command = store.journals["A"]?.registration?.commandID
        clock.now = clock.now.addingTimeInterval(5*3600); await service.set(now: clock.now)
        await controller.recover()
        let requests = await service.registrationRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].registration?.commandID, command)
        XCTAssertEqual(requests[1].registration?.preparedAt, requests[0].registration?.preparedAt)
        XCTAssertEqual(requests[2].registration?.expectedRegistrationRevision, 1)
        XCTAssertNil(store.journals["A"]?.registration)
        XCTAssertEqual(store.journals["A"]?.registrationRevision, 2)
        let state = try await service.displayState(); XCTAssertEqual(state.groupId, "group"); XCTAssertEqual(state.displayRevision, 1)
    }
    func testNeverCommittedExpiredRequestOrPermanentConflictRequiresExplicitRestart() async {
        for conflict in [false, true] {
            let store = GroupTestStore(), service = GroupTestService(), clock = GroupTestClock()
            let controller = await configured(store, service, clock); await prepare(controller, clock)
            var retired: [String] = []; controller.retireLocalDisplay = { retired.append($0) }
            await service.set(mode: .transientFailure)
            await controller.replacePushToken(Data([1]), sessionID: "group")
            clock.now = clock.now.addingTimeInterval(5*3600)
            await service.set(mode: conflict ? .conflict : .normal, now: clock.now)
            await controller.recover()
            XCTAssertTrue(retired.contains("group")); XCTAssertNil(store.journals["A"]?.groupID)
            XCTAssertEqual(controller.sessionStatus["group"], .restartRequired)
            XCTAssertFalse(controller.cleanupPending)
            let requests = await service.registrationRequests; XCTAssertEqual(requests.count, 2)
            await controller.recover()
            let after = await service.registrationRequests; XCTAssertEqual(after.count, 2, "Recovery must not create another group")
        }
    }
    func testLateRegisterAcknowledgementCannotEraseStoppedIntent() async throws {
        let store = GroupTestStore(), service = GroupTestService(), clock = GroupTestClock(), gate = GroupTestGate()
        let controller = await configured(store, service, clock); await prepare(controller, clock)
        await service.set(registerGate: gate)
        let register = Task { await controller.replacePushToken(Data([1]), sessionID: "group") }
        await gate.waitUntilEntered()
        controller.markStopped()
        let stop = Task { await controller.stop() }
        await gate.open(); await register.value; await stop.value
        XCTAssertNil(store.journals["A"]?.groupID); XCTAssertFalse(controller.cleanupPending)
        let state = try await service.displayState(); XCTAssertTrue(state.stopped)
    }
    func testRetiredScopeCleanupRetriesWithoutMutatingCurrentScopeAndFailedStoragePreventsCreate() async {
        let store = GroupTestStore(), a = GroupTestService(), b = GroupTestService(), clock = GroupTestClock()
        let controller = await configured(store, a, clock)
        await a.set(stopFails: true)
        await controller.configure(scope: "B", service: b, environment: .sandbox)
        XCTAssertTrue(controller.cleanupPending); XCTAssertTrue(controller.available)
        await a.set(); await controller.recover()
        XCTAssertFalse(controller.cleanupPending); XCTAssertEqual(store.journals["A"]?.displayRevision, 1)
        XCTAssertNil(store.journals["B"]?.groupID)
        store.failSave = true
        let prepared = await controller.prepare(.init(groupID: "group", windowIDs: ["A"], sourceDeviceID: "mac", sourceEpoch: "epoch", endsAt: clock.now.addingTimeInterval(600)))
        XCTAssertFalse(prepared); XCTAssertFalse(controller.available)
        let requests = await b.registrationRequests; XCTAssertTrue(requests.isEmpty)
    }
    func testCrashRecoveryGetBeforeDelayedCreateStillUsesDurableAbandonBarrier() async throws {
        let store = GroupTestStore(), service = GroupTestService(), clock = GroupTestClock(), gate = GroupTestGate()
        var interrupted = ActivityGroupJournal()
        interrupted.begin(groupID: "interrupted", windowIDs: ["A", "B"], sourceDeviceID: "mac", sourceEpoch: "epoch", endsAt: clock.now.addingTimeInterval(8*3600))
        interrupted.registration = .init(displayRevision: 0, registrationRevision: 0, tokenHash: "synthetic", preparedAt: clock.now)
        store.journals["A"] = interrupted
        await service.stageDelayedCreate(interrupted); await service.set(stopGate: gate)
        let controller = ActivityGroupRemoteController(store: store, clock: { clock.now })
        var retired: [String] = []; controller.retireLocalDisplay = { retired.append($0) }
        let configure = Task { await controller.configure(scope: "A", service: service, environment: .sandbox) }
        await gate.waitUntilEntered()
        XCTAssertTrue(store.journals["A"]!.pendingStop)
        XCTAssertEqual(store.journals["A"]?.fence?.expectedRevision, 0)
        let before = try await service.displayState(); XCTAssertNil(before.groupId)
        await service.commitDelayedCreate(); await gate.open(); await configure.value
        let after = try await service.displayState(); XCTAssertTrue(after.stopped); XCTAssertEqual(after.displayRevision, 2)
        XCTAssertTrue(retired.contains("interrupted")); XCTAssertFalse(controller.cleanupPending)
        let requests = await service.registrationRequests; XCTAssertTrue(requests.isEmpty, "Crash recovery may not replay create")
    }
    func testRapidDisableAndNewScopeConfigureWhileOldCapabilityIsSuspended() async {
        let store = GroupTestStore(), a = GroupTestService(), b = GroupTestService(), cap = GroupTestGate(), clock = GroupTestClock()
        await a.set(capGate: cap)
        let controller = ActivityGroupRemoteController(store: store, clock: { clock.now })
        let first = Task { await controller.configure(scope: "A", service: a, environment: .sandbox) }
        await cap.waitUntilEntered()
        let disableEntered = GroupTestGate()
        controller.onChange = { Task { await disableEntered.open() } }
        let disable = Task { await controller.disable() }
        await disableEntered.wait()
        let nextEntered = GroupTestGate()
        controller.onChange = { Task { await nextEntered.open() } }
        let next = Task { await controller.configure(scope: "B", service: b, environment: .sandbox) }
        await nextEntered.wait(); await cap.open()
        await first.value; await disable.value; await next.value
        XCTAssertTrue(controller.available)
        await prepare(controller, clock)
        await controller.replacePushToken(Data([1]), sessionID: "group")
        let aRequests = await a.registrationRequests, bRequests = await b.registrationRequests
        XCTAssertTrue(aRequests.isEmpty); XCTAssertEqual(bRequests.count, 1)
    }
    func testReenterRetiredScopeTransfersJournalOwnershipBeforeNewGroup() async throws {
        let store = GroupTestStore(), a = GroupTestService(), b = GroupTestService(), clock = GroupTestClock()
        let controller = await configured(store, a, clock)
        await a.set(stopFails: true)
        await controller.configure(scope: "B", service: b, environment: .sandbox)
        XCTAssertTrue(controller.cleanupPending)
        await a.set()
        await controller.configure(scope: "A", service: a, environment: .sandbox)
        XCTAssertFalse(controller.cleanupPending)
        await prepare(controller, clock)
        await controller.replacePushToken(Data([1]), sessionID: "group")
        let before = store.journals["A"]
        controller.existingToken = { _ in nil }
        await controller.recover()
        XCTAssertEqual(store.journals["A"], before)
        let state = try await a.displayState(); XCTAssertEqual(state.groupId, "group")
        XCTAssertFalse(controller.cleanupPending)
    }
    func testTransientCapabilityFailureRecoversKnownRegistrationWithoutReconfiguration() async {
        let store = GroupTestStore(), service = GroupTestService(), clock = GroupTestClock()
        let first = await configured(store, service, clock); await prepare(first, clock)
        await first.replacePushToken(Data([1]), sessionID: "group")
        let restored = ActivityGroupRemoteController(store: store, clock: { clock.now })
        restored.matchesLocalDisplay = { _ in true }; restored.existingToken = { _ in Data([1]) }
        await service.set(capFails: true)
        await restored.configure(scope: "A", service: service, environment: .sandbox)
        XCTAssertFalse(restored.available)
        await service.set()
        await restored.recover()
        XCTAssertTrue(restored.available)
        XCTAssertEqual(store.journals["A"]?.registrationRevision, 2)
        let requests = await service.registrationRequests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[1].registration?.expectedRegistrationRevision, 1)
    }
    func testFailedCapabilityRecoveryIsBoundedAndConfirmedUnsupportedIsNotRetried() async {
        let store = GroupTestStore(), service = GroupTestService(), clock = GroupTestClock()
        await service.set(capFails: true)
        let controller = ActivityGroupRemoteController(store: store, clock: { clock.now })
        await controller.configure(scope: "A", service: service, environment: .sandbox)
        await controller.recover(); await controller.recover()
        let firstCount = await service.capCount; XCTAssertEqual(firstCount, 2)
        clock.now = clock.now.addingTimeInterval(31)
        await controller.recover()
        let retryCount = await service.capCount; XCTAssertEqual(retryCount, 3)
        await service.set(supported: false)
        await controller.configure(scope: "A", service: service, environment: .sandbox)
        clock.now = clock.now.addingTimeInterval(60); await controller.recover()
        let finalCount = await service.capCount; XCTAssertEqual(finalCount, 4)
        XCTAssertFalse(controller.available)
    }
    func testDisabledRelaunchRestoresFailedFenceWithoutCapabilitiesOrRegistration() async throws {
        let store = GroupTestStore(), service = GroupTestService(), clock = GroupTestClock()
        let original = await configured(store, service, clock); await prepare(original, clock)
        await original.replacePushToken(Data([1]), sessionID: "group")
        await service.set(stopFails: true)
        await original.disable()
        XCTAssertTrue(store.journals["A"]!.pendingStop)
        let restored = ActivityGroupRemoteController(store: store, clock: { clock.now })
        await restored.restoreCleanup(scope: "A", service: service)
        XCTAssertTrue(restored.cleanupPending); XCTAssertFalse(restored.available)
        let capCount = await service.capCount, requestCount = await service.registrationRequests.count
        await service.set()
        await restored.recover()
        XCTAssertFalse(restored.cleanupPending); XCTAssertFalse(restored.available)
        XCTAssertFalse(store.journals["A"]!.pendingStop)
        let state = try await service.displayState(); XCTAssertTrue(state.stopped); XCTAssertNil(state.groupId)
        let finalCaps = await service.capCount, finalRequests = await service.registrationRequests.count
        XCTAssertEqual(finalCaps, capCount); XCTAssertEqual(finalRequests, requestCount)
    }
    func testDisabledEmptyScopeRestorationMakesNoUnsupportedWorkerRequests() async {
        let store = GroupTestStore(), service = GroupTestService()
        let controller = ActivityGroupRemoteController(store: store)
        await controller.restoreCleanup(scope: "A", service: service)
        await controller.recover()
        let caps = await service.capCount, stops = await service.stopCount, registrations = await service.registrationRequests
        XCTAssertEqual(caps, 0); XCTAssertEqual(stops, 0); XCTAssertTrue(registrations.isEmpty)
        XCTAssertFalse(controller.available); XCTAssertFalse(controller.cleanupPending)
    }

}
