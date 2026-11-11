import DeviceHubCore
@testable import DeviceHubTransport
import Testing

@Suite("Live client availability lifecycle", .timeLimit(.minutes(1)))
struct DeviceHubClientLiveAvailabilityTests {
    @Test("ending an older consumer preserves the newer browse and its updates")
    func olderConsumerDoesNotStopNewerBrowse() async throws {
        let browser = BrowserProbe()
        let transport = makeTransport(browser: browser)
        let persistence = try PersistenceProbe(records: [fixtureRecord()])
        let gate = FirstAvailabilitySnapshotGate()
        var persistenceClient = persistence.client
        persistenceClient.pairingRecords = {
            await gate.blockFirstSnapshot()
            return try await persistence.client.pairingRecords()
        }
        let client = try makeClient(
            persistence: persistenceClient,
            bonjour: availabilityClient(transport)
        )
        let firstStream = client.availability()
        let firstConsumer = Task {
            for await _ in firstStream {}
        }
        // Hold A's forwarding task while B replaces its source generation.
        await gate.waitUntilBlocked()
        let secondStream = client.availability()
        var secondIterator = secondStream.makeAsyncIterator()
        let initial = await secondIterator.next()
        #expect(initial?.first?.reachability == .unavailable)
        #expect(await browser.startCount == 2)
        #expect(await browser.stopCount == 1)

        firstConsumer.cancel()
        await firstConsumer.value
        await gate.release()
        // Termination cleanup is scheduled in unstructured tasks. Allow it
        // to settle before checking that B still owns the browser.
        try await Task.sleep(for: .milliseconds(100))

        #expect(await browser.stopCount == 1)
        try await browser.emit(.resolved(resolvedService()))
        let updated = await secondIterator.next()
        #expect(updated?.first?.id == deviceID)
        #expect(updated?.first?.reachability == .reachable)
        await transport.stopAvailability()
    }

    @Test("ending the active consumer still stops its own browse")
    func endingConsumerStopsOwnBrowse() async throws {
        let browser = BrowserProbe()
        let transport = makeTransport(browser: browser)
        let persistence = try PersistenceProbe(records: [fixtureRecord()])
        let client = try makeClient(
            persistence: persistence.client,
            bonjour: availabilityClient(transport)
        )
        let stream = client.availability()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.first?.reachability == .unavailable)
        let consumer = Task {
            for await _ in stream {}
        }

        consumer.cancel()
        await consumer.value
        await browser.waitUntilStopped()

        #expect(await browser.startCount == 1)
        #expect(await browser.stopCount == 1)
    }
}

private func availabilityClient(
    _ transport: RemotePairingBonjourTransport
) -> RemotePairingBonjourClient {
    var client = BonjourClientProbe(availability: []).client
    client.availability = { await transport.availability() }
    return client
}

private actor FirstAvailabilitySnapshotGate {
    private var didEnter = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func blockFirstSnapshot() async {
        guard !didEnter else {
            return
        }
        didEnter = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilBlocked() async {
        guard !didEnter else {
            return
        }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
