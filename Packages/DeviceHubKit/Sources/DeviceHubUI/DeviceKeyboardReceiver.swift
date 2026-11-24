import DeviceHubCore
import SwiftUI

/// Zero-content responder that forwards keyboard edges without retaining text.
///
/// Software and hardware keyboard input is emitted directly as semantic key
/// commands. Typed characters never enter SwiftUI state, persistence, logs, or
/// automatic clipboard synchronization.
struct DeviceKeyboardReceiver: View {
    @Binding var isPresented: Bool
    var focusRequest = 0

    let keyChanged: (KeyCommand) -> Void
    let keyTapped: (DeviceKey, KeyModifiers) -> Void

    var body: some View {
        #if os(iOS)
            DeviceKeyboardTextFieldRepresentable(
                isPresented: $isPresented,
                focusRequest: focusRequest,
                keyChanged: keyChanged,
                keyTapped: keyTapped
            )
        #else
            EmptyView()
        #endif
    }
}

#if os(iOS)
    import UIKit

    private struct DeviceKeyboardTextFieldRepresentable: UIViewRepresentable {
        @Binding var isPresented: Bool
        let focusRequest: Int

        let keyChanged: (KeyCommand) -> Void
        let keyTapped: (DeviceKey, KeyModifiers) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(
                isPresented: $isPresented,
                keyChanged: keyChanged,
                keyTapped: keyTapped
            )
        }

        func makeUIView(context: Context) -> DeviceKeyboardTextField {
            let textField = DeviceKeyboardTextField()
            textField.setSoftwareKeyboardShown(false)
            textField.onDone = context.coordinator.doneButtonTapped
            textField.onKeyChanged = context.coordinator.keyChanged
            textField.onKeyTapped = context.coordinator.keyTapped
            return textField
        }

        func updateUIView(
            _ textField: DeviceKeyboardTextField,
            context: Context
        ) {
            context.coordinator.isPresented = $isPresented
            context.coordinator.keyChanged = keyChanged
            context.coordinator.keyTapped = keyTapped

            // Canvas interaction and opening the software keyboard are explicit
            // requests; streaming updates leave the current focus owner alone.
            if context.coordinator.focusRequest != focusRequest
                || (isPresented && textField.inputView != nil)
            {
                if !textField.isFirstResponder {
                    textField.setPresented(false)
                }
                context.coordinator.focusRequest = focusRequest
            }
            textField.setSoftwareKeyboardShown(isPresented)
            textField.setPresented(true)
        }

        static func dismantleUIView(
            _ textField: DeviceKeyboardTextField,
            coordinator: Coordinator
        ) {
            textField.setPresented(false)
        }

        @MainActor
        final class Coordinator {
            var isPresented: Binding<Bool>
            var focusRequest = 0
            var keyChanged: (KeyCommand) -> Void
            var keyTapped: (DeviceKey, KeyModifiers) -> Void

            init(
                isPresented: Binding<Bool>,
                keyChanged: @escaping (KeyCommand) -> Void,
                keyTapped: @escaping (DeviceKey, KeyModifiers) -> Void
            ) {
                self.isPresented = isPresented
                self.keyChanged = keyChanged
                self.keyTapped = keyTapped
            }

            func doneButtonTapped() {
                isPresented.wrappedValue = false
            }
        }
    }

    @MainActor
    final class DeviceKeyboardTextField: UITextField, UITextFieldDelegate {
        var onDone: () -> Void = {}
        var onKeyChanged: (KeyCommand) -> Void = { _ in }
        var onKeyTapped: (DeviceKey, KeyModifiers) -> Void = { _, _ in }

        private var isPresentationRequested = false
        private var isFocusSuspended = false
        private lazy var accessoryToolbar = makeAccessoryToolbar()
        private var isReacquireScheduled = false
        var pressedSpecialKeys = DeviceKeyboardPressedKeyLedger()

        private static let printableASCII: ClosedRange<UInt8> = 0x20 ... 0x7E
        private lazy var hardwareShortcutCommands: [UIKeyCommand] = {
            // Register lowercase letter equivalents and carry Shift in the flags.
            let inputs = Self.printableASCII
                .filter { !(0x41 ... 0x5A).contains($0) }
                .map { String(UnicodeScalar($0)) }
            let requiredModifiers: [UIKeyModifierFlags] = [.command, .control, [.command, .control]]
            let extraModifiers: [UIKeyModifierFlags] = [[], .shift, .alternate, [.shift, .alternate]]

            return requiredModifiers.flatMap { required in
                extraModifiers.flatMap { extra in
                    inputs.map { input in
                        let command = UIKeyCommand(
                            input: input,
                            modifierFlags: required.union(extra),
                            action: #selector(forwardHardwareShortcut(_:))
                        )
                        // Let the chord reach the remote before UIKit handles local edits.
                        command.wantsPriorityOverSystemBehavior = true
                        command.allowsAutomaticLocalization = false
                        command.allowsAutomaticMirroring = false
                        return command
                    }
                }
            }
        }()

        override var keyCommands: [UIKeyCommand]? {
            hardwareShortcutCommands + (super.keyCommands ?? [])
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
            // Hardware focus starts with a session, so a held key must not
            // outlive this window's or scene's keyboard focus.
            // ponytail: releases on any scene/window, harmless when nothing is held.
            for name in [UIScene.willDeactivateNotification, UIWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(focusLost),
                    name: name,
                    object: nil
                )
            }
        }

        @objc private func focusLost() {
            releasePressedSpecialKeys()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("DeviceKeyboardTextField is created programmatically.")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            synchronizePresentation()
        }

        override func deleteBackward() {
            guard !yieldIfCovered() else {
                return
            }
            tap(.delete)
        }

        override func resignFirstResponder() -> Bool {
            let heldFocus = isFirstResponder
            releasePressedSpecialKeys()
            let resigned = super.resignFirstResponder()
            if resigned, heldFocus, isPresentationRequested, window != nil {
                if isCovered {
                    // A sheet or alert may take focus itself; win it back once it closes.
                    scheduleReacquire()
                } else {
                    isFocusSuspended = true
                    if inputView == nil {
                        onDone()
                    }
                }
            }
            return resigned
        }

        override func pressesBegan(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            guard !yieldIfCovered() else {
                super.pressesBegan(presses, with: event)
                return
            }
            var unhandledPresses: Set<UIPress> = []

            for press in presses {
                guard let key = press.key,
                      let deviceKey = specialKey(for: key.keyCode)
                else {
                    unhandledPresses.insert(press)
                    continue
                }
                let modifiers = key.modifierFlags.deviceHubModifiers
                if let command = pressedSpecialKeys.press(
                    usage: key.keyCode,
                    key: deviceKey,
                    modifiers: modifiers
                ) {
                    onKeyChanged(command)
                }
            }

            if !unhandledPresses.isEmpty {
                super.pressesBegan(unhandledPresses, with: event)
            }
        }

        override func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            release(presses)
            super.pressesCancelled(presses, with: event)
        }

        override func pressesEnded(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            release(presses)
            super.pressesEnded(presses, with: event)
        }

        func releasePressedSpecialKeys() {
            for command in pressedSpecialKeys.releaseAll() {
                onKeyChanged(command)
            }
        }

        /// Only explicit edit-menu Paste with the software keyboard shown may
        /// type the controller clipboard. Hardware shortcuts use their own action.
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), inputView != nil || sender is UIKeyCommand {
                return false
            }
            return super.canPerformAction(action, withSender: sender)
        }

        @objc private func forwardHardwareShortcut(_ command: UIKeyCommand) {
            guard !yieldIfCovered(),
                  let shortcut = Self.hardwareShortcut(input: command.input, flags: command.modifierFlags)
            else {
                return
            }
            tap(shortcut.key, modifiers: shortcut.modifiers)
        }

        private static func hardwareShortcut(
            input: String?,
            flags: UIKeyModifierFlags
        ) -> (key: DeviceKey, modifiers: KeyModifiers)? {
            // The transport maps every printable ASCII character to a HID usage.
            guard !flags.isDisjoint(with: [.command, .control]),
                  let input, input.utf8.count == 1,
                  let character = input.first,
                  let ascii = character.asciiValue, printableASCII.contains(ascii)
            else {
                return nil
            }
            return (.character(character), flags.deviceHubModifiers)
        }

        /// Hides the on-screen keyboard; hardware keys stay live.
        func doneTapped() {
            releasePressedSpecialKeys()
            onDone()
        }

        /// An empty input view keeps focus for hardware keys (including a Mac
        /// keyboard shared through Mac Virtual Display) without showing the
        /// software keyboard.
        func setSoftwareKeyboardShown(_ shown: Bool) {
            guard (inputView == nil) != shown else {
                return
            }
            inputView = shown ? nil : UIView()
            inputAccessoryView = shown ? accessoryToolbar : nil
            if isFirstResponder {
                reloadInputViews()
            }
        }

        /// Acquires on a new request, retaining intent until window attachment.
        func setPresented(_ isPresented: Bool) {
            let changed = isPresentationRequested != isPresented
            isPresentationRequested = isPresented
            if changed {
                isFocusSuspended = false
                synchronizePresentation()
            } else if isCovered || isReacquireScheduled {
                // Preserve the existing cover/recovery path without treating
                // ordinary SwiftUI updates as permission to steal focus.
                synchronizePresentation()
            }
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn _: NSRange,
            replacementString string: String
        ) -> Bool {
            guard textField === self, !yieldIfCovered() else {
                return false
            }
            if !string.isEmpty {
                forward(string)
            }
            return false
        }

        private func configure() {
            accessibilityElementsHidden = true
            isAccessibilityElement = false
            autocapitalizationType = .none
            autocorrectionType = .no
            backgroundColor = .clear
            borderStyle = .none
            isSecureTextEntry = false
            keyboardType = .default
            smartDashesType = .no
            smartInsertDeleteType = .no
            smartQuotesType = .no
            spellCheckingType = .no
            textColor = .clear
            tintColor = .clear
            inputAccessoryView = accessoryToolbar
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
            delegate = self
        }

        private func forward(_ text: String) {
            for character in text {
                switch character {
                case "\n", "\r":
                    tap(.return)
                case " ":
                    tap(.space)
                default:
                    tap(.character(character))
                }
            }
        }

        private func tap(
            _ key: DeviceKey,
            modifiers: KeyModifiers = []
        ) {
            onKeyTapped(key, modifiers)
        }

        private func makeAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.items = [
                accessoryButton("Done") { [weak self] in
                    self?.doneTapped()
                },
                UIBarButtonItem(systemItem: .flexibleSpace),
                accessoryButton("Esc") { [weak self] in
                    self?.tap(.escape)
                },
                accessoryButton("Tab") { [weak self] in
                    self?.tap(.tab)
                },
                accessorySymbolButton(
                    "arrow.left",
                    accessibilityLabel: "Left Arrow"
                ) { [weak self] in
                    self?.tap(.leftArrow)
                },
                accessorySymbolButton(
                    "arrow.up",
                    accessibilityLabel: "Up Arrow"
                ) { [weak self] in
                    self?.tap(.upArrow)
                },
                accessorySymbolButton(
                    "arrow.down",
                    accessibilityLabel: "Down Arrow"
                ) { [weak self] in
                    self?.tap(.downArrow)
                },
                accessorySymbolButton(
                    "arrow.right",
                    accessibilityLabel: "Right Arrow"
                ) { [weak self] in
                    self?.tap(.rightArrow)
                }
            ]
            toolbar.sizeToFit()
            return toolbar
        }

        private func accessoryButton(
            _ title: String,
            action: @escaping @MainActor () -> Void
        ) -> UIBarButtonItem {
            UIBarButtonItem(
                title: title,
                primaryAction: UIAction { _ in
                    action()
                }
            )
        }

        private func accessorySymbolButton(
            _ systemName: String,
            accessibilityLabel: String,
            action: @escaping @MainActor () -> Void
        ) -> UIBarButtonItem {
            let item = UIBarButtonItem(
                image: UIImage(systemName: systemName),
                primaryAction: UIAction { _ in
                    action()
                }
            )
            item.accessibilityLabel = accessibilityLabel
            return item
        }

        private func release(_ presses: Set<UIPress>) {
            for press in presses {
                guard let keyCode = press.key?.keyCode,
                      let command = pressedSpecialKeys.release(
                          usage: keyCode
                      )
                else {
                    continue
                }
                onKeyChanged(command)
            }
        }

        private func specialKey(
            for keyCode: UIKeyboardHIDUsage
        ) -> DeviceKey? {
            switch keyCode {
            case .keyboardDownArrow:
                .downArrow
            case .keyboardEscape:
                .escape
            case .keyboardLeftArrow:
                .leftArrow
            case .keyboardRightArrow:
                .rightArrow
            case .keyboardTab:
                .tab
            case .keyboardUpArrow:
                .upArrow
            default:
                nil
            }
        }

        /// A sheet or alert over this window owns the keyboard.
        private var isCovered: Bool {
            window?.rootViewController?.presentedViewController != nil
        }

        /// Gives up focus when covered, so keys arriving before the next SwiftUI
        /// update never reach the device. Returns whether it yielded.
        private func yieldIfCovered() -> Bool {
            guard isCovered else {
                return false
            }
            releasePressedSpecialKeys()
            if isFirstResponder {
                _ = resignFirstResponder()
            }
            scheduleReacquire()
            return true
        }

        // ponytail: 0.5 s poll while covered; a dismissal callback would replace it.
        /// Re-checks after a presentation without waiting for a SwiftUI update
        /// (a static remote screen may send no frames).
        private func scheduleReacquire() {
            guard isPresentationRequested, !isFocusSuspended, !isReacquireScheduled else {
                return
            }
            isReacquireScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else {
                    return
                }
                isReacquireScheduled = false
                synchronizePresentation()
            }
        }

        /// Sheets and alerts temporarily own the keyboard. Other focus owners
        /// keep it until a fresh, explicit presentation request.
        private func synchronizePresentation() {
            if isPresentationRequested, window != nil, isCovered {
                _ = yieldIfCovered()
                return
            }
            guard isPresentationRequested, !isFocusSuspended, window != nil else {
                releasePressedSpecialKeys()
                if isFirstResponder {
                    _ = resignFirstResponder()
                }
                return
            }
            if !isFirstResponder {
                _ = becomeFirstResponder()
            }
        }
    }

    struct DeviceKeyboardPressedKeyLedger {
        private struct Entry {
            let key: DeviceKey
            let modifiers: KeyModifiers
            let usage: UIKeyboardHIDUsage
        }

        private var entries: [Entry] = []

        mutating func press(
            usage: UIKeyboardHIDUsage,
            key: DeviceKey,
            modifiers: KeyModifiers
        ) -> KeyCommand? {
            guard !entries.contains(where: { $0.usage == usage }) else {
                return nil
            }
            entries.append(
                Entry(key: key, modifiers: modifiers, usage: usage)
            )
            return KeyCommand(
                key: key,
                phase: .press,
                modifiers: modifiers
            )
        }

        mutating func release(
            usage: UIKeyboardHIDUsage
        ) -> KeyCommand? {
            guard let index = entries.firstIndex(
                where: { $0.usage == usage }
            ) else {
                return nil
            }
            let entry = entries.remove(at: index)
            return KeyCommand(
                key: entry.key,
                phase: .release,
                modifiers: entry.modifiers
            )
        }

        mutating func releaseAll() -> [KeyCommand] {
            defer {
                entries.removeAll(keepingCapacity: true)
            }
            return entries.reversed().map {
                KeyCommand(
                    key: $0.key,
                    phase: .release,
                    modifiers: $0.modifiers
                )
            }
        }
    }

    private extension UIKeyModifierFlags {
        var deviceHubModifiers: KeyModifiers {
            var modifiers: KeyModifiers = []
            if contains(.command) {
                modifiers.insert(.command)
            }
            if contains(.control) {
                modifiers.insert(.control)
            }
            if contains(.alternate) {
                modifiers.insert(.option)
            }
            if contains(.shift) {
                modifiers.insert(.shift)
            }
            return modifiers
        }
    }
#endif
