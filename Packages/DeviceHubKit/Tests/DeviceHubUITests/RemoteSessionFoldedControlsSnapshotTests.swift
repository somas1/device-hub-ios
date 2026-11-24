#if os(iOS)
    @testable import DeviceHubUI
    import SnapshotTesting
    import SwiftUI
    import Testing
    import UIKit

    #if DEVICE_HUB_RECORD_SNAPSHOTS
        private let foldedSnapshotRecordMode: SnapshotTestingConfiguration.Record = .all
    #else
        private let foldedSnapshotRecordMode: SnapshotTestingConfiguration.Record = .never
    #endif

    @MainActor
    @Suite("Folded remote controls", .serialized, .snapshots(record: foldedSnapshotRecordMode))
    struct RemoteSessionFoldedControlsSnapshotTests {
        @Test("Controls fit their dedicated area in both appearances")
        func foldedControls() {
            for appearance in [ColorScheme.light, .dark] {
                for acceptsInput in [true, false] {
                    assertControls(
                        width: 680,
                        appearance: appearance,
                        acceptsInput: acceptsInput,
                        named: "\(appearance)-\(acceptsInput ? "enabled" : "disabled")"
                    )
                }
            }
        }

        @Test("All five controls fit a compact folded area")
        func compactFoldedControls() {
            assertControls(width: 393, appearance: .light, acceptsInput: true, named: "light-enabled")
        }

        private func assertControls(
            width: CGFloat,
            appearance: ColorScheme,
            acceptsInput: Bool,
            named name: String,
            testName: String = #function
        ) {
            let view = RemoteSessionFoldedControls(
                acceptsInput: acceptsInput,
                isKeyboardPresented: false,
                home: {},
                lock: {},
                keyTapped: { _, _ in },
                keyboard: {},
                rotate: {}
            )
            .preferredColorScheme(appearance)
            assertSnapshot(
                of: view,
                as: .image(
                    layout: .fixed(width: width, height: 300),
                    traits: UITraitCollection(userInterfaceStyle: appearance == .dark ? .dark : .light)
                ),
                named: name,
                testName: testName
            )
        }
    }
#endif
