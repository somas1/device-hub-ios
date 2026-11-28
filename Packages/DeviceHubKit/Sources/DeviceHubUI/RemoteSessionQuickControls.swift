import DeviceHubCore
import SwiftUI

struct RemoteSessionQuickControls: View, Equatable {
    let acceptsInput: Bool
    let buttonTapped: (DeviceButton) -> Void
    let keyTapped: (DeviceKey, KeyModifiers) -> Void

    /// Ignore action closures recreated by the parent on each video frame.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.acceptsInput == rhs.acceptsInput
    }

    var body: some View {
        HStack(spacing: 8) {
            button("Home", symbol: "house") { buttonTapped(.home) }
            button("Lock", symbol: "lock") { buttonTapped(.lock) }
            button("Volume Up", symbol: "speaker.plus") { buttonTapped(.volumeUp) }
            button("Volume Down", symbol: "speaker.minus") { buttonTapped(.volumeDown) }
            button("Mute", symbol: "speaker.slash") { buttonTapped(.mute) }
            // Plain buttons, not a menu: on a headset an open menu here does
            // not stay usable while video is live.
            ForEach(ClipboardShortcut.allCases, id: \.self) { shortcut in
                button(shortcut.title, symbol: shortcut.symbol) { shortcut.tap(using: keyTapped) }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(acceptsInput ? 0.85 : 0.4))
        .disabled(!acceptsInput)
        .background(.black.opacity(0.58), in: .capsule)
    }

    private func button(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(title))
        .accessibilityHint(acceptsInput ? Text("") : Text("Available when the remote screen is live."))
    }
}
