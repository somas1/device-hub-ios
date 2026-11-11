import Dependencies

/// Keeps the process running while cleanup finishes after the app leaves the
/// foreground.
///
/// Leaving the foreground must release held remote input and stop the media
/// stream; without protected background time the process can be suspended
/// before either reaches the device, leaving a finger down or the iPhone's
/// audio routed into a dead stream. The app installs a UIKit-backed value;
/// the default just runs the work.
public struct BackgroundExecutionClient: Sendable {
    public var protect: @Sendable (
        _ name: String,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Void

    public init(
        protect: @escaping @Sendable (
            _ name: String,
            _ work: @escaping @Sendable () async -> Void
        ) async -> Void
    ) {
        self.protect = protect
    }
}

extension BackgroundExecutionClient: DependencyKey {
    public static let liveValue = Self { _, work in
        await work()
    }

    public static let testValue = liveValue
}

public extension DependencyValues {
    var backgroundExecution: BackgroundExecutionClient {
        get { self[BackgroundExecutionClient.self] }
        set { self[BackgroundExecutionClient.self] = newValue }
    }
}
