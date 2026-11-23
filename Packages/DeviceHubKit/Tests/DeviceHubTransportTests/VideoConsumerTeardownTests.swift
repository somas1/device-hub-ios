import DeviceHubCore
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Video consumer teardown", .timeLimit(.minutes(1)))
struct VideoConsumerTeardownTests {
    @Test("a decoder throw cancels video ingress before teardown", .timeLimit(.minutes(1)))
    func accessUnitAfterDecoderThrowIsCancelled() async throws {
        try await withPausedDecoderFailure { bridge in
            #expect(receiveValidAccessUnit(on: bridge, sequenceNumber: 4) == .terminal(.cancelled))
        }
    }

    @Test("the video queue stays empty after a decoder throw", .timeLimit(.minutes(1)))
    func videoQueueDoesNotGrowAfterDecoderThrow() async throws {
        try await withPausedDecoderFailure { bridge in
            for sequenceNumber: UInt64 in 4 ... 5 {
                let receipt = lengthPrefixedNALUnit([0x26, 0x01]).withUnsafeBytes {
                    bridge.receiveAccessUnitWithQueueDepth(
                        sequenceNumber: sequenceNumber,
                        receivedAt: now,
                        orientation: .portrait,
                        pixelSize: PixelSize(width: 1179, height: 2556),
                        bytes: $0
                    )
                }
                #expect(receipt.queueDepth == 0)
            }
        }
    }
}

private func withPausedDecoderFailure(
    _ verify: (NativeVideoEventBridge) -> Void
) async throws {
    let generation = testGeneration(15)
    let bridge = try NativeVideoEventBridge(generation: testGeneration(16), bufferCapacity: 4)
    #expect(receiveValidConfiguration(on: bridge, sequenceNumber: 1) == .accepted)
    #expect(receiveValidAccessUnit(on: bridge, sequenceNumber: 2) == .accepted)
    #expect(receiveValidAccessUnit(on: bridge, sequenceNumber: 3) == .accepted)

    let control = AsyncThrowingStream<NativeSessionEvent, Error>.makeStream()
    let failure = AsyncStream<DeviceHubError>.makeStream()
    let resumeTeardown = AsyncStream<Void>.makeStream()
    let native = NativeSession(
        events: control.stream, videoEvents: bridge.events,
        start: {}, completePersistence: { _, _ in }, send: { _ in },
        cancel: {
            bridge.cancel()
            control.continuation.finish()
        }
    )
    let persistence = try PersistenceProbe(records: [fixtureRecord()])
    let operation = await RemoteSessionOperation.make(
        nativeSession: native, generation: generation,
        initialDevice: DeviceSummary(
            id: deviceID, name: "Synthetic device", productType: "iPhone", operatingSystemVersion: "27.0",
            pairingState: .paired, reachability: .reachable
        ), claimedDeviceID: deviceID,
        environment: DeviceHubTransportEnvironment(
            persistence: persistence.client, bonjour: BonjourClientProbe(availability: []).client,
            observe: { error, _ in
                failure.continuation.yield(error)
                for await _ in resumeTeardown.stream {}
            }, now: { now }, makeUUID: { generation.rawValue }
        )
    )
    try await operation.start()
    let mediaTask = await operation.mediaTask
    await withTaskCancellationHandler {
        var observations = failure.stream.makeAsyncIterator()
        let observedFailure = await observations.next()
        #expect(observedFailure == .decoderFailed)
        if observedFailure == .decoderFailed {
            verify(bridge)
        }
        resumeTeardown.continuation.finish()
        await mediaTask?.value
    } onCancel: {
        failure.continuation.finish()
        resumeTeardown.continuation.finish()
    }
}
