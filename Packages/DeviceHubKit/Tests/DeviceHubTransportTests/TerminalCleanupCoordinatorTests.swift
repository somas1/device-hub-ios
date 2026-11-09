import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Terminal cleanup coordinator boundary", .timeLimit(.minutes(1)))
struct TerminalCleanupCoordinatorTests {
    @Test("Settled transport cleanup precedes coordinator terminal close", arguments: CleanupOutcome.allCases)
    func settledCleanupBeforeTerminal(outcome: CleanupOutcome) async throws {
        try await reproduce(outcome: outcome, overlapping: false)
    }

    @Test("Coordinator close waits for unsettled media-terminal cleanup", arguments: CleanupOutcome.allCases)
    func terminalBeforeCleanupSettles(outcome: CleanupOutcome) async throws {
        try await reproduce(outcome: outcome, overlapping: true)
    }

    private func reproduce(outcome: CleanupOutcome, overlapping: Bool) async throws {
        let generation = SessionGeneration(rawValue: UUID())
        let authorization = try ScreenMetadata.videoFrame(FrameMetadata(
            generation: generation, sequenceNumber: 1, receivedAt: now,
            pixelSize: PixelSize(width: 100, height: 200), orientation: .portrait
        ))
        let events = AsyncThrowingStream<NativeSessionEvent, Error>.makeStream()
        let enteredCancel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancelGate = AsyncStream<Void>.makeStream()
        let probe = TerminalCleanupProbe()
        let native = NativeSession(
            events: events.stream,
            start: { events.continuation.yield(.inputReady) },
            completePersistence: { _, _ in },
            send: { await probe.sent($0) },
            cancel: { () async throws(NativeSessionFailure) in
                await probe.cancelled()
                enteredCancel.continuation.yield(())
                enteredCancel.continuation.finish()
                for await _ in cancelGate.stream {}
                events.continuation.finish()
                if let failure = outcome.failure {
                    throw failure
                }
            }
        )
        let operation = try await makeOperation(native: native, generation: generation)
        let session = operation.deviceSession
        let coordinator = DeviceSessionCoordinator()
        let attemptID = UUID()
        var client = DeviceHubClient()
        client.connect = { _ in session }
        var mediaTask: Task<Void, Never>?
        var closeTasks: [Task<DeviceHubError?, Never>] = []
        try await withTaskCancellationHandler {
            do {
                _ = try await coordinator.replace(attemptID: attemptID, deviceID: deviceID, using: client)
                try await operation.start()
                var updates = session.events.makeAsyncIterator()
                #expect(try await updates.next()?.event == .hidReadinessChanged(.ready))
                #expect(await coordinator.releaseAllInput(
                    attemptID: attemptID, sessionID: session.id, revoking: authorization
                ) == nil)
                #expect(try await ownershipRemoved(coordinator, attemptID: attemptID, session: session, authorization: authorization) == false)
                #expect(try await ownershipRemoved(coordinator, attemptID: UUID(), session: session, authorization: authorization))
                try await coordinator.close(attemptID: UUID())
                #expect(try await ownershipRemoved(coordinator, attemptID: attemptID, session: session, authorization: authorization) == false)

                if overlapping {
                    mediaTask = Task { await operation.terminateForMediaFailure(.decoderFailed) }
                    #expect(try await updates.next()?.event == .ended(.decoderFailed))
                    var entered = enteredCancel.stream.makeAsyncIterator()
                    _ = try #require(await entered.next())
                } else {
                    cancelGate.continuation.finish()
                    events.continuation.yield(.completed)
                    #expect(try await updates.next()?.event == .ended(outcome.terminalError))
                    #expect(await operation.cleanup() == outcome.failure)
                }
                closeTasks = (0 ..< 2).map { _ in
                    Task {
                        let error = await closeError(coordinator, attemptID: attemptID)
                        await probe.closed(error)
                        return error
                    }
                }
                if overlapping {
                    while try await !ownershipRemoved(coordinator, attemptID: attemptID, session: session, authorization: authorization) {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                    #expect(await probe.closeResults.isEmpty)
                }
                cancelGate.continuation.finish()
                let closeError = await closeTasks[0].value
                #expect(await closeTasks[1].value == closeError)
                #expect(await self.closeError(coordinator, attemptID: attemptID) == closeError)
                await mediaTask?.value
                #expect(await operation.cleanup() == outcome.failure)
                if outcome == .success {
                    #expect(closeError == nil)
                } else {
                    #expect(closeError == .inputCleanupFailed)
                }
                #expect(try await ownershipRemoved(coordinator, attemptID: attemptID, session: session, authorization: authorization))
                try await assertOldSessionRejectsInput(session)
                #expect(await probe.commands == [.releaseAllInput])
                #expect(await probe.cancelCount == 1)
                #expect(await probe.closeResults.count == 2)
            } catch {
                cancelGate.continuation.finish()
                enteredCancel.continuation.finish()
                events.continuation.finish()
                await drain(closeTasks, media: mediaTask, operation: operation)
                _ = await closeError(coordinator, attemptID: attemptID)
                try? await session.disconnect()
                throw error
            }
            cancelGate.continuation.finish()
            enteredCancel.continuation.finish()
            events.continuation.finish()
            await drain(closeTasks, media: mediaTask, operation: operation)
            try? await session.disconnect()
        } onCancel: {
            cancelGate.continuation.finish()
            enteredCancel.continuation.finish()
            events.continuation.finish()
        }
    }

    private func makeOperation(native: NativeSession, generation: SessionGeneration) async throws -> RemoteSessionOperation {
        let persistence = try PersistenceProbe(records: [fixtureRecord()])
        let bonjour = BonjourClientProbe(availability: [])
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

    private func drain(_ closes: [Task<DeviceHubError?, Never>], media: Task<Void, Never>?, operation: RemoteSessionOperation) async {
        await media?.value
        for task in closes {
            _ = await task.value
        }
        _ = await operation.cleanup()
    }

    private func assertOldSessionRejectsInput(_ session: DeviceSession) async throws {
        do {
            try await session.command(.buttonTap(.home))
            Issue.record("Old session delivered ordinary input after teardown")
        } catch let error as DeviceHubError {
            #expect(error == .connectionLost)
        }
    }

    /// Revoked metadata distinguishes active old ownership from close's removal.
    private func ownershipRemoved(
        _ coordinator: DeviceSessionCoordinator, attemptID: UUID,
        session: DeviceSession, authorization: ScreenMetadata
    ) async throws -> Bool {
        do {
            try await coordinator.command(
                .buttonTap(.home), attemptID: attemptID, sessionID: session.id,
                authorization: authorization
            )
            Issue.record("Revoked or foreign ownership admitted ordinary input")
            return false
        } catch is CancellationError {
            return false
        } catch let error as DeviceHubError where error == .connectionLost {
            return true
        }
    }

    private func closeError(_ coordinator: DeviceSessionCoordinator, attemptID: UUID) async -> DeviceHubError? {
        do {
            try await coordinator.close(attemptID: attemptID)
            return nil
        } catch let error as DeviceHubError {
            return error
        } catch {
            Issue.record("Coordinator returned an unexpected error")
            return .secureConnectionFailed
        }
    }
}

enum CleanupOutcome: CaseIterable, Sendable {
    case success, timeout, unknown

    var failure: NativeSessionFailure? {
        switch self {
        case .success: nil
        case .timeout: NativeSessionFailure(code: "input_cleanup_timeout", stage: "input_cleanup", retryable: true)
        case .unknown: NativeSessionFailure(code: "invalid_state", stage: "session_lifecycle", retryable: false)
        }
    }

    var terminalError: DeviceHubError? {
        switch self {
        case .success: nil
        case .timeout: .inputCleanupFailed
        case .unknown: .secureConnectionFailed
        }
    }
}

private actor TerminalCleanupProbe {
    var commands: [DeviceCommand] = []
    var cancelCount = 0
    var closeResults: [DeviceHubError?] = []

    func sent(_ command: DeviceCommand) {
        commands.append(command)
    }

    func cancelled() {
        cancelCount += 1
    }

    func closed(_ error: DeviceHubError?) {
        closeResults.append(error)
    }
}
