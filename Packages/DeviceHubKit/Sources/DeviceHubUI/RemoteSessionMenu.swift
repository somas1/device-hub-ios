import DeviceHubCore
import SwiftUI

/// The corner menu carries session options and actions outside the quick controls.
struct RemoteSessionMenu: View, Equatable {
    enum ControlItem: CaseIterable {
        case home, lock, keyboard, rotate
    }

    let acceptsInput: Bool
    let isViewingStopped: Bool
    let canStartViewing: Bool
    let hasActiveSession: Bool
    /// Hides Home, Lock, Volume Up, Volume Down, and Mute when the bar shows them.
    let hidesQuickControlItems: Bool
    let devices: [DeviceSummary]
    let selectedDeviceID: DeviceID?
    let aboutButtonTapped: () -> Void
    let buttonTapped: (DeviceButton) -> Void
    let deviceSelected: (_ deviceID: DeviceID) -> Void
    let detailsButtonTapped: () -> Void
    let keyboardButtonTapped: () -> Void
    let pairButtonTapped: () -> Void
    let reconnectButtonTapped: () -> Void
    let rotateButtonTapped: () -> Void
    let startViewingButtonTapped: () -> Void
    let stopViewingButtonTapped: () -> Void

    var showsQuickControlItems: Bool {
        !hidesQuickControlItems
    }

    var controlItems: [ControlItem] {
        guard selectedDeviceID != nil else {
            return []
        }
        return showsQuickControlItems ? ControlItem.allCases : [.keyboard, .rotate]
    }

    /// Compares only what the menu shows. Its parent redraws on every video
    /// frame with fresh closures; treating those as changes rebuilt the menu
    /// while it was open.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.acceptsInput == rhs.acceptsInput
            && lhs.isViewingStopped == rhs.isViewingStopped
            && lhs.canStartViewing == rhs.canStartViewing
            && lhs.hasActiveSession == rhs.hasActiveSession
            && lhs.hidesQuickControlItems == rhs.hidesQuickControlItems
            && lhs.devices == rhs.devices
            && lhs.selectedDeviceID == rhs.selectedDeviceID
    }

    var body: some View {
        menu
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            .background(.black.opacity(0.58), in: .circle)
            .deviceHubOverlayGlass(in: .circle, interactive: true)
    }

    private var menu: some View {
        Menu {
            let items = controlItems
            if !items.isEmpty {
                Section("Controls") {
                    ForEach(items, id: \.self) { item in
                        switch item {
                        case .home:
                            Button("Home", systemImage: "house") { buttonTapped(.home) }
                        case .lock:
                            Button("Lock", systemImage: "lock") { buttonTapped(.lock) }
                        case .keyboard:
                            Button("Keyboard", systemImage: "keyboard", action: keyboardButtonTapped)
                        case .rotate:
                            Button("Rotate", systemImage: "rotate.right", action: rotateButtonTapped)
                        }
                    }
                }
                .disabled(!acceptsInput)
            }

            Section("Devices") {
                if !devices.isEmpty {
                    Menu("Choose Device", systemImage: "ipad.and.iphone") {
                        ForEach(devices) { device in
                            Button {
                                deviceSelected(device.id)
                            } label: {
                                Label(
                                    device.name,
                                    systemImage: device.id == selectedDeviceID
                                        ? "checkmark"
                                        : device.deviceHubAvailabilitySymbol
                                )
                            }
                        }
                    }
                }

                Button("Pair Nearby Device", systemImage: "plus", action: pairButtonTapped)
            }

            Section("Device Hub") {
                Button(
                    "About Device Hub",
                    systemImage: "info.circle",
                    action: aboutButtonTapped
                )
            }

            if acceptsInput {
                Section("Hardware") {
                    if showsQuickControlItems {
                        // Keep the menu open for repeated volume adjustments.
                        Group {
                            Button("Volume Up", systemImage: "speaker.plus") {
                                buttonTapped(.volumeUp)
                            }
                            Button("Volume Down", systemImage: "speaker.minus") {
                                buttonTapped(.volumeDown)
                            }
                            Button("Mute", systemImage: "speaker.slash") {
                                buttonTapped(.mute)
                            }
                        }
                        #if !os(macOS)
                        // Unavailable on macOS, where the package's tests build.
                        .menuActionDismissBehavior(.disabled)
                        #endif
                    }
                    Button("Siri", systemImage: "waveform") {
                        buttonTapped(.siri)
                    }
                }
            }

            Section("Session") {
                if selectedDeviceID != nil {
                    Button(
                        "Device Details",
                        systemImage: "info.circle",
                        action: detailsButtonTapped
                    )
                }

                if isViewingStopped {
                    Button(
                        "Start Viewing",
                        systemImage: "play",
                        action: startViewingButtonTapped
                    )
                    .disabled(!canStartViewing)
                } else if hasActiveSession {
                    Button(
                        "Reconnect",
                        systemImage: "arrow.clockwise",
                        action: reconnectButtonTapped
                    )
                    Button(
                        "Stop Viewing",
                        systemImage: "stop",
                        role: .destructive,
                        action: stopViewingButtonTapped
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .frame(
                    width: 44,
                    height: 44
                )
                .contentShape(.circle)
        }
        .accessibilityLabel("More Controls")
    }
}
