import DeviceHubClient
import DeviceHubCore
import DeviceHubDiagnostics
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Input cleanup outcomes", .timeLimit(.minutes(1)))
struct InputCleanupOutcomeTests {
    @Test("Cleanup native failures require explicit user retry", arguments: ["input_delivery_failed", "input_cleanup_timeout"])
    func cleanupMapping(code: String) {
        let failure = NativeSessionFailure(code: code, stage: "input_cleanup", retryable: true)
        let error = mapNativeFailure(failure)
        #expect(error.retryability == .userInitiated)
        #expect(error.remedy == .retry)
    }

    @Test("Sanitized cleanup diagnostics retain timeout independently of UI copy")
    func cleanupDiagnosticRetainsTimeout() {
        let native = NativeSessionFailure(code: "input_cleanup_timeout", stage: "input_cleanup", retryable: true)
        let submission = TransportDiagnosticSubmission.failure(
            mapNativeFailure(native), stage: .disconnecting, nativeFailure: native
        )
        #expect(submission.fields.failureCode == .inputCleanupTimeout)
        #expect(submission.fields.retryability == .userInitiated)
    }

    @Test("A failed explicit release survives successful empty shutdown")
    func commandShutdownRetainsKnownReleaseFailure() async throws {
        let probe = ReleaseFailureProbe()
        let executor = NativeCommandExecutor { command async throws(NativeSessionFailure) in
            if command == .releaseAllInput, await probe.firstRelease() {
                throw NativeSessionFailure(code: "input_cleanup_timeout", stage: "input_cleanup", retryable: true)
            }
        }
        let release = try await executor.submit(.releaseAllInput)
        do { try await release.value(); Issue.record("Release unexpectedly succeeded") } catch {}
        let failure = await executor.shutdown()
        #expect(failure?.code == "input_cleanup_timeout")
        #expect(await executor.shutdown() == failure)
    }

    @Test("Release and disconnect retain settled cleanup after the weak owner is gone", arguments: CleanupOutcome.allCases)
    func completedTransportOutcomeOutlivesOwner(outcome: CleanupOutcome) async throws {
        let probe = ReleaseFailureProbe()
        let native = NativeSession(
            events: AsyncThrowingStream { _ in },
            start: {},
            completePersistence: { _, _ in },
            send: { await probe.sent($0) },
            cancel: { () async throws(NativeSessionFailure) in
                await probe.cancelled()
                if let failure = outcome.failure {
                    throw failure
                }
            }
        )
        var operation: RemoteSessionOperation? = try await makeOperation(native: native)
        let session = try #require(operation).deviceSession
        #expect(await operation?.cleanup() == outcome.failure)
        weak var owner = operation
        operation = nil
        for _ in 0 ..< 16 where owner != nil {
            await Task.yield()
        }
        #expect(owner == nil)
        for _ in 0 ..< 2 {
            #expect(await commandError(session, .releaseAllInput) == outcome.terminalError)
        }
        #expect(await commandError(session, .buttonTap(.home)) == .connectionLost)
        for _ in 0 ..< 2 {
            do {
                try await session.disconnect()
                #expect(outcome == .success)
            } catch let error as DeviceHubError {
                #expect(error == outcome.terminalError)
            }
        }
        #expect(await probe.commands == [.releaseAllInput])
        #expect(await probe.cancelCount == 1)
    }

    @Test("An ownerless release without a settled outcome fails closed")
    func missingTransportOutcomeFailsClosed() async throws {
        let probe = ReleaseFailureProbe()
        let native = NativeSession(
            events: AsyncThrowingStream { _ in }, start: {}, completePersistence: { _, _ in },
            send: { await probe.sent($0) }, cancel: { await probe.cancelled() }
        )
        var operation: RemoteSessionOperation? = try await makeOperation(native: native)
        let session = try #require(operation).deviceSession
        weak var owner = operation
        operation = nil
        #expect(owner == nil)
        #expect(await commandError(session, .releaseAllInput) == .connectionLost)
        #expect(await commandError(session, .buttonTap(.home)) == .connectionLost)
        try await session.disconnect()
        #expect(await probe.commands.isEmpty)
        #expect(await probe.cancelCount == 0)
    }

    @Test("Late releases share complete held cleanup", arguments: CleanupOutcome.allCases)
    func lateReleasesJoinAggregateCleanup(outcome: CleanupOutcome) async throws {
        try await heldCleanup(outcome: outcome, cancelDrivers: false, disconnectFacade: false)
    }

    @Test("Cancelling a started release caller drains held cleanup", arguments: CleanupOutcome.allCases)
    func cancellationDrainsAggregateCleanup(outcome: CleanupOutcome) async throws {
        try await heldCleanup(outcome: outcome, cancelDrivers: true, disconnectFacade: false)
    }

    @Test("Facade disconnect rejects releases during and after held cleanup", arguments: CleanupOutcome.allCases)
    func facadeDisconnectRejectsRelease(outcome: CleanupOutcome) async throws {
        try await heldCleanup(outcome: outcome, cancelDrivers: false, disconnectFacade: true)
    }

    @Test("An accepted release failure survives successful native cancellation", arguments: [CleanupOutcome.timeout, .unknown])
    func acceptedReleaseFailureIsRetained(outcome: CleanupOutcome) async throws {
        let failure = try #require(outcome.failure)
        let probe = ReleaseFailureProbe()
        let native = NativeSession(
            events: AsyncThrowingStream { _ in }, start: {}, completePersistence: { _, _ in },
            send: { command async throws(NativeSessionFailure) in
                await probe.sent(command)
                if command == .releaseAllInput, await probe.firstRelease() {
                    throw failure
                }
            }, cancel: { await probe.cancelled() }
        )
        let operation = try await makeOperation(native: native)
        let session = operation.deviceSession
        #expect(await commandError(session, .releaseAllInput) == outcome.terminalError)
        #expect(await operation.cleanup() == failure)
        #expect(await commandError(session, .releaseAllInput) == outcome.terminalError)
        #expect(await disconnectError(session) == outcome.terminalError)
        #expect(await probe.commands == [.releaseAllInput, .releaseAllInput])
        #expect(await probe.cancelCount == 1)
    }

    @Test("A known release timeout takes priority over later cancellation failure")
    func disconnectPreservesFirstCleanupFailure() async throws {
        let probe = ReleaseFailureProbe()
        let events = AsyncThrowingStream<NativeSessionEvent, Error>.makeStream()
        let native = NativeSessionClient(
            capabilities: .requiredLiveControl,
            makePairingSession: { _ async throws(NativeSessionFailure) in
                throw NativeSessionFailure(code: "invalid_state", stage: "session_lifecycle", retryable: false)
            },
            makeRemoteSession: { _ in
                NativeSession(
                    events: events.stream,
                    start: {},
                    completePersistence: { _, _ in },
                    send: { command async throws(NativeSessionFailure) in
                        if command == .releaseAllInput, await probe.firstRelease() {
                            throw NativeSessionFailure(code: "input_cleanup_timeout", stage: "input_cleanup", retryable: true)
                        }
                    },
                    cancel: { () async throws(NativeSessionFailure) in
                        events.continuation.finish()
                        throw NativeSessionFailure(code: "input_delivery_failed", stage: "input_cleanup", retryable: true)
                    }
                )
            }
        )
        let persistence = try PersistenceProbe(records: [fixtureRecord()])
        let bonjour = try BonjourClientProbe(availability: [], resolvedService: fixtureRemoteService())
        let client = try makeClient(
            nativeSessions: native,
            persistence: persistence.client,
            bonjour: bonjour.client,
            inputCleanupSink: { await probe.observed($0) }
        )
        let session = try await client.connect(deviceID)
        do { try await session.command(.releaseAllInput); Issue.record("Release succeeded") } catch {}
        do { try await session.disconnect(); Issue.record("Disconnect succeeded") } catch {}
        #expect(await probe.observations.map(\.code) == ["input_cleanup_timeout"])
    }

    @Test("Disconnect returns cancellation failure even after streams close", arguments: ["input_delivery_failed", "input_cleanup_timeout"])
    func disconnectReturnsCancellationFailure(code: String) async throws {
        let events = AsyncThrowingStream<NativeSessionEvent, Error>.makeStream()
        let native = NativeSessionClient(
            capabilities: .requiredLiveControl,
            makePairingSession: { _ async throws(NativeSessionFailure) in
                throw NativeSessionFailure(code: "invalid_state", stage: "session_lifecycle", retryable: false)
            },
            makeRemoteSession: { _ in
                NativeSession(
                    events: events.stream,
                    start: {},
                    completePersistence: { _, _ in },
                    send: { _ in },
                    cancel: { () async throws(NativeSessionFailure) in
                        events.continuation.finish()
                        throw NativeSessionFailure(code: code, stage: "input_cleanup", retryable: true)
                    }
                )
            }
        )
        let persistence = try PersistenceProbe(records: [fixtureRecord()])
        let bonjour = try BonjourClientProbe(availability: [], resolvedService: fixtureRemoteService())
        let client = try makeClient(nativeSessions: native, persistence: persistence.client, bonjour: bonjour.client)
        let session = try await client.connect(deviceID)
        for _ in 0 ..< 2 {
            do {
                try await session.disconnect()
                Issue.record("Disconnect erased the cleanup failure")
            } catch let error as DeviceHubError {
                #expect(error.retryability == .userInitiated)
            }
        }
    }

    private func makeOperation(native: NativeSession) async throws -> RemoteSessionOperation {
        let persistence = try PersistenceProbe(records: [fixtureRecord()])
        let bonjour = try BonjourClientProbe(availability: [], resolvedService: fixtureRemoteService())
        let generation = SessionGeneration(rawValue: UUID())
        return await RemoteSessionOperation.make(
            nativeSession: native, generation: generation,
            initialDevice: DeviceSummary(
                id: deviceID, name: "Synthetic device", productType: "iPhone",
                operatingSystemVersion: "27.0", pairingState: .paired, reachability: .reachable
            ), claimedDeviceID: deviceID,
            environment: DeviceHubTransportEnvironment(
                persistence: persistence.client, bonjour: bonjour.client,
                observe: { _, _ in }, now: { now }, makeUUID: { generation.rawValue }
            )
        )
    }

    private func commandError(_ session: DeviceSession, _ command: DeviceCommand) async -> DeviceHubError? {
        do {
            try await session.command(command)
            return nil
        } catch let error as DeviceHubError {
            return error
        } catch {
            Issue.record("Unexpected command error")
            return .secureConnectionFailed
        }
    }

    private func disconnectError(_ session: DeviceSession) async -> DeviceHubError? {
        do {
            try await session.disconnect()
            return nil
        } catch let error as DeviceHubError {
            return error
        } catch {
            Issue.record("Unexpected disconnect error")
            return .secureConnectionFailed
        }
    }

    private func heldCleanup(outcome: CleanupOutcome, cancelDrivers: Bool, disconnectFacade: Bool) async throws {
        let events = AsyncThrowingStream<NativeSessionEvent, Error>.makeStream()
        let entered = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let ready = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let probe = ReleaseFailureProbe()
        let openAll: @Sendable () -> Void = {
            gate.continuation.finish()
            entered.continuation.finish()
            ready.continuation.finish()
            events.continuation.finish()
        }
        let native = NativeSession(
            events: events.stream, start: {}, completePersistence: { _, _ in },
            send: { await probe.sent($0) }, cancel: { () async throws(NativeSessionFailure) in
                await probe.cancelled()
                entered.continuation.yield(())
                entered.continuation.finish()
                for await _ in gate.stream {}
                if let failure = outcome.failure {
                    throw failure
                }
            }
        )
        let operation = try await makeOperation(native: native)
        let session = operation.deviceSession
        let closing = Task<DeviceHubError?, Never> {
            if disconnectFacade {
                return await disconnectError(session)
            }
            let failure = await operation.cleanup()
            return failure.map(mapNativeFailure)
        }
        try await withTaskCancellationHandler {
            var releases: [Task<DeviceHubError?, Never>] = []
            do {
                var entry = entered.stream.makeAsyncIterator()
                _ = try #require(await entry.next())
                #expect(await probe.commands == [.releaseAllInput])
                #expect(await probe.cancelCount == 1)
                if disconnectFacade {
                    for _ in 0 ..< 2 {
                        #expect(await commandError(session, .releaseAllInput) == .connectionLost)
                    }
                } else {
                    releases = (0 ..< 2).map { _ in
                        Task {
                            await withTaskCancellationHandler {
                                ready.continuation.yield(())
                                let error = await commandError(session, .releaseAllInput)
                                await probe.released(error)
                                return error
                            } onCancel: {
                                cancelled.continuation.yield(())
                                openAll()
                            }
                        }
                    }
                    var starts = ready.stream.makeAsyncIterator()
                    for _ in 0 ..< 2 {
                        _ = try #require(await starts.next())
                    }
                    // Caller-start and this snapshot do not instrument a private actor-await entry.
                    #expect(await probe.releaseResults.isEmpty)
                    if cancelDrivers {
                        // Its handler opens the shared gate; the other caller can then finish.
                        releases[0].cancel()
                    }
                }
            } catch {
                openAll()
                await drainHeld(operation, session: session, closing: closing, releases: releases, outcome: outcome)
                cancelled.continuation.finish()
                throw error
            }
            openAll()
            await drainHeld(operation, session: session, closing: closing, releases: releases, outcome: outcome)
            cancelled.continuation.finish()
            var cancellationCount = 0
            for await _ in cancelled.stream {
                cancellationCount += 1
            }
            #expect(cancellationCount == (cancelDrivers ? 1 : 0))
            #expect(await probe.commands == [.releaseAllInput])
            #expect(await probe.cancelCount == 1)
            #expect(await probe.releaseResults.count == (disconnectFacade ? 0 : 2))
        } onCancel: { openAll() }
    }

    private func drainHeld(
        _ operation: RemoteSessionOperation, session: DeviceSession, closing: Task<DeviceHubError?, Never>,
        releases: [Task<DeviceHubError?, Never>], outcome: CleanupOutcome
    ) async {
        // Joined unstructured drainage remains independent of a cancelled caller.
        let drain = Task {
            for release in releases {
                #expect(await release.value == outcome.terminalError)
            }
            #expect(await closing.value == outcome.terminalError)
            #expect(await operation.cleanup() == outcome.failure)
            #expect(await disconnectError(session) == outcome.terminalError)
            #expect(await commandError(session, .releaseAllInput) == .connectionLost)
            #expect(await commandError(session, .buttonTap(.home)) == .connectionLost)
        }
        await drain.value
    }
}

private actor ReleaseFailureProbe {
    private var releaseCount = 0
    var observations: [NativeSessionFailure] = []
    var commands: [DeviceCommand] = []
    var cancelCount = 0
    var releaseResults: [DeviceHubError?] = []

    func released(_ error: DeviceHubError?) {
        releaseResults.append(error)
    }

    func sent(_ command: DeviceCommand) {
        commands.append(command)
    }

    func cancelled() {
        cancelCount += 1
    }

    func observed(_ failure: NativeSessionFailure) {
        observations.append(failure)
    }

    func firstRelease() -> Bool {
        releaseCount += 1
        return releaseCount == 1
    }
}
