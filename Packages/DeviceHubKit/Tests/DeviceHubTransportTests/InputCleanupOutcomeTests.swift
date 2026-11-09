import DeviceHubClient
import DeviceHubCore
import DeviceHubDiagnostics
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Input cleanup outcomes")
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

    @Test("Disconnect retains cleanup outcome after its weak transport owner is gone")
    func completedTransportOutcomeOutlivesOwner() async throws {
        let failure = NativeSessionFailure(code: "input_cleanup_timeout", stage: "input_cleanup", retryable: true)
        let native = NativeSession(
            events: AsyncThrowingStream { _ in },
            start: {},
            completePersistence: { _, _ in },
            send: { _ in },
            cancel: { () async throws(NativeSessionFailure) in throw failure }
        )
        let persistence = try PersistenceProbe(records: [fixtureRecord()])
        let bonjour = try BonjourClientProbe(availability: [], resolvedService: fixtureRemoteService())
        let generation = SessionGeneration(rawValue: UUID())
        var operation: RemoteSessionOperation? = await RemoteSessionOperation.make(
            nativeSession: native, generation: generation,
            initialDevice: DeviceSummary(
                id: deviceID,
                name: "Synthetic device",
                productType: "iPhone",
                operatingSystemVersion: "27.0",
                pairingState: .paired,
                reachability: .reachable
            ),
            claimedDeviceID: deviceID,
            environment: DeviceHubTransportEnvironment(
                persistence: persistence.client,
                bonjour: bonjour.client,
                observe: { _, _ in },
                now: { now },
                makeUUID: { generation.rawValue }
            )
        )
        let session = try #require(operation).deviceSession
        #expect(await operation?.cleanup() == failure)
        weak var owner = operation
        operation = nil
        for _ in 0 ..< 16 where owner != nil {
            await Task.yield()
        }
        #expect(owner == nil)
        do {
            try await session.disconnect()
            Issue.record("Cleanup outcome died with the transport actor")
        } catch let error as DeviceHubError {
            #expect(error == .inputCleanupFailed)
        }
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
}

private actor ReleaseFailureProbe {
    private var releaseCount = 0
    var observations: [NativeSessionFailure] = []
    func observed(_ failure: NativeSessionFailure) {
        observations.append(failure)
    }

    func firstRelease() -> Bool {
        releaseCount += 1
        return releaseCount == 1
    }
}
