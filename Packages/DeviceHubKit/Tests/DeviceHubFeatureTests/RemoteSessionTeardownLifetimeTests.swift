import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Warning-time observer lifetime", .timeLimit(.minutes(1)))
struct RemoteSessionTeardownLifetimeTests {
    @Test("Observer handles finish before external disconnect settles", arguments: [nil, .inputCleanupFailed, .secureConnectionFailed] as [DeviceHubError?])
    func observersFinishDuringHeldDisconnect(error: DeviceHubError?) async throws {
        try await probe(error: error, cancelDriver: false)
    }

    @Test("Cancelling an entered diagnostic drains the held close")
    func cancellationDrainsHeldDisconnect() async throws {
        try await probe(error: nil, cancelDriver: true)
    }

    private func probe(error: DeviceHubError?, cancelDriver: Bool) async throws {
        let device = device(id: "teardown", name: "Synthetic device")
        let time = Date(timeIntervalSince1970: 5000)
        let active = try connectedSession(device: device, receivedAt: time)
        let sessionID = try #require(active.sessionID)
        let frame = try #require(active.frame)
        let lateFrame = try remoteFrame(generation: frame.metadata.generation, receivedAt: time, sequenceNumber: 2)
        let sources = (events: AsyncThrowingStream<SessionUpdate, Error>.makeStream(), frames: AsyncStream<RemoteDisplayFrame>.makeStream())
        let entered = AsyncStream<Bool>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let terminations = AsyncStream<String>.makeStream()
        let ready = AsyncStream<Bool>.makeStream()
        let cancelled = AsyncStream<Bool>.makeStream()
        let recorder = SessionRecorder()
        sources.events.continuation.onTermination = { reason in
            if case .cancelled = reason {
                terminations.continuation.yield("events_cancelled")
            } else {
                terminations.continuation.yield("events_finished")
            }
        }
        sources.frames.continuation.onTermination = { reason in
            if case .cancelled = reason {
                terminations.continuation.yield("frames_cancelled")
            } else {
                terminations.continuation.yield("frames_finished")
            }
        }
        let openAll: @Sendable () -> Void = {
            gate.continuation.finish()
            entered.continuation.finish()
            ready.continuation.finish()
            sources.events.continuation.finish()
            sources.frames.continuation.finish()
            terminations.continuation.finish()
            cancelled.continuation.finish()
        }
        let transport = DeviceSession(
            id: sessionID, device: device, events: sources.events.stream, frames: sources.frames.stream,
            command: { await recorder.record($0) }, disconnect: {
                await recorder.recordDisconnect()
                entered.continuation.yield(true)
                entered.continuation.finish()
                for await _ in gate.stream {}
                if let error {
                    throw error
                }
            }
        )
        let feature = RemoteSessionFeature()
        let coordinator = feature.sessionCoordinator
        let store = TestStore(initialState: RemoteSessionFeature.State(
            activeContactIDs: [7], roster: DeviceRoster(devices: [device]), selectedDeviceID: device.id, session: active
        )) { feature } withDependencies: { $0.date.now = time }
        let driver = Task { @MainActor in
            try await withTaskCancellationHandler {
                var observation: TestStoreTask?
                var close: TestStoreTask?
                var setupFailure: Error?
                do {
                    var client = DeviceHubClient()
                    client.connect = { _ in transport }
                    _ = try await coordinator.replace(attemptID: active.attemptID, deviceID: device.id, using: client)
                    let task = await seedObservers(store, active: active, transport: transport, frame: frame, sources: sources)
                    observation = task
                    close = await beginHeldClose(
                        store,
                        active: active,
                        sessionID: sessionID,
                        observation: task,
                        signals: (entry: entered.stream, terminations: terminations.stream)
                    )
                    ready.continuation.yield(true)
                    ready.continuation.finish()
                    if cancelDriver {
                        for await _ in gate.stream {}
                        try Task.checkCancellation()
                    }
                } catch is CancellationError {
                    #expect(Task.isCancelled)
                } catch {
                    setupFailure = error
                }
                // Every exit opens gates before joining the retained coordinator close and every feature effect.
                openAll()
                await drain(
                    store,
                    owner: (active: active, frame: lateFrame),
                    lifetime: (transport: transport, coordinator: coordinator),
                    recorder: recorder,
                    effects: (observation: observation, close: close),
                    error: error
                )
                if let setupFailure {
                    throw setupFailure
                }
            } onCancel: {
                cancelled.continuation.yield(true)
                cancelled.continuation.finish()
                openAll()
            }
        }
        try await joinDriver(driver, cancelDriver: cancelDriver, ready: ready.stream)
        cancelled.continuation.finish()
        var cancellation = cancelled.stream.makeAsyncIterator()
        #expect(await cancellation.next() == (cancelDriver ? true : nil))
    }

    private func drain(
        _ store: TestStoreOf<RemoteSessionFeature>, owner: (active: ActiveRemoteSession, frame: RemoteDisplayFrame),
        lifetime: (transport: DeviceSession, coordinator: DeviceSessionCoordinator), recorder: SessionRecorder,
        effects: (observation: TestStoreTask?, close: TestStoreTask?), error: DeviceHubError?
    ) async {
        // An unstructured, explicitly joined drain is not cancelled with the diagnostic driver.
        let cleanup = Task { @MainActor in
            if let close = effects.close {
                if error == nil {
                    await store.receive(\.inputCleanupFinished) { $0.pendingInputCleanup = nil }
                } else {
                    await store.receive(\.inputCleanupFailed) { $0.pendingInputCleanup = nil }
                }
                await close.finish()
                await effects.observation?.finish()
                await store.finish()
                await assertStopped(
                    store,
                    active: owner.active,
                    sessionID: lifetime.transport.id,
                    frame: owner.frame,
                    coordinator: lifetime.coordinator,
                    recorder: recorder
                )
            } else {
                await effects.observation?.cancel()
                try? await lifetime.coordinator.close(attemptID: owner.active.attemptID)
                await store.finish()
            }
            do {
                try await lifetime.transport.disconnect()
            } catch let actual as DeviceHubError {
                #expect(actual == error)
            } catch {
                Issue.record("Unexpected transport cleanup error: \(error)")
            }
        }
        await cleanup.value
    }

    private func joinDriver(_ driver: Task<Void, Error>, cancelDriver: Bool, ready: AsyncStream<Bool>) async throws {
        try await withTaskCancellationHandler {
            if cancelDriver {
                var signal = ready.makeAsyncIterator()
                #expect(await signal.next() == true)
                driver.cancel()
            }
            try await driver.value
        } onCancel: { driver.cancel() }
    }

    private func beginHeldClose(
        _ store: TestStoreOf<RemoteSessionFeature>, active: ActiveRemoteSession, sessionID: DeviceSessionID, observation: TestStoreTask,
        signals: (entry: AsyncStream<Bool>, terminations: AsyncStream<String>)
    ) async -> TestStoreTask {
        let close = await store.send(.inputCleanupFailed(attemptID: active.attemptID, sessionID: sessionID, error: .inputCleanupFailed)) {
            $0.activeContactIDs = []
            $0.session = nil
            $0.inputCleanupFailed = true
            $0.remediation = DeviceHubRemediation(error: .inputCleanupFailed)
            $0.pendingInputCleanup = InputCleanupOwnership(session: active)
        }
        var entry = signals.entry.makeAsyncIterator()
        #expect(await entry.next() == true)
        var terminations = signals.terminations.makeAsyncIterator()
        let first = await terminations.next()
        let second = await terminations.next()
        #expect(Set([first, second].compactMap(\.self)) == ["events_cancelled", "frames_cancelled"])
        // Also finish the specific tracked observation handle before opening disconnect; private TCA task bodies have no exit signal here.
        await observation.finish()
        // TCA cancellation is eager here; cancelled loops emit no terminal observer actions. Keep the store exhaustive.
        #expect(store.state.pendingInputCleanup == InputCleanupOwnership(session: active))
        assertLatched(store)
        return close
    }

    private func seedObservers(
        _ store: TestStoreOf<RemoteSessionFeature>, active: ActiveRemoteSession, transport: DeviceSession, frame: RemoteDisplayFrame,
        sources: (
            events: (stream: AsyncThrowingStream<SessionUpdate, Error>, continuation: AsyncThrowingStream<SessionUpdate, Error>.Continuation),
            frames: (stream: AsyncStream<RemoteDisplayFrame>, continuation: AsyncStream<RemoteDisplayFrame>.Continuation)
        )
    ) async -> TestStoreTask {
        let task = await store.send(.connectionResponse(attemptID: active.attemptID, deviceID: transport.device.id, result: .success(transport))) {
            $0.session?.remoteState = nil
        }
        for event in [DeviceSessionEvent.phaseChanged(.ready), .hidReadinessChanged(.ready)] {
            let update = SessionUpdate(generation: frame.metadata.generation, event: event)
            sources.events.continuation.yield(update)
            await store.receive(\.sessionUpdateReceived) {
                var state = $0.session?.remoteState ?? RemoteSessionState(deviceID: transport.device.id, generation: update.generation)
                _ = state.apply(update)
                $0.session?.remoteState = state
            }
        }
        sources.frames.continuation.yield(frame)
        await store.receive(\.frameReceived) {
            _ = $0.session?.remoteState?.apply(SessionUpdate(generation: frame.metadata.generation, event: frame.metadata.sessionEventForTesting))
        }
        #expect(store.state.acceptsInput)
        return task
    }

    private func assertLatched(_ store: TestStoreOf<RemoteSessionFeature>) {
        #expect(store.state.inputCleanupFailed)
        #expect(store.state.remediation?.error == .inputCleanupFailed)
        #expect(store.state.session == nil)
        #expect(store.state.activeContactIDs.isEmpty)
        #expect(!store.state.acceptsInput)
    }

    private func assertStopped(
        _ store: TestStoreOf<RemoteSessionFeature>, active: ActiveRemoteSession, sessionID: DeviceSessionID,
        frame: RemoteDisplayFrame, coordinator: DeviceSessionCoordinator, recorder: SessionRecorder
    ) async {
        #expect(store.state.pendingInputCleanup == nil)
        await store.send(.startViewingButtonTapped)
        await store.send(.frameReceived(attemptID: active.attemptID, sessionID: sessionID, frame: frame))
        await store.send(.inputCleanupFinished(attemptID: active.attemptID, sessionID: sessionID))
        await store.send(.inputCleanupFailed(attemptID: fixtureUUID(90), sessionID: sessionID, error: .secureConnectionFailed))
        await store.send(.buttonTapped(.home))
        assertLatched(store)
        do {
            try await coordinator.command(.buttonTap(.home), attemptID: active.attemptID, sessionID: sessionID, authorization: frame.metadata)
            Issue.record("Old owner delivered ordinary input")
        } catch let error as DeviceHubError {
            #expect(error == .connectionLost)
        } catch {
            Issue.record("Unexpected old-owner rejection: \(error)")
        }
        #expect(await recorder.commands() == [.releaseAllInput])
        #expect(await recorder.disconnectCount() == 1)
    }
}
