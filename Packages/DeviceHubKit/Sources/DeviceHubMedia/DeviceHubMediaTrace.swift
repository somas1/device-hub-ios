import Foundation
import Synchronization

/// Shared by the native ingress and all decoders in one stream generation.
package final class VideoConsumerLag: Sendable {
    private let lag = Atomic(0)

    package init() {}

    package var count: Int {
        lag.load(ordering: .relaxed)
    }

    package func admit() {
        lag.wrappingAdd(1, ordering: .relaxed)
    }

    func submit() {
        lag.wrappingSubtract(1, ordering: .relaxed)
    }
}

/// Emits opt-in, payload-free decoder milestones for physical-device diagnosis.
package enum DeviceHubMediaTrace {
    package static let isEnabled = ProcessInfo.processInfo.environment[
        "DEVICE_HUB_BOOTSTRAP_TRACE"
    ] == "1"

    static func emit(_ message: String) {
        guard isEnabled else {
            return
        }
        FileHandle.standardOutput.write(
            Data("devicehub.media \(message)\n".utf8)
        )
    }
}
