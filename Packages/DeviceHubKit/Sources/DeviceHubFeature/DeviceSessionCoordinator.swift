import DeviceHubClient
import DeviceHubCore
import Foundation

/// Serializes ownership changes around the one active transport session.
///
/// This imperative shell is intentionally actor-isolated. Attempt-scoped
/// ownership prevents stale effects from disconnecting a newer target, and
/// media-scoped revocation prevents late commands from crossing a cleanup
/// barrier after input authorization has been withdrawn.
actor DeviceSessionCoordinator {
    private struct OwnedSession {
        let attemptID: UUID
        var revokedInputMetadata: ScreenMetadata?
        var cleanupFailure: DeviceHubError?
        let session: DeviceSession
    }

    private var activeSession: OwnedSession?
    private var latestAttemptID: UUID?
    private var closingSession: (attemptID: UUID, task: Task<Void, Error>)?

    func command(
        _ command: DeviceCommand,
        attemptID: UUID,
        sessionID: DeviceSessionID,
        authorization: ScreenMetadata
    ) async throws {
        guard let activeSession,
              activeSession.attemptID == attemptID,
              activeSession.session.id == sessionID
        else {
            throw DeviceHubError.connectionLost
        }
        guard activeSession.revokedInputMetadata != authorization else {
            throw CancellationError()
        }
        try await activeSession.session.command(command)
    }

    /// Revokes one exact media authorization and enqueues the cleanup barrier.
    func releaseAllInput(
        attemptID: UUID,
        sessionID: DeviceSessionID,
        revoking authorization: ScreenMetadata
    ) async -> DeviceHubError? {
        guard var activeSession,
              activeSession.attemptID == attemptID,
              activeSession.session.id == sessionID
        else {
            return nil
        }
        guard activeSession.revokedInputMetadata != authorization else {
            return nil
        }
        activeSession.revokedInputMetadata = authorization
        self.activeSession = activeSession

        do {
            try await activeSession.session.command(.releaseAllInput)
            return nil
        } catch {
            if self.activeSession?.attemptID == attemptID {
                self.activeSession?.cleanupFailure = .inputCleanupFailed
            }
            return .inputCleanupFailed
        }
    }

    /// Every caller shares the same release/disconnect task and retained outcome.
    func close(attemptID: UUID) async throws {
        if latestAttemptID == attemptID {
            latestAttemptID = nil
        }
        if let closingSession, closingSession.attemptID == attemptID {
            try await closingSession.task.value
            return
        }
        guard let owned = activeSession, owned.attemptID == attemptID else { return }
        activeSession = nil
        let task = Task<Void, Error> {
            var failure = owned.cleanupFailure
            do {
                try await owned.session.command(.releaseAllInput)
            } catch {
                failure = failure ?? .inputCleanupFailed
            }
            do {
                try await owned.session.disconnect()
            } catch {
                failure = failure ?? .inputCleanupFailed
            }
            if let failure {
                throw failure
            }
        }
        closingSession = (attemptID, task)
        try await task.value
    }

    /// Only an explicit acknowledged Retry may discard a settled old outcome.
    func acknowledgeCleanupFailure() async {
        guard let closingSession else { return }
        _ = await closingSession.task.result
        self.closingSession = nil
    }

    func replace(
        attemptID: UUID,
        deviceID: DeviceID,
        using client: DeviceHubClient
    ) async throws -> DeviceSession {
        try Task.checkCancellation()
        if let activeSession {
            try await close(attemptID: activeSession.attemptID)
        }
        if let closingSession {
            try await closingSession.task.value
        }
        try Task.checkCancellation()
        latestAttemptID = attemptID
        let session = try await client.connect(deviceID)
        guard !Task.isCancelled, latestAttemptID == attemptID else {
            try await session.disconnect()
            throw CancellationError()
        }
        guard activeSession == nil else {
            try await session.disconnect()
            throw DeviceHubError.connectionLost
        }
        activeSession = OwnedSession(attemptID: attemptID, revokedInputMetadata: nil, cleanupFailure: nil, session: session)
        return session
    }
}
