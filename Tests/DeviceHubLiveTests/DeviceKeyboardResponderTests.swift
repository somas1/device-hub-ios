import DeviceHubCore
@testable import DeviceHubUI
import ObjectiveC.runtime
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("Device keyboard responder lifecycle")
struct DeviceKeyboardResponderTests {
    @Test("Software-keyboard edits are intercepted without retaining text")
    func softwareKeyboardEditInterception() {
        let textField = DeviceKeyboardTextField()
        var tappedKeys: [DeviceKey] = []
        textField.onKeyTapped = { key, _ in
            tappedKeys.append(key)
        }

        let inserted = textField.delegate?.textField?(
            textField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "1"
        )
        let deleted = textField.delegate?.textField?(
            textField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: ""
        )
        textField.deleteBackward()

        #expect(inserted == false)
        #expect(deleted == false)
        #expect(tappedKeys == [.character("1"), .delete])
        #expect(textField.text?.isEmpty != false)
    }

    @Test("The delegate owns insertion and the subclass owns deletion")
    func uiKeyInputOwnership() throws {
        let insertSelector = #selector(UIKeyInput.insertText(_:))
        let deleteSelector = #selector(UIKeyInput.deleteBackward)
        let baseInsert = try #require(
            class_getInstanceMethod(UITextField.self, insertSelector)
        )
        let concreteInsert = try #require(
            class_getInstanceMethod(DeviceKeyboardTextField.self, insertSelector)
        )
        let baseDelete = try #require(
            class_getInstanceMethod(UITextField.self, deleteSelector)
        )
        let concreteDelete = try #require(
            class_getInstanceMethod(DeviceKeyboardTextField.self, deleteSelector)
        )

        #expect(method_getImplementation(baseInsert) == method_getImplementation(concreteInsert))
        #expect(method_getImplementation(baseDelete) != method_getImplementation(concreteDelete))
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("A presentation request survives attachment to the window")
    func presentationBeforeAttachment() async {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewController = UIViewController()
        let textField = DeviceKeyboardTextField()
        window.rootViewController = viewController

        textField.setPresented(true)
        viewController.view.addSubview(textField)
        window.makeKeyAndVisible()
        await Task.yield()

        #expect(textField.isFirstResponder)

        textField.setPresented(false)
        #expect(!textField.isFirstResponder)
        textField.setPresented(false)
        window.isHidden = true
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("Repeated presentation updates preserve a sibling's keyboard focus")
    func updatesPreserveSiblingFocus() async throws {
        let (window, receiver, sibling) = makeKeyboardWindow()
        defer { window.isHidden = true }
        receiver.setSoftwareKeyboardShown(false)
        receiver.setPresented(true)
        await Task.yield()
        try #require(receiver.isFirstResponder)
        try #require(sibling.becomeFirstResponder())

        for _ in 0 ..< 3 {
            receiver.setPresented(true)
            #expect(sibling.isFirstResponder)
            #expect(!receiver.isFirstResponder)
        }
        receiver.setPresented(false)
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("An explicit canvas re-request restores yielded keyboard focus")
    func explicitRequestRestoresFocus() async throws {
        let (window, receiver, sibling) = makeKeyboardWindow()
        defer { window.isHidden = true }
        receiver.setSoftwareKeyboardShown(false)
        receiver.setPresented(true)
        await Task.yield()
        try #require(sibling.becomeFirstResponder())
        receiver.setPresented(true)
        #expect(sibling.isFirstResponder)

        // The canvas request starts a fresh presentation edge.
        receiver.setPresented(false)
        receiver.setPresented(true)

        #expect(receiver.isFirstResponder)
        #expect(!sibling.isFirstResponder)
        receiver.setPresented(false)
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("Only a new presentation edge acquires keyboard focus")
    func presentationEdgesAcquireFocus() async throws {
        let (window, receiver, sibling) = makeKeyboardWindow()
        defer { window.isHidden = true }
        receiver.setSoftwareKeyboardShown(false)
        try #require(sibling.becomeFirstResponder())
        receiver.setPresented(false)
        #expect(sibling.isFirstResponder)

        receiver.setPresented(true)
        await Task.yield()
        #expect(receiver.isFirstResponder)
        try #require(sibling.becomeFirstResponder())
        receiver.setPresented(true)
        #expect(sibling.isFirstResponder)

        receiver.setPresented(false)
        receiver.setPresented(true)
        #expect(receiver.isFirstResponder)
        receiver.setPresented(false)
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("System keyboard dismissal clears software presentation and stays dismissed")
    func systemDismissClearsPresentation() async throws {
        let (window, receiver, _) = makeKeyboardWindow()
        defer { window.isHidden = true }
        var isPresented = true
        receiver.onDone = { isPresented = false }
        receiver.setSoftwareKeyboardShown(isPresented)
        receiver.setPresented(true)
        await Task.yield()
        try #require(receiver.isFirstResponder)

        try #require(receiver.resignFirstResponder())

        #expect(!isPresented)
        receiver.setSoftwareKeyboardShown(isPresented)
        receiver.setPresented(true)
        #expect(!receiver.isFirstResponder)
        #expect(receiver.inputView != nil)
        #expect(receiver.text?.isEmpty != false)
        receiver.setPresented(false)
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("Canvas requests and software keyboard opening preserve held keys when already focused")
    func focusedRequestsPreserveHeldKeys() async throws {
        var commands: [KeyCommand] = []
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: DeviceKeyboardReceiver(
            isPresented: .constant(false),
            focusRequest: 0,
            keyChanged: { commands.append($0) },
            keyTapped: { _, _ in }
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try #require(await eventually { keyboardReceiver(in: host.view)?.isFirstResponder == true })
        let receiver = try #require(keyboardReceiver(in: host.view))
        _ = receiver.pressedSpecialKeys.press(usage: .keyboardTab, key: .tab, modifiers: [])

        host.rootView = DeviceKeyboardReceiver(
            isPresented: .constant(true),
            focusRequest: 1,
            keyChanged: { commands.append($0) },
            keyTapped: { _, _ in }
        )
        // The input-view transition proves the representable processed this update.
        try #require(await eventually { receiver.inputView == nil })

        #expect(keyboardReceiver(in: host.view) === receiver)
        #expect(receiver.isFirstResponder)
        #expect(commands.isEmpty)
        receiver.setPresented(false)
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("A pending cover recovery leaves subsequently yielded focus alone")
    func pendingRecoveryPreservesSiblingFocus() async throws {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewController = PresentationStateViewController()
        let receiver = DeviceKeyboardTextField()
        let sibling = UITextField()
        window.rootViewController = viewController
        viewController.view.addSubview(receiver)
        viewController.view.addSubview(sibling)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        receiver.setSoftwareKeyboardShown(false)
        receiver.setPresented(true)
        try #require(receiver.isFirstResponder)

        viewController.isCovered = true
        receiver.setPresented(true)
        try #require(!receiver.isFirstResponder)
        viewController.isCovered = false
        receiver.setPresented(true)
        try #require(receiver.isFirstResponder)
        try #require(sibling.becomeFirstResponder())

        // Let the existing 500 ms cover-recovery task run after focus was yielded.
        try await Task.sleep(for: .milliseconds(650))
        receiver.setPresented(true)

        #expect(sibling.isFirstResponder)
        #expect(!receiver.isFirstResponder)
        receiver.setPresented(false)
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("Hardware keys keep focus without an on-screen keyboard")
    func hardwareOnlyFocus() async {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewController = UIViewController()
        let textField = DeviceKeyboardTextField()
        window.rootViewController = viewController
        viewController.view.addSubview(textField)
        window.makeKeyAndVisible()

        textField.setSoftwareKeyboardShown(false)
        textField.setPresented(true)
        await Task.yield()
        #expect(textField.isFirstResponder)
        #expect(textField.inputView != nil)
        #expect(textField.inputAccessoryView == nil)

        textField.setSoftwareKeyboardShown(true)
        #expect(textField.isFirstResponder)
        #expect(textField.inputView == nil)
        #expect(textField.inputAccessoryView != nil)
        textField.setPresented(false)
        window.isHidden = true
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("Done keeps hardware focus")
    func doneKeepsHardwareFocus() async {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewController = UIViewController()
        let textField = DeviceKeyboardTextField()
        var doneCount = 0
        textField.onDone = { doneCount += 1 }
        window.rootViewController = viewController
        viewController.view.addSubview(textField)
        window.makeKeyAndVisible()
        textField.setPresented(true)
        await Task.yield()

        textField.doneTapped()

        #expect(doneCount == 1)
        #expect(textField.isFirstResponder)
        textField.setPresented(false)
        window.isHidden = true
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("Presented sheets and alerts keep keyboard focus until dismissed")
    func focusYieldsToPresentedContent() async {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewController = PresentationStateViewController()
        let textField = DeviceKeyboardTextField()
        window.rootViewController = viewController
        viewController.view.addSubview(textField)
        window.makeKeyAndVisible()
        textField.setPresented(true)
        await Task.yield()
        #expect(textField.isFirstResponder)

        viewController.isCovered = true
        textField.setPresented(true) // presentation updates still yield while covered
        #expect(!textField.isFirstResponder)

        viewController.isCovered = false
        textField.setPresented(true) // an update can complete cover recovery
        #expect(textField.isFirstResponder)
        textField.setPresented(false)
        window.isHidden = true
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("Typing while a sheet or alert is up never reaches the iPad")
    func coveredInputIsNotForwarded() async {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewController = PresentationStateViewController()
        let textField = DeviceKeyboardTextField()
        var tapped: [DeviceKey] = []
        textField.onKeyTapped = { key, _ in tapped.append(key) }
        window.rootViewController = viewController
        viewController.view.addSubview(textField)
        window.makeKeyAndVisible()
        textField.setPresented(true)
        await Task.yield()

        viewController.isCovered = true // no SwiftUI update has run yet
        _ = textField.delegate?.textField?(
            textField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "\r"
        )
        textField.deleteBackward()

        #expect(tapped.isEmpty)
        #expect(!textField.isFirstResponder)
        textField.setPresented(false)
        window.isHidden = true
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("Focus returns after a sheet closes even when no update follows")
    func focusReturnsWithoutAnUpdate() async throws {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewController = PresentationStateViewController()
        let textField = DeviceKeyboardTextField()
        window.rootViewController = viewController
        viewController.view.addSubview(textField)
        window.makeKeyAndVisible()
        viewController.isCovered = true
        textField.setPresented(true)
        #expect(!textField.isFirstResponder)

        viewController.isCovered = false // static iPad screen: no further updates

        #expect(await eventually { textField.isFirstResponder })
        textField.setPresented(false)
        window.isHidden = true
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("Paste needs the on-screen keyboard; clipboard transfer stays explicit")
    func pasteRequiresSoftwareKeyboard() async {
        let savedItems = UIPasteboard.general.items
        defer { UIPasteboard.general.items = savedItems }
        UIPasteboard.general.string = "synthetic"
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewController = UIViewController()
        let textField = DeviceKeyboardTextField()
        window.rootViewController = viewController
        viewController.view.addSubview(textField)
        window.makeKeyAndVisible()
        textField.setPresented(true)
        await Task.yield()
        let paste = #selector(UIResponderStandardEditActions.paste(_:))

        textField.setSoftwareKeyboardShown(true)
        #expect(textField.canPerformAction(paste, withSender: nil))

        textField.setSoftwareKeyboardShown(false)
        #expect(!textField.canPerformAction(paste, withSender: nil))
        textField.setPresented(false)
        window.isHidden = true
    }

    @available(
        iOS,
        deprecated: 26.0,
        message: "Exercises pre-scene responder attachment."
    )
    @Test("Focus returns after a sheet's own field took it, without an update")
    func focusReturnsAfterSheetTookFocus() async {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let viewController = PresentationStateViewController()
        let textField = DeviceKeyboardTextField()
        let sheetField = UITextField()
        window.rootViewController = viewController
        viewController.view.addSubview(textField)
        viewController.view.addSubview(sheetField)
        window.makeKeyAndVisible()
        textField.setPresented(true)
        await Task.yield()

        viewController.isCovered = true
        _ = sheetField.becomeFirstResponder() // UIKit resigns the receiver
        #expect(!textField.isFirstResponder)
        viewController.isCovered = false
        sheetField.removeFromSuperview() // the sheet is dismissed

        #expect(await eventually { textField.isFirstResponder })
        textField.setPresented(false)
        window.isHidden = true
    }

    @Test(
        "Held special keys release when the scene or window loses focus",
        arguments: [UIScene.willDeactivateNotification, UIWindow.didResignKeyNotification]
    )
    func heldKeysReleaseOnFocusLoss(notification: Notification.Name) {
        let textField = DeviceKeyboardTextField()
        var commands: [KeyCommand] = []
        textField.onKeyChanged = { commands.append($0) }
        _ = textField.pressedSpecialKeys.press(
            usage: .keyboardLeftArrow,
            key: .leftArrow,
            modifiers: []
        )

        NotificationCenter.default.post(name: notification, object: nil)

        #expect(commands == [KeyCommand(key: .leftArrow, phase: .release, modifiers: [])])
    }
}

@MainActor
private func keyboardReceiver(in view: UIView) -> DeviceKeyboardTextField? {
    if let receiver = view as? DeviceKeyboardTextField {
        return receiver
    }
    return view.subviews.lazy.compactMap { keyboardReceiver(in: $0) }.first
}

@MainActor
@available(iOS, deprecated: 26.0, message: "Exercises pre-scene responder attachment.")
private func makeKeyboardWindow() -> (UIWindow, DeviceKeyboardTextField, UITextField) {
    let window = UIWindow()
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    let viewController = UIViewController()
    let receiver = DeviceKeyboardTextField()
    let sibling = UITextField()
    window.rootViewController = viewController
    viewController.view.addSubview(receiver)
    viewController.view.addSubview(sibling)
    window.makeKeyAndVisible()
    return (window, receiver, sibling)
}

/// Reports a sheet or alert over the root without a real, scene-dependent
/// presentation (whose dismissal never completes in a bare test window).
private final class PresentationStateViewController: UIViewController {
    var isCovered = false
    override var presentedViewController: UIViewController? {
        isCovered ? UIViewController() : nil
    }
}

/// Polls a main-actor condition until it holds or a deadline passes.
@MainActor
private func eventually(
    within seconds: Double = 3,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
