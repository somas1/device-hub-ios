import DeviceHubCore
import SwiftUI

enum ClipboardShortcut: Character, CaseIterable {
    case cut = "x"
    case copy = "c"
    case paste = "v"

    var title: LocalizedStringKey {
        switch self {
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        }
    }

    var symbol: String {
        switch self {
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        }
    }

    func tap(using keyTapped: (DeviceKey, KeyModifiers) -> Void) {
        keyTapped(.character(rawValue), .command)
    }

    @MainActor
    static func menuItems(keyTapped: @escaping (DeviceKey, KeyModifiers) -> Void) -> some View {
        ForEach(allCases, id: \.self) { shortcut in
            Button(shortcut.title, systemImage: shortcut.symbol) {
                shortcut.tap(using: keyTapped)
            }
        }
    }
}
