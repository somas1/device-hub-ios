import CoreGraphics
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubUI
import Foundation
import SwiftUI
import Testing

struct RemoteScreenImageOrientationTests {
    @Test(arguments: ScreenOrientation.allCases)
    func imageOrientationUsesCarriedTurnInsteadOfRecomputingFromDimensions(orientation: ScreenOrientation) throws {
        let context = try #require(CGContext(
            data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let metadata = ScreenMetadata.videoFrame(FrameMetadata(
            generation: SessionGeneration(rawValue: UUID()), sequenceNumber: 1, receivedAt: .distantPast,
            pixelSize: PixelSize(width: 64, height: 96), orientation: orientation
        ))
        // The carried turn is authoritative even when dimensions suggest another one.
        let cases: [(DisplayTurn, Image.Orientation)] = [
            (.upright, .up), (.clockwise, .right), (.counterclockwise, .left)
        ]
        for (turn, expected) in cases {
            let frame = RemoteDisplayFrame(metadata: metadata, image: image, displayTurn: turn)
            #expect(RemoteScreenLayout.imageOrientation(for: frame) == expected)
        }
    }
}
