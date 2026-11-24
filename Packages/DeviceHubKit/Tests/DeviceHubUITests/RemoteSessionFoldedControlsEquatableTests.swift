@testable import DeviceHubUI
import Testing

/// The folded controls' parent redraws on every video frame. They must compare
/// equal across those redraws so SwiftUI leaves an open Clipboard menu alone.
@MainActor
@Suite("Folded controls identity across redraws")
struct RemoteSessionFoldedControlsEquatableTests {
    @Test("Fresh closures alone do not make the controls different")
    func sameContentIsEqual() {
        #expect(controls() == controls())
    }

    @Test("Each piece of visible content makes the controls different")
    func changedContentIsDifferent() {
        #expect(controls() != controls(acceptsInput: false))
        #expect(controls() != controls(isKeyboardPresented: true))
    }

    private func controls(
        acceptsInput: Bool = true,
        isKeyboardPresented: Bool = false
    ) -> RemoteSessionFoldedControls {
        RemoteSessionFoldedControls(
            acceptsInput: acceptsInput,
            isKeyboardPresented: isKeyboardPresented,
            home: {},
            lock: {},
            keyTapped: { _, _ in },
            keyboard: {},
            rotate: {}
        )
    }
}
