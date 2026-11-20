@testable import DeviceHubUI
import Testing

/// Mac Virtual Display shares the Mac keyboard with visionOS apps; it must
/// reach the session without first opening the on-screen keyboard.
struct RemoteSessionKeyboardReceiverTests {
    @Test func receiverListensWheneverTheSessionAcceptsInput() {
        #expect(RemoteSessionView.showsKeyboardReceiver(acceptsInput: true, isKeyboardPresented: false))
        #expect(RemoteSessionView.showsKeyboardReceiver(acceptsInput: true, isKeyboardPresented: true))
    }

    @Test func receiverFollowsThePanelWhenInputIsUnavailable() {
        #expect(!RemoteSessionView.showsKeyboardReceiver(acceptsInput: false, isKeyboardPresented: false))
        #expect(RemoteSessionView.showsKeyboardReceiver(acceptsInput: false, isKeyboardPresented: true))
    }
}
