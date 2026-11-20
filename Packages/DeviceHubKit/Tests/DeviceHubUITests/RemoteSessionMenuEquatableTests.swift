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
        #expect(menu() != menu(hidesQuickControlItems: true))
    }

    @Test("More hides the five quick actions while the bar is visible")
    func quickControlItemsFollowBarVisibility() {
        #expect(menu(hidesQuickControlItems: false).showsQuickControlItems)
        #expect(!menu(hidesQuickControlItems: true).showsQuickControlItems)
    }

    @Test("More keeps Rotate after Keyboard in both layouts")
    func rotateStaysInMore() {
        #expect(menu(hidesQuickControlItems: false).controlItems == [.home, .lock, .keyboard, .rotate])
        #expect(menu(hidesQuickControlItems: true).controlItems == [.keyboard, .rotate])
        #expect(menu(acceptsInput: false, hidesQuickControlItems: true).controlItems == [.keyboard, .rotate])
        #expect(menu(selectedDeviceID: nil).controlItems.isEmpty)
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
        hidesQuickControlItems: Bool = false,
        devices: [DeviceSummary] = [target],
        selectedDeviceID: DeviceID? = target.id
    ) -> RemoteSessionMenu {
        RemoteSessionMenu(
            acceptsInput: acceptsInput,
            isViewingStopped: isViewingStopped,
            canStartViewing: canStartViewing,
            hasActiveSession: hasActiveSession,
            hidesQuickControlItems: hidesQuickControlItems,
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
