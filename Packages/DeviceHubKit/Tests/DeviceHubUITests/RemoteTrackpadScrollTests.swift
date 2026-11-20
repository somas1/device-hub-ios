#if os(iOS)
    import DeviceHubCore
    @testable import DeviceHubUI
    import SwiftUI
    import Testing
    import UIKit

    /// The app test task selects the visual suite for its iOS package pass.
    extension DeviceHubVisualSnapshotTests {
        @MainActor
        @Suite("Continuous trackpad recognizer configuration")
        struct RemoteTrackpadScrollTests {
            @Test("UIKit states forward initial movement, cancellation and no post-revocation input")
            func forwardsLifecycle() {
                var ledger = RemoteTouchLedger()
                var updates: [RemoteTouchUpdate] = []
                let viewport = Viewport(origin: Point2D(x: 0, y: 0), size: Size2D(width: 200, height: 300))
                func makeGesture(acceptsInput: Bool) -> RemoteTrackpadScrollGesture {
                    RemoteTrackpadScrollGesture(
                        touchLedger: Binding(get: { ledger }, set: { ledger = $0 }),
                        acceptsInput: acceptsInput,
                        viewport: viewport,
                        touch: { id, phase, point, bounds in
                            updates.append(RemoteTouchUpdate(
                                phase: phase, touch: RemoteActiveTouch(contactID: id, lastPoint: point, viewport: bounds)
                            ))
                        }
                    )
                }
                let gesture = makeGesture(acceptsInput: true)
                let disabled = makeGesture(acceptsInput: false)
                disabled.forward(state: .began, location: CGPoint(x: 80, y: 120), translation: CGPoint(x: 0, y: 20))
                #expect(ledger.activeTouch == nil)
                #expect(updates.isEmpty)
                gesture.forward(state: .possible, location: .zero, translation: .zero)
                #expect(updates.isEmpty)
                gesture.forward(state: .began, location: CGPoint(x: 80, y: 120), translation: CGPoint(x: 0, y: 20))
                #expect(updates.map(\.phase) == [.began, .moved])
                #expect(updates.last?.touch.lastPoint == Point2D(x: 80, y: 140))
                gesture.forward(state: .changed, location: .zero, translation: CGPoint(x: 10, y: 30))
                #expect(updates.last?.touch.lastPoint == Point2D(x: 90, y: 150))
                gesture.forward(state: .ended, location: .zero, translation: CGPoint(x: 10, y: 30))
                #expect(updates.last?.phase == .ended)
                #expect(ledger.activeTouch == nil)
                let drag = ledger.beginIfNeeded(contactID: 0, at: Point2D(x: 20, y: 30), viewport: viewport)
                let beforeConflict = updates.count
                gesture.forward(state: .began, location: CGPoint(x: 80, y: 120), translation: CGPoint(x: 0, y: 20))
                #expect(updates.count == beforeConflict)
                #expect(ledger.activeTouch == drag)
                _ = ledger.removeActiveTouch()
                for cancellation in [UIGestureRecognizer.State.cancelled, .failed] {
                    gesture.forward(state: .began, location: CGPoint(x: 80, y: 120), translation: .zero)
                    gesture.forward(state: cancellation, location: .zero, translation: nil)
                    #expect(updates.last?.phase == .cancelled)
                    #expect(ledger.activeTouch == nil)
                }
                gesture.forward(state: .began, location: CGPoint(x: 80, y: 120), translation: .zero)
                _ = ledger.revokeInput(from: true, to: false)
                let count = updates.count
                gesture.forward(state: .changed, location: .zero, translation: CGPoint(x: 10, y: 30))
                gesture.forward(state: .ended, location: .zero, translation: CGPoint(x: 10, y: 30))
                #expect(updates.count == count)
            }

            @Test("recognizer accepts continuous scrolls without taking touch/click input")
            func continuousScrollOnly() {
                let recognizer = RemoteTrackpadScrollGesture.makeRecognizer()
                #expect(recognizer.allowedScrollTypesMask == .continuous)
                #expect(recognizer.allowedTouchTypes.isEmpty)
                #expect(!recognizer.cancelsTouchesInView)
            }
        }
    }
#endif
