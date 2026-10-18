import XCTest
import QuotaPhone

private actor PhoneTransportTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var began = false
    private var opened = false
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        began = true; started?.resume(); started = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func untilStarted() async {
        if began { return }; await withCheckedContinuation { started = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
@MainActor
final class PhoneActivityTransportTests: XCTestCase {
    func testOffInvalidatesGroupBeforeSuspendedLegacyEnableCanConfigureIt() async {
        let gate = PhoneTransportTestGate()
        var enabled = true, generation = 1, groupAvailable = true, legacyAvailable = true, groupConfigurations = 0
        let ticket = generation
        let configure = Task {
            await PhoneActivityTransportPolicy.configure(isCurrent: { enabled && generation == ticket },
                legacy: { await gate.wait() }, group: { groupConfigurations += 1; groupAvailable = true })
        }
        await gate.untilStarted()
        enabled = false; generation += 1
        PhoneActivityTransportPolicy.preferenceChanged(enabled: enabled,
            invalidateGroup: { groupAvailable = false }, invalidateLegacy: { legacyAvailable = false })
        XCTAssertFalse(groupAvailable); XCTAssertFalse(legacyAvailable)
        await gate.open()
        let configured = await configure.value
        XCTAssertFalse(configured); XCTAssertEqual(groupConfigurations, 0)
    }
    func testRapidOffOnRejectsOldEnableTicketAndAllowsOnlyCurrentOne() async {
        let gate = PhoneTransportTestGate()
        var enabled = true, generation = 1, groups: [Int] = []
        let old = generation
        let first = Task {
            await PhoneActivityTransportPolicy.configure(isCurrent: { enabled && generation == old },
                legacy: { await gate.wait() }, group: { groups.append(old) })
        }
        await gate.untilStarted()
        enabled = false; generation += 1
        PhoneActivityTransportPolicy.preferenceChanged(enabled: enabled, invalidateGroup: {}, invalidateLegacy: {})
        enabled = true; generation += 1
        let current = generation
        await gate.open()
        let oldAccepted = await first.value; XCTAssertFalse(oldAccepted)
        let currentAccepted = await PhoneActivityTransportPolicy.configure(isCurrent: { enabled && generation == current },
            legacy: {}, group: { groups.append(current) })
        XCTAssertTrue(currentAccepted); XCTAssertEqual(groups, [3])
    }
    func testObsoleteDisableContinuationCannotDisableNewLegacyConfiguration() async {
        let gate = PhoneTransportTestGate()
        var enabled = false, generation = 2, legacyDisableCount = 0
        let ticket = generation
        let disable = Task {
            await PhoneActivityTransportPolicy.disable(isCurrent: { !enabled && generation == ticket },
                group: { await gate.wait() }, legacy: { legacyDisableCount += 1 })
        }
        await gate.untilStarted()
        enabled = true; generation += 1
        await gate.open(); await disable.value
        XCTAssertEqual(legacyDisableCount, 0)
    }
    func testActualRegistrationQueueChecksHostIdentityAfterPredecessorWait() async {
        let predecessorGate = PhoneTransportTestGate(), queuedGate = PhoneTransportTestGate()
        var current = true, requests = 0
        let predecessor = Task { await predecessorGate.wait(); return true }
        await predecessorGate.untilStarted()
        let queued = Task {
            await LegacyActivityRegistrationPolicy.submit(after: [predecessor],
                isCurrent: { Task { await queuedGate.open() }; return current },
                request: { requests += 1; return true })
        }
        // The first predicate signals entry; the predecessor is still suspended.
        await queuedGate.wait()
        current = false
        await predecessorGate.open()
        let accepted = await queued.value
        XCTAssertFalse(accepted); XCTAssertEqual(requests, 0)
    }
    func testActualRegistrationQueueChecksStopSeparatelyFromSourceGeneration() async {
        let predecessorGate = PhoneTransportTestGate(), queuedGate = PhoneTransportTestGate()
        var stopped = false, requests = 0
        let unchangedGeneration = 7
        let predecessor = Task { await predecessorGate.wait(); return true }
        await predecessorGate.untilStarted()
        let queued = Task {
            await LegacyActivityRegistrationPolicy.submit(after: [predecessor],
                isCurrent: { Task { await queuedGate.open() }; return unchangedGeneration == 7 && !stopped },
                request: { requests += 1; return true })
        }
        await queuedGate.wait(); stopped = true; await predecessorGate.open()
        let accepted = await queued.value
        XCTAssertFalse(accepted); XCTAssertEqual(requests, 0)
    }
    func testActualRegistrationQueueSubmitsValidRequestOnlyAfterPredecessor() async {
        let predecessorGate = PhoneTransportTestGate(), queuedGate = PhoneTransportTestGate()
        var requests = 0
        let predecessor = Task { await predecessorGate.wait(); return true }
        await predecessorGate.untilStarted()
        let queued = Task {
            await LegacyActivityRegistrationPolicy.submit(after: [predecessor],
                isCurrent: { Task { await queuedGate.open() }; return true },
                request: { requests += 1; return true })
        }
        await queuedGate.wait(); XCTAssertEqual(requests, 0); await predecessorGate.open()
        let accepted = await queued.value
        XCTAssertTrue(accepted); XCTAssertEqual(requests, 1)
    }

    func testAcceptedGenerationRefreshRejectsOldQueueButAllowsNewPreparation() async throws {
        let binding = LegacyActivitySourceBinding(), predecessorGate = PhoneTransportTestGate(), queuedGate = PhoneTransportTestGate()
        var hostGeneration = 1, requests = 0
        let configuredGeneration = hostGeneration
        binding.configure(scope: "CF", isCurrent: { _ in hostGeneration == configuredGeneration })
        let oldSource = try XCTUnwrap(binding.capture(windowID: "window"))
        let predecessor = Task { await predecessorGate.wait(); return true }
        await predecessorGate.untilStarted()
        let oldQueued = Task {
            await LegacyActivityRegistrationPolicy.submit(after: [predecessor],
                isCurrent: { Task { await queuedGate.open() }; return oldSource() },
                request: { requests += 1; return true })
        }
        await queuedGate.wait()
        // iCloud preference/account event changes Host generation; CF remains selected.
        hostGeneration = 2
        let acceptedGeneration = hostGeneration
        XCTAssertTrue(binding.refresh(scope: "CF", isCurrent: { _ in hostGeneration == acceptedGeneration }))
        let newSource = try XCTUnwrap(binding.capture(windowID: "window"))
        await predecessorGate.open()
        let oldAccepted = await oldQueued.value; XCTAssertFalse(oldAccepted)
        XCTAssertEqual(requests, 0)
        let newAccepted = await LegacyActivityRegistrationPolicy.submit(after: [],
            isCurrent: newSource, request: { requests += 1; return true })
        XCTAssertTrue(newAccepted); XCTAssertEqual(requests, 1)
    }
    func testSourcePredicateRefreshCannotAttachNewScopeToOldClientBinding() {
        let binding = LegacyActivitySourceBinding()
        binding.configure(scope: "A", isCurrent: { _ in false })
        XCTAssertFalse(binding.refresh(scope: "B", isCurrent: { _ in true }))
        XCTAssertNil(binding.capture(windowID: "window"))
        binding.configure(scope: "B", isCurrent: { _ in true })
        XCTAssertNotNil(binding.capture(windowID: "window"))
    }

}
