import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote session return from inactive")
struct RemoteSessionReturnTests {
    private let time = Date(timeIntervalSince1970: 5000)
    private let attemptID = fixtureUUID(81)
    private let reachable = device(id: "return", name: "Synthetic device")
    private let unavailable = device(id: "return", name: "Synthetic device", reachability: .unavailable)

    @Test("A reachable snapshot received while inactive connects on return")
    func reachableOnReturn() async {
        let stream = AsyncStream<[DeviceSummary]>.makeStream()
        let store = makeStore(RemoteSessionFeature.State()) {
            $0.deviceHub.pairedDevices = { [unavailable] }
            $0.deviceHub.availability = { stream.stream }
        }
        await store.send(.task) {
            $0.isLoadingRoster = true
        }
        await store.receive(\.pairedDevicesResponse) {
            $0.isLoadingRoster = false
            $0.isObservingAvailability = true
            $0.roster = DeviceRoster(devices: [unavailable])
        }
        await store.send(.appLifecycleChanged(.inactive)) {
            $0.lifecycle = .inactive
        }
        stream.continuation.yield([reachable])
        await store.receive(\.availabilitySnapshotReceived) {
            $0.roster = DeviceRoster(devices: [reachable])
            $0.selectedDeviceID = reachable.id
        }
        await store.send(.appLifecycleChanged(.active)) {
            $0.lifecycle = .active
            $0.session = connectingSession
        }
        await store.receive(\.connectionResponse) {
            $0.session?.connectionError = .deviceOffline
            $0.remediation = DeviceHubRemediation(error: .deviceOffline)
        }
        stream.continuation.yield([reachable])
        await store.receive(\.availabilitySnapshotReceived)
        stream.continuation.finish()
        await store.receive(\.availabilityObservationFinished) {
            $0.isObservingAvailability = false
        }
    }

    @Test("An unavailable target keeps its remediation until the next reachable snapshot")
    func unavailableOnReturn() async {
        let remediation = DeviceHubRemediation(error: .connectionLost)
        let store = makeStore(RemoteSessionFeature.State(
            isObservingAvailability: true,
            lifecycle: .inactive,
            remediation: remediation,
            roster: DeviceRoster(devices: [unavailable]),
            selectedDeviceID: unavailable.id
        ))
        await store.send(.appLifecycleChanged(.active)) {
            $0.lifecycle = .active
        }
        #expect(store.state.remediation == remediation)
        #expect(store.state.session == nil)
        await store.send(.availabilitySnapshotReceived([reachable])) {
            $0.roster = DeviceRoster(devices: [reachable])
            $0.remediation = nil
            $0.session = connectingSession
        }
        await store.receive(\.connectionResponse) {
            $0.session?.connectionError = .deviceOffline
            $0.remediation = DeviceHubRemediation(error: .deviceOffline)
        }
    }

    @Test("A reachable target stays stopped on return")
    func stoppedOnReturn() async {
        let store = makeStore(RemoteSessionFeature.State(
            isObservingAvailability: true,
            roster: DeviceRoster(devices: [unavailable]),
            selectedDeviceID: unavailable.id
        ))
        await store.send(.stopViewingButtonTapped) {
            $0.isViewingStopped = true
        }
        await store.send(.appLifecycleChanged(.inactive)) {
            $0.lifecycle = .inactive
        }
        await store.send(.availabilitySnapshotReceived([reachable])) {
            $0.roster = DeviceRoster(devices: [reachable])
        }
        await store.send(.appLifecycleChanged(.active)) {
            $0.lifecycle = .active
        }
        await store.finish()
        #expect(store.state.isViewingStopped)
        #expect(store.state.session == nil)
    }

    @Test("Returning with a live session keeps it")
    func liveSessionOnReturn() async throws {
        let session = try connectedSession(device: reachable, receivedAt: time)
        let store = makeStore(RemoteSessionFeature.State(
            isObservingAvailability: true,
            lifecycle: .inactive,
            roster: DeviceRoster(devices: [reachable]),
            selectedDeviceID: reachable.id,
            session: session
        ))
        await store.send(.appLifecycleChanged(.active)) {
            $0.lifecycle = .active
        }
        await store.finish()
        #expect(store.state.session == session)
    }

    @Test("Returning after availability ends reloads the roster")
    func endedObservationOnReturn() async {
        let store = makeStore(RemoteSessionFeature.State(
            isObservingAvailability: true,
            lifecycle: .inactive
        )) {
            $0.deviceHub.pairedDevices = { [unavailable] }
            $0.deviceHub.availability = { AsyncStream { $0.finish() } }
        }
        await store.send(.availabilityObservationFinished) {
            $0.isObservingAvailability = false
        }
        await store.send(.appLifecycleChanged(.active)) {
            $0.lifecycle = .active
        }
        await store.receive(\.task) {
            $0.isLoadingRoster = true
        }
        await store.receive(\.pairedDevicesResponse) {
            $0.isLoadingRoster = false
            $0.isObservingAvailability = true
            $0.roster = DeviceRoster(devices: [unavailable])
        }
        await store.receive(\.availabilityObservationFinished) {
            $0.isObservingAvailability = false
        }
    }

    private var connectingSession: ActiveRemoteSession {
        ActiveRemoteSession(attemptID: attemptID, device: reachable, evaluatedAt: time)
    }

    private func makeStore(
        _ state: RemoteSessionFeature.State,
        withDependencies update: (inout DependencyValues) -> Void = { _ in }
    ) -> TestStoreOf<RemoteSessionFeature> {
        TestStore(initialState: state) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.date.now = time
            $0.uuid = .constant(attemptID)
            $0.deviceHub.connect = { _ in throw DeviceHubError.deviceOffline }
            update(&$0)
        }
    }
}
