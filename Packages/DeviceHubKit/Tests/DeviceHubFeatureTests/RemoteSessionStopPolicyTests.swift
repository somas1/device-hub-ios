import ComposableArchitecture
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Sticky Stop Viewing")
struct RemoteSessionStopPolicyTests {
    @Test("Roster loss and return do not authorize viewing", arguments: [false, true])
    func rosterLossAndReturn(durableResponse: Bool) async {
        let target = device(id: "stopped", name: "Synthetic target")
        let probe = StopConnectionProbe()
        let store = stoppedStore(target: target, probe: probe)
        await store.send(snapshot([], durableResponse: durableResponse))
        #expect(store.state.isViewingStopped)
        #expect(store.state.selectedDeviceID == nil)
        #expect(store.state.toolbarPresentation == .noSelection)
        await store.send(snapshot([target], durableResponse: durableResponse))
        await assertStopped(store, probe: probe)
        #expect(store.state.selectedDeviceID == target.id)
    }

    @Test("Automatic replacement remains stopped", arguments: [false, true])
    func automaticReplacement(reachable: Bool) async {
        let target = device(id: "stopped", name: "Synthetic target")
        let replacement = device(id: "other", name: "Other target", reachability: reachable ? .reachable : .unavailable)
        let probe = StopConnectionProbe()
        let store = stoppedStore(target: target, probe: probe)
        await store.send(.availabilitySnapshotReceived([replacement]))
        await assertStopped(store, probe: probe)
        #expect(store.state.selectedDeviceID == (reachable ? replacement.id : nil))
    }

    @Test("Selection pairing and Retry do not authorize Start", arguments: ["same", "other", "paired", "retry"])
    func explicitNonStartIntent(intent: String) async {
        let target = device(id: "stopped", name: "Synthetic target")
        let other = device(id: "other", name: "Other target")
        let probe = StopConnectionProbe()
        let store = makeStore(state: RemoteSessionFeature.State(
            isViewingStopped: true,
            pairing: intent == "paired" ? PairingFeature.State() : nil,
            roster: DeviceRoster(devices: [target, other]), selectedDeviceID: target.id
        ), probe: probe)
        switch intent {
        case "same": await store.send(.deviceSelected(target.id))
        case "other": await store.send(.deviceSelected(other.id))
        case "paired": await store.send(.pairing(.presented(.delegate(.paired(other)))))
        default: await store.send(.retrySelectedDevice)
        }
        await assertStopped(store, probe: probe)
    }

    @Test("A rejected Start preserves Stop", arguments: ["pending", "failed", "no-device", "inactive", "pairing"])
    func rejectedStart(reason: String) async {
        var target = device(id: "stopped", name: "Synthetic target")
        if reason == "pairing" {
            target.pairingState = .requiresPairing
        }
        var state = RemoteSessionFeature.State(
            isViewingStopped: true,
            lifecycle: reason == "inactive" ? .inactive : .active,
            roster: DeviceRoster(devices: reason == "no-device" ? [] : [target]),
            selectedDeviceID: reason == "no-device" ? nil : target.id
        )
        if reason == "pending" {
            state.pendingInputCleanup = InputCleanupOwnership(session: ActiveRemoteSession(
                attemptID: fixtureUUID(80), device: target, evaluatedAt: Date(timeIntervalSince1970: 5000)
            ), resumeViewing: true)
        }
        if reason == "failed" {
            state.inputCleanupFailed = true
            state.remediation = DeviceHubRemediation(error: .inputCleanupFailed)
        }
        let probe = StopConnectionProbe()
        let store = makeStore(state: state, probe: probe)
        let pending = state.pendingInputCleanup
        await store.send(.startViewingButtonTapped)
        await assertStopped(store, probe: probe)
        #expect(store.state.pendingInputCleanup == pending)
        #expect(store.state.inputCleanupFailed == (reason == "failed"))
        if reason == "failed" {
            #expect(store.state.remediation?.error == .inputCleanupFailed)
        }
    }

    @Test("Reachability and foreground do not authorize viewing")
    func availabilityAndForeground() async {
        let target = device(id: "stopped", name: "Synthetic target")
        let offline = device(id: "stopped", name: "Synthetic target", reachability: .unavailable)
        let probe = StopConnectionProbe()
        let store = stoppedStore(target: target, probe: probe)
        for value in [offline, target, target, offline, target] {
            await store.send(.availabilitySnapshotReceived([value]))
            #expect(store.state.isViewingStopped)
        }
        await store.send(.appLifecycleChanged(.background))
        await store.send(.appLifecycleChanged(.active))
        await assertStopped(store, probe: probe)
    }

    @Test("Stop wins over pending automatic resume", arguments: [false, true])
    func stopWinsOverCleanup(failure: Bool) async {
        let target = device(id: "stopped", name: "Synthetic target")
        let old = ActiveRemoteSession(attemptID: fixtureUUID(80), device: target, evaluatedAt: Date(timeIntervalSince1970: 5000))
        var state = RemoteSessionFeature.State(roster: DeviceRoster(devices: [target]), selectedDeviceID: target.id)
        state.pendingInputCleanup = InputCleanupOwnership(session: old, resumeViewing: true)
        let probe = StopConnectionProbe()
        let store = makeStore(state: state, probe: probe)
        await store.send(.stopViewingButtonTapped)
        if failure {
            await store.send(.inputCleanupFailed(attemptID: old.attemptID, sessionID: nil, error: .inputCleanupFailed))
        } else {
            await store.send(.inputCleanupFinished(attemptID: old.attemptID, sessionID: nil))
        }
        await assertStopped(store, probe: probe)
        #expect(store.state.pendingInputCleanup == nil)
        #expect(store.state.inputCleanupFailed == failure)
    }

    @Test("Successful cleanup resumes without a deferred user Start")
    func cleanupResumesAtOwnerBoundary() async {
        let target = device(id: "stopped", name: "Synthetic target")
        let old = ActiveRemoteSession(attemptID: fixtureUUID(80), device: target, evaluatedAt: Date(timeIntervalSince1970: 5000))
        var state = RemoteSessionFeature.State(roster: DeviceRoster(devices: [target]), selectedDeviceID: target.id)
        state.pendingInputCleanup = InputCleanupOwnership(session: old, resumeViewing: true)
        let probe = StopConnectionProbe()
        let store = makeStore(state: state, probe: probe)
        await store.send(.inputCleanupFinished(attemptID: old.attemptID, sessionID: nil))
        #expect(store.state.pendingInputCleanup == nil)
        #expect(store.state.session?.attemptID == fixtureUUID(81))
        await store.finish()
        #expect(await probe.connections() == [target.id])
        await store.send(.stopViewingButtonTapped)
        await store.finish()
        #expect(store.state.isViewingStopped)
        #expect(store.state.session == nil)
    }

    @Test("Explicit Start authorizes one fresh connection", arguments: [false, true])
    func acceptedStart(reachable: Bool) async {
        let target = device(id: "stopped", name: "Synthetic target", reachability: reachable ? .reachable : .unavailable)
        let probe = StopConnectionProbe()
        let store = stoppedStore(target: target, probe: probe)
        await store.send(.startViewingButtonTapped)
        #expect(!store.state.isViewingStopped)
        #expect(!store.state.acceptsInput)
        if !reachable {
            #expect(store.state.session == nil)
            #expect(await probe.connections().isEmpty)
            let online = device(id: "stopped", name: "Synthetic target")
            await store.send(.availabilitySnapshotReceived([online]))
        }
        #expect(store.state.session?.attemptID == fixtureUUID(81))
        await store.finish()
        #expect(await probe.connections() == [target.id])
        #expect(store.state.activeContactIDs.isEmpty)
        #expect(!store.state.acceptsInput)
    }

    @Test("Explicit cleanup Retry does not override Stop")
    func cleanupRetryStaysStopped() async {
        let target = device(id: "stopped", name: "Synthetic target")
        var state = RemoteSessionFeature.State(
            isViewingStopped: true, remediation: DeviceHubRemediation(error: .inputCleanupFailed),
            roster: DeviceRoster(devices: [target]), selectedDeviceID: target.id
        )
        state.inputCleanupFailed = true
        let probe = StopConnectionProbe()
        let store = makeStore(state: state, probe: probe)
        await store.send(.remediationButtonTapped)
        await store.receive(\.retrySelectedDevice)
        await assertStopped(store, probe: probe)
        #expect(!store.state.inputCleanupFailed)
        #expect(store.state.remediation == nil)
        await store.send(.startViewingButtonTapped)
        await store.finish()
        #expect(!store.state.isViewingStopped)
        #expect(await probe.connections() == [target.id])
    }

    private func snapshot(_ devices: [DeviceSummary], durableResponse: Bool) -> RemoteSessionFeature.Action {
        durableResponse ? .pairedDevicesResponse(.success(devices)) : .availabilitySnapshotReceived(devices)
    }

    private func stoppedStore(target: DeviceSummary, others: [DeviceSummary] = [], probe: StopConnectionProbe) -> TestStoreOf<RemoteSessionFeature> {
        makeStore(state: RemoteSessionFeature.State(
            isViewingStopped: true, roster: DeviceRoster(devices: [target] + others), selectedDeviceID: target.id
        ), probe: probe)
    }

    private func makeStore(state: RemoteSessionFeature.State, probe: StopConnectionProbe) -> TestStoreOf<RemoteSessionFeature> {
        let devices = state.roster.devices
        let store = TestStore(initialState: state) { RemoteSessionFeature() } withDependencies: {
            $0.date.now = Date(timeIntervalSince1970: 5000)
            $0.uuid = .constant(fixtureUUID(81))
            $0.deviceHub.pairedDevices = { devices }
            $0.deviceHub.availability = { AsyncStream { $0.finish() } }
            $0.deviceHub.connect = { id in
                await probe.record(id)
                throw DeviceHubError.deviceOffline
            }
        }
        // RED can start an unexpected connection; drain its finite synthetic failure
        // rather than waiting for absent expected actions. Assert the full stop contract below.
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    private func assertStopped(_ store: TestStoreOf<RemoteSessionFeature>, probe: StopConnectionProbe) async {
        await store.finish()
        #expect(store.state.isViewingStopped)
        #expect(store.state.session == nil)
        #expect(!store.state.acceptsInput)
        #expect(store.state.activeContactIDs.isEmpty)
        #expect(await probe.connections().isEmpty)
    }
}

private actor StopConnectionProbe {
    private var deviceIDs: [DeviceID] = []

    func record(_ id: DeviceID) {
        deviceIDs.append(id)
    }

    func connections() -> [DeviceID] {
        deviceIDs
    }
}
