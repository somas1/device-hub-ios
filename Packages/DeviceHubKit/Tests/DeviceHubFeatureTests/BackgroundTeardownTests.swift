import ComposableArchitecture
import CustomDump
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

/// Teardown must finish inside protected background time so input release
/// and disconnect reach the device before iOS suspends the app.
@MainActor
@Suite("Background teardown")
struct BackgroundTeardownTests {
    @Test("A close releases input and disconnects inside protected time", .timeLimit(.minutes(1)))
    func closeRunsInsideProtectedTime() async throws {
        let log = ProtectionLog()
        let coordinator = DeviceSessionCoordinator()
        let device = device(id: "background", name: "Synthetic device")
        try await connect(coordinator, attemptID: fixtureUUID(100), session: loggingSession(device: device, log: log))

        try await withDependencies {
            $0.backgroundExecution = .logging(to: log)
        } operation: {
            try await coordinator.close(attemptID: fixtureUUID(100))
        }

        let entries = await log.entries
        expectNoDifference(entries, [
            "begin close-remote-session",
            "release input",
            "disconnect",
            "end close-remote-session"
        ])
    }

    @Test("A failed release still fails the close after protected time ends", .timeLimit(.minutes(1)))
    func failedReleaseIsStillReported() async throws {
        let log = ProtectionLog()
        let coordinator = DeviceSessionCoordinator()
        let device = device(id: "background", name: "Synthetic device")
        let session = loggingSession(device: device, log: log, releaseFails: true)
        try await connect(coordinator, attemptID: fixtureUUID(101), session: session)

        await withDependencies {
            $0.backgroundExecution = .logging(to: log)
        } operation: {
            do {
                try await coordinator.close(attemptID: fixtureUUID(101))
                Issue.record("Close hid the failed input release")
            } catch {
                #expect(error as? DeviceHubError == .inputCleanupFailed)
            }
        }

        let entries = await log.entries
        expectNoDifference(entries, [
            "begin close-remote-session",
            "release input",
            "disconnect",
            "end close-remote-session"
        ])
    }

    @Test("Backgrounding closes the session inside protected time and reports cleanup", .timeLimit(.minutes(1)))
    func backgroundCloseIsProtected() async throws {
        let time = Date(timeIntervalSince1970: 4600)
        let device = device(id: "device", name: "Test iPhone")
        let context = RotationSessionTestContext(
            time: time,
            device: device,
            attemptID: fixtureUUID(80),
            sessionID: DeviceSessionID(rawValue: fixtureUUID(81)),
            generation: SessionGeneration(rawValue: fixtureUUID(82))
        )
        let log = ProtectionLog()
        let session = loggingSession(device: device, log: log, sessionID: context.sessionID)
        let store = TestStore(initialState: RemoteSessionFeature.State()) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date.now = time
            $0.deviceHub.connect = { _ in session }
            $0.uuid = .constant(context.attemptID)
            $0.backgroundExecution = .logging(to: log)
        }
        try await establishInputReadyRotationSession(in: store, context: context)
        let previousSession = try #require(store.state.session)

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.pendingInputCleanup = InputCleanupOwnership(session: previousSession)
            $0.session = nil
        }
        await store.receive(\.inputCleanupFinished) { $0.pendingInputCleanup = nil }

        let entries = await log.entries
        expectNoDifference(entries, [
            "begin close-remote-session",
            "release input",
            "disconnect",
            "end close-remote-session"
        ])
    }

    private func connect(
        _ coordinator: DeviceSessionCoordinator,
        attemptID: UUID,
        session: DeviceSession
    ) async throws {
        var client = DeviceHubClient()
        client.connect = { _ in session }
        _ = try await coordinator.replace(attemptID: attemptID, deviceID: session.device.id, using: client)
    }

    private func loggingSession(
        device: DeviceSummary,
        log: ProtectionLog,
        sessionID: DeviceSessionID = DeviceSessionID(rawValue: fixtureUUID(102)),
        releaseFails: Bool = false
    ) -> DeviceSession {
        DeviceSession(
            id: sessionID, device: device,
            events: AsyncThrowingStream { _ in }, frames: AsyncStream { _ in },
            command: { command in
                guard command == .releaseAllInput else { return }
                await log.append("release input")
                if releaseFails {
                    throw DeviceHubError.secureConnectionFailed
                }
            },
            disconnect: { await log.append("disconnect") }
        )
    }
}

private extension BackgroundExecutionClient {
    static func logging(to log: ProtectionLog) -> Self {
        Self { name, work in
            await log.append("begin \(name)")
            await work()
            await log.append("end \(name)")
        }
    }
}

private actor ProtectionLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}
