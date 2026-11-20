@testable import DeviceHubUI
import SwiftUI
import Testing

@MainActor
struct RemoteSessionQuickControlsTests {
    @Test("Only input availability changes quick control identity")
    func comparesInputAvailability() {
        let enabled = RemoteSessionQuickControls(acceptsInput: true, buttonTapped: { _ in }, rotateButtonTapped: {})
        let enabledAgain = RemoteSessionQuickControls(acceptsInput: true, buttonTapped: { _ in }, rotateButtonTapped: {})
        let disabled = RemoteSessionQuickControls(acceptsInput: false, buttonTapped: { _ in }, rotateButtonTapped: {})

        #expect(enabled == enabledAgain)
        #expect(enabled != disabled)
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
