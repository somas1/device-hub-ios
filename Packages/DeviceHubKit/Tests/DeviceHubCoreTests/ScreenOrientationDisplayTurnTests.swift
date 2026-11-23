import DeviceHubCore
import Testing

/// Covers coded frame rotation and touch mapping in the displayed orientation.
struct ScreenOrientationDisplayTurnTests {
    private let nativePortrait = PixelSize(width: 2064, height: 2736)
    private let landscapeCoded = PixelSize(width: 2736, height: 2064)

    @Test func nativePortraitSizeIsPortraitShapedWhicheverWayTheStreamIsCoded() {
        #expect(landscapeCoded.portraitShaped == nativePortrait)
        #expect(nativePortrait.portraitShaped == nativePortrait)
    }

    @Test func portraitTargetWithLandscapeCodedFrameTurnsClockwise() {
        #expect(ScreenOrientation.portrait.displayTurn(
            decoded: landscapeCoded, native: nativePortrait, panelFixedLandscape: true
        ) == .clockwise)
    }

    @Test func upsideDownTargetWithLandscapeCodedFrameTurnsCounterclockwise() {
        #expect(ScreenOrientation.portraitUpsideDown.displayTurn(
            decoded: landscapeCoded, native: nativePortrait, panelFixedLandscape: true
        ) == .counterclockwise)
    }

    @Test(arguments: [
        (ScreenOrientation.portrait, false, DisplayTurn.upright),
        (ScreenOrientation.portrait, true, DisplayTurn.upright),
        (ScreenOrientation.portraitUpsideDown, false, DisplayTurn.upright),
        (ScreenOrientation.portraitUpsideDown, true, DisplayTurn.upright),
        (ScreenOrientation.landscapeLeft, false, DisplayTurn.upright),
        (ScreenOrientation.landscapeLeft, true, DisplayTurn.upright),
        (ScreenOrientation.landscapeRight, false, DisplayTurn.upright),
        (ScreenOrientation.landscapeRight, true, DisplayTurn.half)
    ])
    func framesAlreadyShapedForTheOrientationUseThePanelTurn(
        orientation: ScreenOrientation, panelFixedLandscape: Bool, expected: DisplayTurn
    ) {
        let decoded = orientation.orientedSize(for: nativePortrait)
        #expect(orientation.displayTurn(
            decoded: decoded, native: nativePortrait, panelFixedLandscape: panelFixedLandscape
        ) == expected)
    }

    @Test func otherMismatchesRemainUnusable() {
        for orientation in [ScreenOrientation.landscapeLeft, .landscapeRight] {
            for panelFixedLandscape in [false, true] {
                #expect(orientation.displayTurn(
                    decoded: nativePortrait, native: nativePortrait, panelFixedLandscape: panelFixedLandscape
                ) == nil)
            }
        }
        #expect(ScreenOrientation.portrait.displayTurn(
            decoded: nativePortrait, native: landscapeCoded, panelFixedLandscape: false
        ) == nil)
        #expect(ScreenOrientation.portrait.displayTurn(
            decoded: PixelSize(width: 100, height: 100), native: nativePortrait, panelFixedLandscape: false
        ) == nil)
    }

    @Test(arguments: [
        (ScreenOrientation.portrait, TargetPixelPoint(x: 0, y: 0), TargetPixelPoint(x: 2063, y: 2735)),
        (ScreenOrientation.portraitUpsideDown, TargetPixelPoint(x: 2063, y: 2735), TargetPixelPoint(x: 0, y: 0)),
        (ScreenOrientation.landscapeLeft, TargetPixelPoint(x: 2063, y: 0), TargetPixelPoint(x: 0, y: 2735)),
        (ScreenOrientation.landscapeRight, TargetPixelPoint(x: 0, y: 2735), TargetPixelPoint(x: 2063, y: 0))
    ])
    func touchesFollowUprightContent(
        orientation: ScreenOrientation, topLeft: TargetPixelPoint, bottomRight: TargetPixelPoint
    ) {
        let native = landscapeCoded.portraitShaped
        let decoded = orientation.orientedSize(for: native)
        let viewport = Viewport(
            origin: Point2D(x: 0, y: 0),
            size: Size2D(width: Double(decoded.width), height: Double(decoded.height))
        )
        #expect(RemoteCoordinateMapper.mapInitialTouch(
            Point2D(x: 0, y: 0), in: viewport, targetPixels: native, orientation: orientation
        ) == topLeft)
        #expect(RemoteCoordinateMapper.mapInitialTouch(
            Point2D(x: viewport.size.width, y: viewport.size.height),
            in: viewport, targetPixels: native, orientation: orientation
        ) == bottomRight)
    }
}
