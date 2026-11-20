import DeviceHubCore

struct RemoteActiveTouch: Equatable {
    let contactID: UInt8
    var lastPoint: Point2D
    let viewport: Viewport
}

struct RemoteTouchUpdate: Equatable {
    let phase: TouchPhase
    let touch: RemoteActiveTouch
}

/// Local gesture ownership that cannot outlive remote input authorization.
struct RemoteTouchLedger {
    private(set) var activeTouch: RemoteActiveTouch?
    private var scrollAnchor: Point2D?

    /// Starts a contact only when no gesture is currently owned.
    mutating func beginIfNeeded(
        contactID: UInt8,
        at point: Point2D,
        viewport: Viewport
    ) -> RemoteActiveTouch? {
        guard activeTouch == nil else { return nil }
        let touch = RemoteActiveTouch(contactID: contactID, lastPoint: point, viewport: viewport)
        activeTouch = touch
        return touch
    }

    /// Drag callbacks cannot change or end a contact owned by a scroll.
    @discardableResult
    mutating func updateLastPoint(_ point: Point2D) -> Bool {
        guard scrollAnchor == nil, activeTouch != nil else { return false }
        activeTouch?.lastPoint = point
        return true
    }

    mutating func removeDrag() -> RemoteActiveTouch? {
        guard scrollAnchor == nil else { return nil }
        return removeActiveTouch()
    }

    /// Ends local ownership and returns the contact to terminate remotely.
    mutating func removeActiveTouch() -> RemoteActiveTouch? {
        defer {
            activeTouch = nil
            scrollAnchor = nil
        }
        return activeTouch
    }

    /// Revokes a contact exactly when input transitions from allowed to denied.
    mutating func revokeInput(from oldValue: Bool, to newValue: Bool) -> RemoteActiveTouch? {
        guard oldValue, !newValue else { return nil }
        return removeActiveTouch()
    }

    /// Converts cumulative scroll translation into one touch contact.
    /// A resize or non-finite movement ends the contact at its last valid point.
    mutating func scroll(
        phase: TouchPhase,
        at point: Point2D,
        translation: Point2D,
        viewport: Viewport
    ) -> RemoteTouchUpdate? {
        if phase == .began {
            guard validScrollStart(point, translation: translation, viewport: viewport),
                  let touch = beginIfNeeded(contactID: 0, at: point, viewport: viewport)
            else { return nil }
            scrollAnchor = point
            return RemoteTouchUpdate(phase: .began, touch: touch)
        }
        guard let anchor = scrollAnchor, var touch = activeTouch else { return nil }
        let translated = Point2D(x: anchor.x + translation.x, y: anchor.y + translation.y)
        guard phase != .cancelled, viewport == touch.viewport,
              translated.x.isFinite, translated.y.isFinite
        else {
            _ = removeActiveTouch()
            return RemoteTouchUpdate(phase: .cancelled, touch: touch)
        }
        touch.lastPoint = translated
        if phase == .ended {
            _ = removeActiveTouch()
        } else {
            activeTouch = touch
        }
        return RemoteTouchUpdate(phase: phase, touch: touch)
    }

    private func validScrollStart(_ point: Point2D, translation: Point2D, viewport: Viewport) -> Bool {
        let maximumX = viewport.origin.x + viewport.size.width
        let maximumY = viewport.origin.y + viewport.size.height
        return point.x.isFinite && point.y.isFinite
            && translation.x.isFinite && translation.y.isFinite
            && viewport.origin.x.isFinite && viewport.origin.y.isFinite
            && viewport.size.width.isFinite && viewport.size.height.isFinite
            && viewport.size.width > 0 && viewport.size.height > 0
            && maximumX.isFinite && maximumY.isFinite
            && point.x >= viewport.origin.x && point.x <= maximumX
            && point.y >= viewport.origin.y && point.y <= maximumY
    }
}
