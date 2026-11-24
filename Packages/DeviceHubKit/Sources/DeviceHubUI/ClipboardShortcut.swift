import DeviceHubCore
import SwiftUI

enum ClipboardShortcut: Character, CaseIterable {
    case cut = "x"
    case copy = "c"
    case paste = "v"

    private var label: (title: LocalizedStringKey, symbol: String) {
        switch self {
        case .cut: ("Cut", "scissors")
        case .copy: ("Copy", "doc.on.doc")
        case .paste: ("Paste", "doc.on.clipboard")
        }
    }

    func tap(using keyTapped: (DeviceKey, KeyModifiers) -> Void) {
        keyTapped(.character(rawValue), .command)
    }

    @MainActor
    static func menuItems(keyTapped: @escaping (DeviceKey, KeyModifiers) -> Void) -> some View {
        ForEach(allCases, id: \.self) { shortcut in
            let label = shortcut.label
            Button(label.title, systemImage: label.symbol) {
                shortcut.tap(using: keyTapped)
            }
        }
    }
}
