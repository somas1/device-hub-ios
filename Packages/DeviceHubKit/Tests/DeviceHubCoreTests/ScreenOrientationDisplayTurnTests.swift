import DeviceHubCore
import Testing

/// Portrait targets can encode their upright screen sideways in a landscape frame.
struct ScreenOrientationDisplayTurnTests {
    private let nativePortrait = PixelSize(width: 2064, height: 2736)
    private let landscapeCoded = PixelSize(width: 2736, height: 2064)

    @Test func nativePortraitSizeIsPortraitShapedWhicheverWayTheStreamIsCoded() {
        #expect(landscapeCoded.portraitShaped == nativePortrait)
        #expect(nativePortrait.portraitShaped == nativePortrait)
    }

    @Test func portraitTargetWithLandscapeCodedFrameTurnsClockwise() {
        #expect(ScreenOrientation.portrait.displayTurn(decoded: landscapeCoded, native: nativePortrait) == .clockwise)
    }

    @Test func upsideDownTargetWithLandscapeCodedFrameTurnsCounterclockwise() {
        #expect(ScreenOrientation.portraitUpsideDown.displayTurn(decoded: landscapeCoded, native: nativePortrait) == .counterclockwise)
    }

    @Test(arguments: ScreenOrientation.allCases)
    func framesAlreadyShapedForTheOrientationNeedNoTurn(orientation: ScreenOrientation) {
        let decoded = orientation.orientedSize(for: nativePortrait)
        #expect(orientation.displayTurn(decoded: decoded, native: nativePortrait) == DisplayTurn.upright)
    }

    @Test func otherMismatchesRemainUnusable() {
        for orientation in [ScreenOrientation.landscapeLeft, .landscapeRight] {
            #expect(orientation.displayTurn(decoded: nativePortrait, native: nativePortrait) == nil)
        }
        #expect(ScreenOrientation.portrait.displayTurn(decoded: nativePortrait, native: landscapeCoded) == nil)
        #expect(ScreenOrientation.portrait.displayTurn(decoded: PixelSize(width: 100, height: 100), native: nativePortrait) == nil)
    }

    @Test(arguments: [
        (ScreenOrientation.portrait, TargetPixelPoint(x: 0, y: 0), TargetPixelPoint(x: 2063, y: 2735)),
        (ScreenOrientation.portraitUpsideDown, TargetPixelPoint(x: 2063, y: 2735), TargetPixelPoint(x: 0, y: 0))
    ])
    func touchesFollowUprightContent(
        orientation: ScreenOrientation, topLeft: TargetPixelPoint, bottomRight: TargetPixelPoint
    ) {
        let native = landscapeCoded.portraitShaped
        let viewport = Viewport(origin: Point2D(x: 0, y: 0), size: Size2D(width: 2064, height: 2736))
        #expect(RemoteCoordinateMapper.mapInitialTouch(
            Point2D(x: 0, y: 0), in: viewport, targetPixels: native, orientation: orientation
        ) == topLeft)
        #expect(RemoteCoordinateMapper.mapInitialTouch(
            Point2D(x: 2064, y: 2736), in: viewport, targetPixels: native, orientation: orientation
        ) == bottomRight)
    }
}
