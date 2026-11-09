import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote cleanup recovery")
struct RemoteSessionCleanupOutcomeTests {
    @Test("Background close retains its removed session's failure")
    func backgroundFailureRetained() async throws {
        let device = device(id: "cleanup", name: "Synthetic device")
        let time = Date(timeIntervalSince1970: 5000)
        let active = try connectedSession(device: device, receivedAt: time)
        let feature = RemoteSessionFeature()
        let coordinator = feature.sessionCoordinator
        let transport = try DeviceSession(
            id: #require(active.sessionID), device: device,
            events: AsyncThrowingStream { _ in }, frames: AsyncStream { _ in },
            command: { _ in throw DeviceHubError.inputCleanupFailed }, disconnect: {}
        )
        var client = DeviceHubClient()
        client.connect = { _ in transport }
        _ = try await coordinator.replace(attemptID: active.attemptID, deviceID: device.id, using: client)
        let store = TestStore(initialState: RemoteSessionFeature.State(
            activeContactIDs: [7], roster: DeviceRoster(devices: [device]),
            selectedDeviceID: device.id, session: active
        )) { feature }
        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.activeContactIDs = []
            $0.pendingInputCleanup = InputCleanupOwnership(session: active)
            $0.session = nil
        }
        await store.receive(\.inputCleanupFailed) {
            $0.pendingInputCleanup = nil
            $0.inputCleanupFailed = true
            $0.remediation = DeviceHubRemediation(error: .inputCleanupFailed)
        }
        #expect(store.state.session == nil)
        #expect(store.state.activeContactIDs.isEmpty)
        #expect(store.state.remediation != nil)
        #expect(!store.state.acceptsInput)
        #expect(store.state.sessionPresentation != nil)
    }

    @Test("A connection cleanup failure cannot be restarted implicitly")
    func failedReplacementLatchesRecovery() async {
        let device = device(id: "cleanup", name: "Synthetic device")
        let time = Date(timeIntervalSince1970: 5000)
        let active = ActiveRemoteSession(attemptID: fixtureUUID(93), device: device, evaluatedAt: time)
        let store = TestStore(initialState: RemoteSessionFeature.State(
            roster: DeviceRoster(devices: [device]), selectedDeviceID: device.id, session: active
        )) { RemoteSessionFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.connectionResponse(attemptID: active.attemptID, deviceID: device.id, result: .failure(.inputCleanupFailed)))
        await store.receive(\.inputCleanupFailed)
        await store.receive(\.inputCleanupFinished)
        await store.finish()
        #expect(store.state.inputCleanupFailed)
        #expect(store.state.session == nil)
        await store.send(.startViewingButtonTapped)
        #expect(store.state.session == nil)
        #expect(store.state.remediation?.error == .inputCleanupFailed)
    }

    @Test("Cleanup remediation outlives unrelated roster errors and in-flight Retry")
    func cleanupRemediationCannotDisappear() async throws {
        let device = device(id: "cleanup", name: "Synthetic device")
        let active = try connectedSession(device: device, receivedAt: Date(timeIntervalSince1970: 5000))
        var state = RemoteSessionFeature.State(
            remediation: DeviceHubRemediation(error: .inputCleanupFailed),
            roster: DeviceRoster(devices: [device]), selectedDeviceID: device.id
        )
        state.inputCleanupFailed = true
        state.pendingInputCleanup = InputCleanupOwnership(session: active)
        let store = TestStore(initialState: state) { RemoteSessionFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.pairedDevicesResponse(.failure(.deviceOffline)))
        #expect(store.state.remediation?.error == .inputCleanupFailed)
        await store.send(.remediationButtonTapped)
        #expect(store.state.remediation?.error == .inputCleanupFailed)
        #expect(store.state.inputCleanupFailed)
    }

    @Test("A superseded cleanup owner cannot fail a replacement session")
    func supersededCleanupIsIgnored() async throws {
        let device = device(id: "cleanup", name: "Synthetic device")
        let old = try connectedSession(device: device, receivedAt: Date(timeIntervalSince1970: 5000))
        var successor = ActiveRemoteSession(attemptID: fixtureUUID(95), device: device, evaluatedAt: old.evaluatedAt)
        successor.sessionID = DeviceSessionID(rawValue: fixtureUUID(96))
        var state = RemoteSessionFeature.State(
            roster: DeviceRoster(devices: [device]), selectedDeviceID: device.id, session: successor
        )
        state.pendingInputCleanup = InputCleanupOwnership(session: old)
        let store = TestStore(initialState: state) { RemoteSessionFeature() }
        await store.send(.inputCleanupFailed(attemptID: old.attemptID, sessionID: old.sessionID, error: .inputCleanupFailed))
        #expect(store.state.session == successor)
        #expect(!store.state.inputCleanupFailed)
    }

    @Test("Foreground waits for successful pending cleanup before reconnecting")
    func foregroundWaitsForCleanup() async throws {
        let device = device(id: "cleanup", name: "Synthetic device")
        let time = Date(timeIntervalSince1970: 5000)
        let old = try connectedSession(device: device, receivedAt: time)
        let attemptID = fixtureUUID(99)
        let clock = TestClock()
        var state = RemoteSessionFeature.State(
            lifecycle: .background,
            roster: DeviceRoster(devices: [device]),
            selectedDeviceID: device.id
        )
        state.pendingInputCleanup = InputCleanupOwnership(session: old)
        let store = TestStore(initialState: state) { RemoteSessionFeature() } withDependencies: {
            $0.date.now = time
            $0.uuid = .constant(attemptID)
            $0.continuousClock = clock
            $0.deviceHub.pairedDevices = { [device] }
            $0.deviceHub.availability = { AsyncStream { $0.finish() } }
            $0.deviceHub.connect = { _ in
                try await clock.sleep(for: .seconds(3600))
                throw DeviceHubError.deviceOffline
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.appLifecycleChanged(.active))
        await store.receive(\.pairedDevicesResponse)
        #expect(store.state.session == nil)
        await store.send(.inputCleanupFinished(attemptID: old.attemptID, sessionID: old.sessionID))
        // Avoid waiting for an absent effect in RED while asserting the resume intent.
        #expect(store.state.pendingInputCleanup == nil)
        await store.send(.detailsDismissed)
        #expect(store.state.session?.attemptID == attemptID)
        await store.send(.stopViewingButtonTapped)
        await store.finish()
    }

    @Test("Only explicit Retry creates fresh ownership without replaying input")
    func explicitRetryDoesNotReplay() async throws {
        let time = Date(timeIntervalSince1970: 5000)
        let device = device(id: "cleanup", name: "Synthetic device")
        let old = try connectedSession(device: device, receivedAt: time)
        let feature = RemoteSessionFeature()
        var oldClient = DeviceHubClient()
        oldClient.connect = { _ in
            DeviceSession(
                id: DeviceSessionID(rawValue: fixtureUUID(12)),
                device: device,
                events: AsyncThrowingStream { _ in },
                frames: AsyncStream { _ in },
                command: { _ in throw DeviceHubError.inputCleanupFailed },
                disconnect: {}
            )
        }
        _ = try await feature.sessionCoordinator.replace(attemptID: old.attemptID, deviceID: device.id, using: oldClient)
        do { try await feature.sessionCoordinator.close(attemptID: old.attemptID); Issue.record("Cleanup unexpectedly succeeded") } catch {}
        let freshID = DeviceSessionID(rawValue: fixtureUUID(97))
        let attemptID = fixtureUUID(98)
        let recorder = SessionRecorder()
        let events = AsyncThrowingStream<SessionUpdate, Error>.makeStream()
        let frames = AsyncStream<RemoteDisplayFrame>.makeStream()
        let fresh = transportSession(id: freshID, device: device, events: events.stream, frames: frames.stream, recorder: recorder)
        var state = RemoteSessionFeature.State(
            remediation: DeviceHubRemediation(error: .inputCleanupFailed),
            roster: DeviceRoster(devices: [device]), selectedDeviceID: device.id
        )
        state.inputCleanupFailed = true
        let store = TestStore(initialState: state) { feature } withDependencies: {
            $0.date.now = time
            $0.uuid = .constant(attemptID)
            $0.deviceHub.connect = { _ in fresh }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.startViewingButtonTapped)
        await store.send(.deviceSelected(device.id))
        await store.send(.availabilitySnapshotReceived([device]))
        await store.send(.keyTapped(.character("x"), modifiers: []))
        await store.send(.buttonTapped(.home))
        #expect(store.state.session == nil)
        #expect(await recorder.commands().isEmpty)
        await store.send(.retrySelectedDevice)
        await store.receive(\.connectionResponse)
        #expect(store.state.session?.attemptID == attemptID)
        #expect(store.state.session?.sessionID == freshID)
        #expect(!store.state.inputCleanupFailed)
        #expect(store.state.activeContactIDs.isEmpty)
        #expect(store.state.session?.pendingCommands.isEmpty == true)
        #expect(await recorder.commands().isEmpty)
        // Late old errors/readiness cannot mutate fresh ownership.
        await store.send(.inputCleanupFailed(attemptID: old.attemptID, sessionID: old.sessionID, error: .inputCleanupFailed))
        #expect(store.state.session?.attemptID == attemptID)
        #expect(!store.state.inputCleanupFailed)
        await store.send(.stopViewingButtonTapped)
        await store.receive(\.inputCleanupFinished)
        await store.finish()
        #expect(await recorder.disconnectCount() == 1)
    }

    @Test("A later frame cannot erase a known cleanup failure")
    func frameCannotReopenInput() async throws {
        let device = device(id: "cleanup", name: "Synthetic device")
        let time = Date(timeIntervalSince1970: 5000)
        let active = try connectedSession(device: device, receivedAt: time)
        let store = TestStore(initialState: RemoteSessionFeature.State(
            roster: DeviceRoster(devices: [device]), selectedDeviceID: device.id, session: active
        )) { RemoteSessionFeature() } withDependencies: { $0.date.now = time }
        store.exhaustivity = .off
        let sessionID = try #require(active.sessionID)
        await store.send(.inputCleanupFailed(attemptID: active.attemptID, sessionID: sessionID, error: .secureConnectionFailed))
        let generation = try #require(active.remoteState?.generation)
        let frame = try remoteFrame(generation: generation, receivedAt: time, sequenceNumber: 2)
        await store.send(.frameReceived(attemptID: active.attemptID, sessionID: sessionID, frame: frame))
        #expect(!store.state.acceptsInput)
        #expect(store.state.remediation != nil)
    }
}
