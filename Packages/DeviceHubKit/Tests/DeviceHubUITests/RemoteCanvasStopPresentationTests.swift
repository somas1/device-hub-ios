import DeviceHubCore
import DeviceHubFeature
@testable import DeviceHubUI
import Foundation
import Testing

@MainActor
@Suite("Stopped canvas actions")
struct RemoteCanvasStopPresentationTests {
    @Test("Cleanup status takes precedence over device selection", arguments: [false, true])
    func cleanupStatus(hasDevice: Bool) {
        let device = target()
        var state = stoppedState(device: hasDevice ? device : nil)
        state.pendingInputCleanup = InputCleanupOwnership(session: ActiveRemoteSession(
            attemptID: UUID(),
            device: device,
            evaluatedAt: Date(timeIntervalSince1970: 0)
        ))
        let pending = content(for: state)
        #expect(pending.message == "Viewing is paused. Waiting for input cleanup to finish.")
        #expect(pending.actionTitle == nil)

        state.pendingInputCleanup = nil
        state.inputCleanupFailed = true
        let failed = content(for: state)
        #expect(failed.message == "Viewing is paused. Input release is unconfirmed; check the device before trying again.")
        #expect(failed.actionTitle == nil)
    }

    @Test("The stopped canvas explains what is needed before Start")
    func selectionAndLifecycle() {
        let noDevice = content(for: stoppedState(device: nil))
        #expect(noDevice.message == "Choose or pair a device before resuming.")
        #expect(noDevice.actionTitle == nil)

        let unpaired = content(for: stoppedState(device: target(pairingState: .requiresPairing)))
        #expect(unpaired.message == "Pair this device, then choose Start Viewing to resume.")
        #expect(unpaired.actionTitle == nil)

        var state = stoppedState(device: target())
        let paired = content(for: state)
        #expect(paired.message == "Viewing stays paused until you choose Start Viewing. The device must be available to connect.")
        #expect(paired.actionTitle == "Start Viewing")

        state.lifecycle = .inactive
        #expect(content(for: state).actionTitle == nil)
    }

    private func target(pairingState: DevicePairingState = .paired) -> DeviceSummary {
        DeviceSummary(
            id: DeviceID(rawValue: "stopped-canvas"),
            name: "Synthetic target",
            productType: "iPhone17,4",
            operatingSystemVersion: nil,
            pairingState: pairingState,
            reachability: .unavailable
        )
    }

    private func stoppedState(device: DeviceSummary?) -> RemoteSessionFeature.State {
        RemoteSessionFeature.State(
            isViewingStopped: true,
            roster: DeviceRoster(devices: device.map { [$0] } ?? []),
            selectedDeviceID: device?.id
        )
    }

    private func content(for state: RemoteSessionFeature.State) -> (message: String, actionTitle: String?) {
        RemoteCanvas.stoppedViewingContent(
            canStartViewing: state.canStartViewing,
            isInputCleanupPending: state.pendingInputCleanup != nil,
            isInputCleanupFailed: state.inputCleanupFailed,
            pairingState: state.selectedDevice?.pairingState
        )
    }
}
