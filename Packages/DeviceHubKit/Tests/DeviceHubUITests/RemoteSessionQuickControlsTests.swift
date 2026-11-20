@testable import DeviceHubUI
import SwiftUI
import Testing

@MainActor
struct RemoteSessionQuickControlsTests {
    @Test("Only input availability changes quick control identity")
    func comparesInputAvailability() {
        let enabled = RemoteSessionQuickControls(acceptsInput: true, buttonTapped: { _ in })
        let enabledAgain = RemoteSessionQuickControls(acceptsInput: true, buttonTapped: { _ in })
        let disabled = RemoteSessionQuickControls(acceptsInput: false, buttonTapped: { _ in })

        #expect(enabled == enabledAgain)
        #expect(enabled != disabled)
    }

    @Test("The bar fits five 44-point buttons with four gaps")
    func fitsFiveButtons() {
        let controls = RemoteSessionQuickControls(acceptsInput: true, buttonTapped: { _ in })

        #expect(ImageRenderer(content: controls).cgImage?.width == 5 * 44 + 4 * 8)
    }

    @Test("Quick controls require regular width and a selected device")
    func visibilityFollowsSizeClassAndSelection() {
        #expect(RemoteSessionView.showsQuickControls(horizontalSizeClass: .regular, hasSelectedDevice: true))
        #expect(!RemoteSessionView.showsQuickControls(horizontalSizeClass: .regular, hasSelectedDevice: false))
        #expect(!RemoteSessionView.showsQuickControls(horizontalSizeClass: .compact, hasSelectedDevice: true))
        #expect(!RemoteSessionView.showsQuickControls(horizontalSizeClass: .compact, hasSelectedDevice: false))
        #expect(!RemoteSessionView.showsQuickControls(horizontalSizeClass: nil, hasSelectedDevice: true))
    }
}
