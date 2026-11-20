import DeviceHubCore
import SwiftUI

/// Captures only continuous trackpad scrolls alongside the SwiftUI tap and drag gestures.
struct RemoteTrackpadScrollModifier: ViewModifier {
    @Binding var touchLedger: RemoteTouchLedger
    let acceptsInput: Bool
    let viewport: Viewport
    let touch: (UInt8, TouchPhase, Point2D, Viewport) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
            content.gesture(RemoteTrackpadScrollGesture(
                touchLedger: $touchLedger,
                acceptsInput: acceptsInput,
                viewport: viewport,
                touch: touch
            ))
        #else
            content
        #endif
    }
}

#if os(iOS)
    import UIKit

    struct RemoteTrackpadScrollGesture: UIGestureRecognizerRepresentable {
        @Binding var touchLedger: RemoteTouchLedger
        let acceptsInput: Bool
        let viewport: Viewport
        let touch: (UInt8, TouchPhase, Point2D, Viewport) -> Void

        static func makeRecognizer() -> UIPanGestureRecognizer {
            let recognizer = UIPanGestureRecognizer()
            recognizer.allowedScrollTypesMask = .continuous
            recognizer.allowedTouchTypes = []
            recognizer.cancelsTouchesInView = false
            return recognizer
        }

        func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
            let recognizer = Self.makeRecognizer()
            recognizer.isEnabled = acceptsInput
            return recognizer
        }

        func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
            recognizer.isEnabled = acceptsInput
        }

        func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
            forward(
                state: recognizer.state,
                location: context.converter.localLocation,
                translation: context.converter.localTranslation
            )
        }

        /// Forwards each sample synchronously within the current input session.
        func forward(state: UIGestureRecognizer.State, location: CGPoint, translation: CGPoint?) {
            guard acceptsInput else { return }
            let phase: TouchPhase
            switch state {
            case .began: phase = .began
            case .changed: phase = .moved
            case .ended: phase = .ended
            case .cancelled, .failed: phase = .cancelled
            default: return
            }
            // Recognition can begin with movement. Send the pointer position first,
            // followed by the first displacement.
            let phases: [TouchPhase] = translation == nil ? [.cancelled]
                : phase == .began ? [.began, .moved] : [phase]
            for phase in phases {
                let update = touchLedger.scroll(
                    phase: phase,
                    at: Point2D(x: Double(location.x), y: Double(location.y)),
                    translation: Point2D(x: Double(translation?.x ?? 0), y: Double(translation?.y ?? 0)),
                    viewport: viewport
                )
                guard let update else { return }
                touch(update.touch.contactID, update.phase, update.touch.lastPoint, update.touch.viewport)
            }
        }
    }
#endif
