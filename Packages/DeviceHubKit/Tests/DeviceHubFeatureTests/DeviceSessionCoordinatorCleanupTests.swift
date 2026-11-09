import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

@Suite("Coordinator cleanup outcomes")
struct DeviceSessionCoordinatorCleanupTests {
    @Test("Replacement never connects behind failed old-session cleanup")
    func replacementFailsClosed() async throws {
        let coordinator = DeviceSessionCoordinator()
        let device = device(id: "cleanup", name: "Synthetic device")
        let probe = CleanupCoordinatorProbe()
        let session = DeviceSession(
            id: DeviceSessionID(rawValue: fixtureUUID(90)), device: device,
            events: AsyncThrowingStream { _ in }, frames: AsyncStream { _ in },
            command: { command in
                if command == .releaseAllInput {
                    throw DeviceHubError.secureConnectionFailed
                }
            }, disconnect: { await probe.disconnected() }
        )
        var client = DeviceHubClient()
        client.connect = { _ in await probe.connected(); return session }
        _ = try await coordinator.replace(attemptID: fixtureUUID(91), deviceID: device.id, using: client)
        do {
            _ = try await coordinator.replace(attemptID: fixtureUUID(92), deviceID: device.id, using: client)
            Issue.record("Replacement ignored failed cleanup")
        } catch let error as DeviceHubError {
            #expect(error.retryability == .userInitiated)
        }
        #expect(await probe.connects == 1)
        #expect(await probe.disconnects == 1)
    }
}

private actor CleanupCoordinatorProbe {
    var connects = 0
    var disconnects = 0
    func connected() {
        connects += 1
    }

    func disconnected() {
        disconnects += 1
    }
}
