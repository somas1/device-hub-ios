import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

/// Once a session ends, nothing still in flight from it may clear its
/// terminal error or re-enable input, and its cleanup outcome still counts.
@MainActor
@Suite("Ended session identity")
struct RemoteSessionEndedIdentityTests {
    @Test("A late frame after the stream fails cannot clear the failure")
    func lateFrameAfterStreamFailure() async throws {
        let (store, active) = try makeStore()
        let sessionID = try #require(active.sessionID)
        await store.send(.sessionStreamFailed(attemptID: active.attemptID, sessionID: sessionID, error: .connectionLost))
        await store.receive(\.inputCleanupFinished)

        try await sendLateFrame(to: store, from: active, sequenceNumber: 2)

        expectTerminalFailureKept(store, error: .connectionLost)
    }

    @Test("A late frame after the event stream finishes cannot clear the failure")
    func lateFrameAfterEventsFinished() async throws {
        let (store, active) = try makeStore()
        let sessionID = try #require(active.sessionID)
        await store.send(.sessionEventsFinished(attemptID: active.attemptID, sessionID: sessionID))
        await store.receive(\.inputCleanupFinished)

        try await sendLateFrame(to: store, from: active, sequenceNumber: 2)

        expectTerminalFailureKept(store, error: .connectionLost)
    }

    @Test("A repeated frame after an ending update cannot clear the failure")
    func repeatedFrameAfterEndingUpdate() async throws {
        let (store, active) = try makeStore()
        let sessionID = try #require(active.sessionID)
        let generation = try #require(active.remoteState?.generation)
        await store.send(.sessionUpdateReceived(
            attemptID: active.attemptID, sessionID: sessionID,
            update: SessionUpdate(generation: generation, event: .ended(.connectionLost))
        ))
        await store.receive(\.inputCleanupFinished)

        try await sendLateFrame(to: store, from: active, sequenceNumber: 1)

        expectTerminalFailureKept(store, error: .connectionLost)
    }

    @Test("A cleanup failure after the stream fails is still reported")
    func cleanupFailureAfterStreamFailureIsReported() async throws {
        let device = device(id: "device", name: "Test iPhone")
        let time = Date(timeIntervalSince1970: 5200)
        let active = try connectedSession(device: device, receivedAt: time)
        let sessionID = try #require(active.sessionID)
        let feature = RemoteSessionFeature()
        let transport = DeviceSession(
            id: sessionID, device: device,
            events: AsyncThrowingStream { _ in }, frames: AsyncStream { _ in },
            command: { _ in throw DeviceHubError.secureConnectionFailed }, disconnect: {}
        )
        var client = DeviceHubClient()
        client.connect = { _ in transport }
        _ = try await feature.sessionCoordinator.replace(
            attemptID: active.attemptID, deviceID: device.id, using: client
        )
        let store = TestStore(initialState: RemoteSessionFeature.State(
            roster: DeviceRoster(devices: [device]), selectedDeviceID: device.id, session: active
        )) { feature } withDependencies: { $0.date.now = time }
        store.exhaustivity = .off

        await store.send(.sessionStreamFailed(attemptID: active.attemptID, sessionID: sessionID, error: .connectionLost))
        await store.receive(\.inputCleanupFailed)

        #expect(store.state.inputCleanupFailed)
        #expect(store.state.remediation == DeviceHubRemediation(error: .inputCleanupFailed))
        #expect(!store.state.acceptsInput)
    }

    private func makeStore() throws -> (TestStoreOf<RemoteSessionFeature>, ActiveRemoteSession) {
        let device = device(id: "device", name: "Test iPhone")
        let time = Date(timeIntervalSince1970: 5100)
        let active = try connectedSession(device: device, receivedAt: time)
        let store = TestStore(initialState: RemoteSessionFeature.State(
            roster: DeviceRoster(devices: [device]), selectedDeviceID: device.id, session: active
        )) { RemoteSessionFeature() } withDependencies: { $0.date.now = time }
        store.exhaustivity = .off
        return (store, active)
    }

    private func sendLateFrame(
        to store: TestStoreOf<RemoteSessionFeature>,
        from active: ActiveRemoteSession,
        sequenceNumber: UInt64
    ) async throws {
        let sessionID = try #require(active.sessionID)
        let generation = try #require(active.remoteState?.generation)
        let frame = try remoteFrame(
            generation: generation,
            receivedAt: Date(timeIntervalSince1970: 5100),
            sequenceNumber: sequenceNumber
        )
        await store.send(.frameReceived(attemptID: active.attemptID, sessionID: sessionID, frame: frame))
    }

    private func expectTerminalFailureKept(
        _ store: TestStoreOf<RemoteSessionFeature>,
        error: DeviceHubError
    ) {
        #expect(store.state.session?.connectionError == error)
        #expect(store.state.remediation == DeviceHubRemediation(error: error))
        #expect(!store.state.acceptsInput)
    }
}
