@testable import DeviceHubUI
import SwiftUI
import Testing

@MainActor
struct RemoteSessionQuickControlsTests {
    @Test("Only input availability changes quick control identity")
    func comparesInputAvailability() {
        let enabled = RemoteSessionQuickControls(acceptsInput: true, buttonTapped: { _ in }, keyTapped: { _, _ in })
        let enabledAgain = RemoteSessionQuickControls(acceptsInput: true, buttonTapped: { _ in }, keyTapped: { _, _ in })
        let disabled = RemoteSessionQuickControls(acceptsInput: false, buttonTapped: { _ in }, keyTapped: { _, _ in })

        #expect(enabled == enabledAgain)
        #expect(enabled != disabled)
    }

    @Test("The bar fits eight 44-point controls with seven gaps")
    func fitsEightControls() {
        let controls = RemoteSessionQuickControls(acceptsInput: true, buttonTapped: { _ in }, keyTapped: { _, _ in })

        #expect(ImageRenderer(content: controls).cgImage?.width == 8 * 44 + 7 * 8)
    }

    @Test("Cut, Copy and Paste each have their own bar button")
    func clipboardButtons() {
        #expect(ClipboardShortcut.allCases.map(\.symbol) == ["scissors", "doc.on.doc", "doc.on.clipboard"])
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
