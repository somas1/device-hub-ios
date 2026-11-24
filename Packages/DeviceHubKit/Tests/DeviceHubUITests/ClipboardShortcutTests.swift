import DeviceHubCore
@testable import DeviceHubUI
import Testing

struct ClipboardShortcutTests {
    @Test(
        "Each clipboard action sends one Command key tap",
        arguments: [
            (ClipboardShortcut.cut, DeviceKey.character("x")),
            (.copy, .character("c")),
            (.paste, .character("v"))
        ]
    )
    func sendsOneCommandTap(shortcut: ClipboardShortcut, expectedKey: DeviceKey) throws {
        var taps: [(DeviceKey, KeyModifiers)] = []

        shortcut.tap { taps.append(($0, $1)) }

        #expect(taps.count == 1)
        let tap = try #require(taps.first)
        #expect(tap.0 == expectedKey)
        #expect(tap.1 == .command)
    }
}
