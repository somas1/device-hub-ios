#if os(iOS)
    import DeviceHubCore
    @testable import DeviceHubUI
    import Testing
    import UIKit

    @MainActor
    @Suite("Device keyboard pressed-key ownership")
    struct DeviceKeyboardReceiverTests {
        @Test("hidden keyboard responder never enters the accessibility tree")
        func responderIsAccessibilityHidden() {
            let textField = DeviceKeyboardTextField()

            #expect(!textField.isAccessibilityElement)
            #expect(textField.accessibilityElementsHidden)
        }

        @Test("software text emits semantic taps without synthetic key edges")
        func softwareTextTaps() {
            let textField = DeviceKeyboardTextField()
            var edgeCommands: [KeyCommand] = []
            var tappedKeys: [DeviceKey] = []
            var tappedModifiers: [KeyModifiers] = []
            textField.onKeyChanged = {
                edgeCommands.append($0)
            }
            textField.onKeyTapped = { key, modifiers in
                tappedKeys.append(key)
                tappedModifiers.append(modifiers)
            }

            textField.insertText("a ")
            textField.deleteBackward()

            #expect(
                tappedKeys
                    == [
                        .character("a"),
                        .space,
                        .delete
                    ]
            )
            let modifiersAreEmpty = tappedModifiers.allSatisfy(\.isEmpty)
            #expect(modifiersAreEmpty)
            #expect(edgeCommands.isEmpty)
        }

        @Test(
            "hardware editing shortcuts send exactly one modified key tap",
            arguments: ["c", "v", "x", "a", "z"], [false, true]
        )
        func hardwareEditingShortcuts(input: String, softwareKeyboardShown: Bool) throws {
            let textField = DeviceKeyboardTextField()
            textField.setSoftwareKeyboardShown(softwareKeyboardShown)
            var taps: [DeviceCommand] = []
            textField.onKeyTapped = { taps.append(.keyTap($0, modifiers: $1)) }

            let command = try shortcut(input, modifiers: .command, in: textField)
            let action = try #require(command.action)
            let paste = #selector(UIResponderStandardEditActions.paste(_:))
            try #require(action != paste)
            #expect(!textField.canPerformAction(paste, withSender: command))
            #expect(textField.canPerformAction(action, withSender: command))
            _ = textField.perform(action, with: command)

            #expect(taps == [.keyTap(.character(Character(input)), modifiers: .command)])
            #expect(textField.text?.isEmpty != false)
        }

        @Test("hardware redo keeps Shift and Control chords keep Control")
        func additionalShortcutModifiers() throws {
            let textField = DeviceKeyboardTextField()
            var taps: [DeviceCommand] = []
            textField.onKeyTapped = { taps.append(.keyTap($0, modifiers: $1)) }

            let redo = try shortcut("z", modifiers: [.command, .shift], in: textField)
            let control = try shortcut("/", modifiers: .control, in: textField)
            _ = try textField.perform(#require(redo.action), with: redo)
            _ = try textField.perform(#require(control.action), with: control)

            #expect(taps == [
                .keyTap(.character("z"), modifiers: [.command, .shift]),
                .keyTap(.character("/"), modifiers: .control)
            ])
        }

        @Test("plain letters and unsupported shortcut inputs stay out of the shortcut path")
        func unsupportedShortcutInputsLeaveTypingAvailable() throws {
            let textField = DeviceKeyboardTextField()
            var taps: [DeviceCommand] = []
            textField.onKeyTapped = { taps.append(.keyTap($0, modifiers: $1)) }
            let supportedCommand = try shortcut("c", modifiers: .command, in: textField)
            let action = try #require(supportedCommand.action)

            let ignoredInputs: [(String, UIKeyModifierFlags)] = [
                ("a", []), ("é", .command), ("\t", .control), ("ab", .command)
            ]
            for (input, modifiers) in ignoredInputs {
                let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
                _ = textField.perform(action, with: command)
            }
            #expect(taps.isEmpty)

            let shouldInsert = textField.delegate?.textField?(
                textField,
                shouldChangeCharactersIn: NSRange(location: 0, length: 0),
                replacementString: "a"
            )
            #expect(shouldInsert == false)
            #expect(taps == [.keyTap(.character("a"), modifiers: [])])
        }

        @available(iOS, deprecated: 26.0, message: "Exercises pre-scene responder attachment.")
        @Test("a shortcut yields to a covering sheet or alert")
        func coveredShortcut() throws {
            let window = UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            let controller = KeyboardCoverViewController()
            let textField = DeviceKeyboardTextField()
            window.rootViewController = controller
            controller.view.addSubview(textField)
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try #require(textField.window === window)
            var taps: [DeviceCommand] = []
            textField.onKeyTapped = { taps.append(.keyTap($0, modifiers: $1)) }
            let command = try shortcut("v", modifiers: .command, in: textField)

            controller.isCovered = true
            _ = try textField.perform(#require(command.action), with: command)

            #expect(taps.isEmpty)
        }

        private func shortcut(
            _ input: String,
            modifiers: UIKeyModifierFlags,
            in textField: DeviceKeyboardTextField
        ) throws -> UIKeyCommand {
            try #require(textField.keyCommands?.first {
                $0.input == input && $0.modifierFlags == modifiers && $0.wantsPriorityOverSystemBehavior
            })
        }

        @Test("closing releases held keys once in reverse press order")
        func releaseAll() {
            var ledger = DeviceKeyboardPressedKeyLedger()

            let escapePress = ledger.press(
                usage: .keyboardEscape,
                key: .escape,
                modifiers: [.command]
            )
            #expect(
                escapePress
                    == KeyCommand(
                        key: .escape,
                        phase: .press,
                        modifiers: [.command]
                    )
            )
            let tabPress = ledger.press(
                usage: .keyboardTab,
                key: .tab,
                modifiers: [.shift]
            )
            #expect(
                tabPress
                    == KeyCommand(
                        key: .tab,
                        phase: .press,
                        modifiers: [.shift]
                    )
            )
            let releases = ledger.releaseAll()
            #expect(
                releases
                    == [
                        KeyCommand(
                            key: .tab,
                            phase: .release,
                            modifiers: [.shift]
                        ),
                        KeyCommand(
                            key: .escape,
                            phase: .release,
                            modifiers: [.command]
                        )
                    ]
            )
            let repeatedReleases = ledger.releaseAll()
            #expect(repeatedReleases.isEmpty)
        }

        @Test("duplicate presses and already-released keys never double-send")
        func duplicateAndIndividualRelease() {
            var ledger = DeviceKeyboardPressedKeyLedger()

            _ = ledger.press(
                usage: .keyboardLeftArrow,
                key: .leftArrow,
                modifiers: []
            )
            let duplicatePress = ledger.press(
                usage: .keyboardLeftArrow,
                key: .leftArrow,
                modifiers: []
            )
            #expect(duplicatePress == nil)
            let release = ledger.release(usage: .keyboardLeftArrow)
            #expect(
                release
                    == KeyCommand(
                        key: .leftArrow,
                        phase: .release,
                        modifiers: []
                    )
            )
            let repeatedRelease = ledger.release(
                usage: .keyboardLeftArrow
            )
            #expect(repeatedRelease == nil)
            let trailingReleases = ledger.releaseAll()
            #expect(trailingReleases.isEmpty)
        }
    }

    private final class KeyboardCoverViewController: UIViewController {
        var isCovered = false

        override var presentedViewController: UIViewController? {
            isCovered ? UIViewController() : nil
        }
    }
#endif
