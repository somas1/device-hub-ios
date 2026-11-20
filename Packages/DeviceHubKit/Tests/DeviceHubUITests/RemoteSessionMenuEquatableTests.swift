import DeviceHubCore
@testable import DeviceHubUI
import Testing

/// The menu's parent redraws on every video frame. The menu must compare
/// equal across those redraws so SwiftUI leaves an open menu alone.
@MainActor
@Suite("More menu identity across redraws")
struct RemoteSessionMenuEquatableTests {
    @Test("Fresh closures alone do not make the menu different")
    func sameContentIsEqual() {
        #expect(menu() == menu())
    }

    @Test("Each piece of visible content makes the menu different")
    func changedContentIsDifferent() {
        #expect(menu() != menu(acceptsInput: false))
        #expect(menu() != menu(isViewingStopped: true))
        #expect(menu() != menu(canStartViewing: false))
        #expect(menu() != menu(hasActiveSession: false))
        #expect(menu() != menu(devices: []))
        #expect(menu() != menu(selectedDeviceID: nil))
        #expect(menu() != menu(showsQuickControls: true))
    }

    @Test("More exposes the six actions only when the bar is hidden")
    func quickControlItemsFollowBarVisibility() {
        #expect(menu(showsQuickControls: false).showsQuickControlItems)
        #expect(!menu(showsQuickControls: true).showsQuickControlItems)
    }

    private static let target = DeviceSummary(
        id: DeviceID(rawValue: "menu-target"),
        name: "Synthetic target",
        productType: "iPad16,3",
        operatingSystemVersion: nil,
        pairingState: .paired,
        reachability: .reachable
    )

    private func menu(
        acceptsInput: Bool = true,
        isViewingStopped: Bool = false,
        canStartViewing: Bool = true,
        hasActiveSession: Bool = true,
        showsQuickControls: Bool = false,
        devices: [DeviceSummary] = [target],
        selectedDeviceID: DeviceID? = target.id
    ) -> RemoteSessionMenu {
        RemoteSessionMenu(
            acceptsInput: acceptsInput,
            isViewingStopped: isViewingStopped,
            canStartViewing: canStartViewing,
            hasActiveSession: hasActiveSession,
            showsQuickControls: showsQuickControls,
            devices: devices,
            selectedDeviceID: selectedDeviceID,
            aboutButtonTapped: {},
            buttonTapped: { _ in },
            deviceSelected: { _ in },
            detailsButtonTapped: {},
            keyboardButtonTapped: {},
            pairButtonTapped: {},
            reconnectButtonTapped: {},
            rotateButtonTapped: {},
            startViewingButtonTapped: {},
            stopViewingButtonTapped: {}
        )
    }
}
