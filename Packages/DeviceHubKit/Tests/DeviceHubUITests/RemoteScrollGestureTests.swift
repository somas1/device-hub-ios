import DeviceHubCore
@testable import DeviceHubUI
import Testing

@Suite("Continuous trackpad scroll lifecycle")
struct RemoteScrollGestureTests {
    private let viewport = Viewport(origin: Point2D(x: 0, y: 0), size: Size2D(width: 200, height: 300))
    private let origin = Point2D(x: 80, y: 120)
    private let zero = Point2D(x: 0, y: 0)

    @Test("scroll translation uses its initial pointer and complete cumulative movement")
    func scrollLifecycle() throws {
        var ledger = RemoteTouchLedger()
        let startResult = ledger.scroll(
            phase: .began, at: origin, translation: Point2D(x: 3, y: 5), viewport: viewport
        )
        let start = try #require(startResult)
        #expect(start.phase == .began)
        #expect(start.touch.contactID == 0)
        #expect(start.touch.lastPoint == origin)
        let moveResult = ledger.scroll(
            phase: .moved, at: zero, translation: Point2D(x: 23, y: -25), viewport: viewport
        )
        let move = try #require(moveResult)
        #expect(move.phase == .moved)
        #expect(move.touch.lastPoint == Point2D(x: 103, y: 95))
        let endResult = ledger.scroll(
            phase: .ended, at: zero, translation: Point2D(x: 33, y: -45), viewport: viewport
        )
        let end = try #require(endResult)
        #expect(end.phase == .ended)
        #expect(end.touch.lastPoint == Point2D(x: 113, y: 75))
        #expect(ledger.activeTouch == nil)
        #expect(ledger.scroll(phase: .ended, at: origin, translation: zero, viewport: viewport) == nil)
    }

    @Test("the first nonzero scroll sample is retained through a short gesture")
    func initialTranslationIsNotDiscarded() throws {
        var ledger = RemoteTouchLedger()
        let delta = Point2D(x: 0, y: 20)
        let startResult = ledger.scroll(phase: .began, at: origin, translation: delta, viewport: viewport)
        let start = try #require(startResult)
        let endResult = ledger.scroll(phase: .ended, at: origin, translation: delta, viewport: viewport)
        let end = try #require(endResult)
        #expect(start.touch.lastPoint == origin)
        #expect(end.touch.lastPoint == Point2D(x: 80, y: 140))
        #expect(ledger.activeTouch == nil)
    }

    @Test("scroll cannot steal or end a drag")
    func dragOwnsItsContact() throws {
        var ledger = RemoteTouchLedger()
        let dragResult = ledger.beginIfNeeded(contactID: 0, at: origin, viewport: viewport)
        let drag = try #require(dragResult)
        for phase in [TouchPhase.began, .moved, .ended, .cancelled] {
            #expect(ledger.scroll(phase: phase, at: origin, translation: zero, viewport: viewport) == nil)
            #expect(ledger.activeTouch == drag)
        }
    }

    @Test("drag callbacks cannot mutate or release a scroll")
    func scrollOwnsItsContact() throws {
        var ledger = RemoteTouchLedger()
        let scrollResult = ledger.scroll(phase: .began, at: origin, translation: zero, viewport: viewport)
        let scroll = try #require(scrollResult)
        #expect(ledger.beginIfNeeded(contactID: 0, at: zero, viewport: viewport) == nil)
        ledger.updateLastPoint(zero)
        #expect(ledger.activeTouch == scroll.touch)
        #expect(ledger.removeDrag() == nil)
        #expect(ledger.activeTouch == scroll.touch)
    }

    @Test("cancel, authorization loss and disappearance release once and ignore late scroll callbacks", arguments: 0 ... 2)
    func cancelledScrollCannotResume(kind: Int) throws {
        var ledger = RemoteTouchLedger()
        let beganResult = ledger.scroll(phase: .began, at: origin, translation: zero, viewport: viewport)
        _ = try #require(beganResult)
        let released: RemoteActiveTouch?
        switch kind {
        case 0:
            let update = ledger.scroll(phase: .cancelled, at: origin, translation: zero, viewport: viewport)
            #expect(update?.phase == .cancelled)
            released = update?.touch
        case 1:
            released = ledger.revokeInput(from: true, to: false)
        default:
            released = ledger.removeActiveTouch()
        }
        #expect(released?.lastPoint == origin)
        #expect(ledger.activeTouch == nil)
        for phase in [TouchPhase.moved, .ended, .cancelled] {
            #expect(ledger.scroll(phase: phase, at: origin, translation: zero, viewport: viewport) == nil)
        }
        let dragResult = ledger.beginIfNeeded(contactID: 0, at: zero, viewport: viewport)
        let drag = try #require(dragResult)
        #expect(ledger.scroll(phase: .ended, at: origin, translation: zero, viewport: viewport) == nil)
        #expect(ledger.activeTouch == drag)
    }

    @Test("invalid starts never acquire input", arguments: 0 ... 5)
    func invalidStart(kind: Int) {
        var ledger = RemoteTouchLedger()
        var point = origin
        var bounds = viewport
        var translation = zero
        switch kind {
        case 0: point.x = .nan
        case 1: point.y = -1
        case 2: point.x = 201
        case 3: bounds.size.width = 0
        case 4: bounds.origin.y = .infinity
        default: translation.y = .infinity
        }
        #expect(ledger.scroll(phase: .began, at: point, translation: translation, viewport: bounds) == nil)
        #expect(ledger.activeTouch == nil)
    }

    @Test("resizing and invalid translation cancel at the last valid matched geometry", arguments: 0 ... 2)
    func invalidMoveCancels(kind: Int) throws {
        var ledger = RemoteTouchLedger()
        let beganResult = ledger.scroll(phase: .began, at: origin, translation: zero, viewport: viewport)
        _ = try #require(beganResult)
        let previousResult = ledger.scroll(
            phase: .moved, at: origin, translation: Point2D(x: 10, y: 20), viewport: viewport
        )
        let previous = try #require(previousResult)
        var bounds = viewport
        var translation = zero
        switch kind {
        case 0: bounds.size.width = 400
        case 1: translation.x = .nan
        default: translation.y = .infinity
        }
        let cancelledResult = ledger.scroll(phase: .moved, at: origin, translation: translation, viewport: bounds)
        let cancelled = try #require(cancelledResult)
        #expect(cancelled.phase == .cancelled)
        #expect(cancelled.touch == previous.touch)
        #expect(ledger.activeTouch == nil)
    }

    @Test("scroll output reuses oriented coordinate mapping and clamping")
    func scrollCoordinatesUseExistingMapper() throws {
        var ledger = RemoteTouchLedger()
        let beganResult = ledger.scroll(phase: .began, at: origin, translation: zero, viewport: viewport)
        _ = try #require(beganResult)
        let movedResult = ledger.scroll(
            phase: .moved, at: origin, translation: Point2D(x: 1000, y: -1000), viewport: viewport
        )
        let moved = try #require(movedResult)
        let mapping = try #require(RemoteCoordinateMapper.map(
            moved.touch.lastPoint, in: moved.touch.viewport,
            targetPixels: PixelSize(width: 301, height: 201), orientation: .landscapeLeft
        ))
        #expect(mapping.wasClamped)
        #expect(mapping.point == TargetPixelPoint(x: 300, y: 200))
    }
}
