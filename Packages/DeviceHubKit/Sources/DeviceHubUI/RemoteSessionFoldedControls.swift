import DeviceHubCore
import SwiftUI

// Direct controls exist only while an active native division overlaps the
// arrangement's available area. The arrangement itself owns pane placement;
// flat/cover displays and keyboard-constrained overlays keep only the menu.
#if os(iOS)
    @available(iOS 27.1, *)
    struct RemoteSessionControlSurface: View {
        let showsDirectControls: Bool
        let controls: RemoteSessionFoldedControls
        let menu: RemoteSessionMenu?

        var body: some View {
            ZStack {
                if showsDirectControls {
                    controls
                }

                Color.clear
                    .allowsHitTesting(false)
                    .overlay(alignment: .topTrailing) {
                        if let menu {
                            menu.equatable().padding(6)
                        }
                    }
            }
        }
    }
#endif

/// Shares the remote session's existing commands and keyboard intent. It owns
/// no connection, responder, input transform, or copy of the selected device.
struct RemoteSessionFoldedControls: View {
    let acceptsInput: Bool
    let isKeyboardPresented: Bool
    let home: () -> Void
    let lock: () -> Void
    let keyTapped: (DeviceKey, KeyModifiers) -> Void
    let keyboard: () -> Void
    let rotate: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Remote Controls")
                .font(.headline)

            ViewThatFits {
                HStack(spacing: 8) {
                    buttons
                }

                VStack(spacing: 8) {
                    HStack(spacing: 8) { hardwareButtons }
                    clipboardMenu
                    HStack(spacing: 8) { sessionButtons }
                }

                ScrollView {
                    VStack(spacing: 8) { buttons }
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!acceptsInput)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("folded-remote-controls")
    }

    @ViewBuilder
    private var buttons: some View {
        hardwareButtons
        clipboardMenu
        sessionButtons
    }

    @ViewBuilder
    private var hardwareButtons: some View {
        Button("Home", systemImage: "house", action: home)
        Button("Lock", systemImage: "lock", action: lock)
    }

    private var clipboardMenu: some View {
        Menu("Clipboard", systemImage: "doc.on.clipboard") {
            ClipboardShortcut.menuItems(keyTapped: keyTapped)
        }
    }

    @ViewBuilder
    private var sessionButtons: some View {
        Button("Keyboard", systemImage: "keyboard", action: keyboard)
            .accessibilityValue(isKeyboardPresented ? "Shown" : "Hidden")

        Button("Rotate", systemImage: "rotate.right", action: rotate)
    }
}

#if DEBUG
    #if os(iOS)
        @available(iOS 27.1, *)
        struct RemoteSessionControlSurface_Previews: PreviewProvider {
            static var previews: some View {
                example(appearance: .light, hasActiveDivision: false)
                example(appearance: .dark, hasActiveDivision: false)
                example(appearance: .light, hasActiveDivision: true)
                example(appearance: .dark, hasActiveDivision: true)
            }

            /// Explicitly cover the native arrangement's two presentation
            /// states without inventing hinge angles or device size classes.
            private static func example(appearance: ColorScheme, hasActiveDivision: Bool) -> some View {
                RemoteSessionControlSurface(
                    showsDirectControls: hasActiveDivision,
                    controls: RemoteSessionFoldedControls(
                        acceptsInput: true,
                        isKeyboardPresented: false,
                        home: {},
                        lock: {},
                        keyTapped: { _, _ in },
                        keyboard: {},
                        rotate: {}
                    ),
                    menu: RemoteSessionMenu(
                        acceptsInput: true,
                        isViewingStopped: false,
                        canStartViewing: false,
                        hasActiveSession: true,
                        hidesQuickControlItems: false,
                        devices: [],
                        selectedDeviceID: nil,
                        aboutButtonTapped: {},
                        buttonTapped: { _ in },
                        deviceSelected: { _ in },
                        detailsButtonTapped: {},
                        keyTapped: { _, _ in },
                        keyboardButtonTapped: {},
                        pairButtonTapped: {},
                        reconnectButtonTapped: {},
                        rotateButtonTapped: {},
                        startViewingButtonTapped: {},
                        stopViewingButtonTapped: {}
                    )
                )
                .preferredColorScheme(appearance)
                .frame(width: 680, height: 340)
            }
        }
    #endif

    #Preview("Connected", traits: .fixedLayout(width: 680, height: 340)) {
        RemoteSessionFoldedControls(
            acceptsInput: true,
            isKeyboardPresented: false,
            home: {},
            lock: {},
            keyTapped: { _, _ in },
            keyboard: {},
            rotate: {}
        )
        .preferredColorScheme(.light)
    }

    #Preview("Input unavailable", traits: .fixedLayout(width: 680, height: 340)) {
        RemoteSessionFoldedControls(
            acceptsInput: false,
            isKeyboardPresented: false,
            home: {},
            lock: {},
            keyTapped: { _, _ in },
            keyboard: {},
            rotate: {}
        )
        .preferredColorScheme(.dark)
    }
#endif
