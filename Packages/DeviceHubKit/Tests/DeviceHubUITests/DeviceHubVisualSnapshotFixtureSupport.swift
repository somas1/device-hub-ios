#if os(iOS)
    import CoreGraphics
    import DeviceHubCore
    import UIKit

    enum FixturePresentation {
        case connecting
        case live
        case viewingOnly
    }

    struct FixtureRemoteGeometry {
        let imageHeight: Int
        let imageWidth: Int
        let orientation: ScreenOrientation
        let pixelSize: PixelSize
        /// Turn carried by the decoder for this synthetic frame.
        var displayTurn: DisplayTurn = .upright
    }

    enum FixtureRemoteScreen {
        case phonePortrait
        case tabletLandscape
        case tabletLandscapePanelFixed
        case tabletPortraitLandscapeCoded

        var geometry: FixtureRemoteGeometry {
            switch self {
            case .phonePortrait:
                FixtureRemoteGeometry(
                    imageHeight: 852,
                    imageWidth: 393,
                    orientation: .portrait,
                    pixelSize: PixelSize(width: 1179, height: 2556)
                )

            case .tabletLandscape, .tabletLandscapePanelFixed:
                FixtureRemoteGeometry(
                    imageHeight: 1024,
                    imageWidth: 1366,
                    orientation: .landscapeRight,
                    pixelSize: PixelSize(width: 2064, height: 2752),
                    displayTurn: self == .tabletLandscapePanelFixed ? .half : .upright
                )

            case .tabletPortraitLandscapeCoded:
                FixtureRemoteGeometry(
                    imageHeight: 1024,
                    imageWidth: 1366,
                    orientation: .portrait,
                    pixelSize: PixelSize(width: 2064, height: 2752),
                    displayTurn: .clockwise
                )
            }
        }
    }

    struct FixtureDevices {
        let reachable: DeviceSummary
        let offline: DeviceSummary
        let landscapeIPad: DeviceSummary
        let roster: DeviceRoster
    }

    enum VisualFixtureError: Error {
        case imageContextCreationFailed
        case imageCreationFailed
        case invalidPairingCode
        case invalidRemoteState
        case invalidUUID
        case unexpectedScenario
    }

    enum VisualScenario: String, CaseIterable {
        case emptyIPhoneLight
        case pairingIPhoneDark
        case connectingIPhoneLight
        case liveIPhoneDark
        case liveIPadLight
        case liveIPadDark
        case liveLandscapeIPadTargetIPhoneDark
        case livePortraitIPadTargetLandscapeCodedIPadDark
        case landscapeRightPanelFixedIPad
        case offlineIPhoneDark
        case lockedIPhoneAccessibility
        case developerModeIPadAccessibility
        case localNetworkDeniedIPadDark
        case deviceBusyIPhoneDark
        case developerImageUnavailableIPadLight
        case developerImageIncompatibleIPhoneDark
        case xcodePreparationIPadLight
        case deviceDetailsPendingVersionIPadLight
        case aboutNoticesIPadLight
        case noticesUnavailableIPhoneDark
        case viewingOnlyIPadLight

        var appearance: UIUserInterfaceStyle {
            switch self {
            case .emptyIPhoneLight,
                 .liveIPadLight,
                 .connectingIPhoneLight,
                 .deviceDetailsPendingVersionIPadLight,
                 .aboutNoticesIPadLight,
                 .developerImageUnavailableIPadLight,
                 .xcodePreparationIPadLight,
                 .lockedIPhoneAccessibility,
                 .developerModeIPadAccessibility,
                 .viewingOnlyIPadLight:
                .light
            case .pairingIPhoneDark,
                 .liveIPadDark,
                 .liveIPhoneDark,
                 .liveLandscapeIPadTargetIPhoneDark,
                 .livePortraitIPadTargetLandscapeCodedIPadDark,
                 .landscapeRightPanelFixedIPad,
                 .offlineIPhoneDark,
                 .noticesUnavailableIPhoneDark,
                 .developerImageIncompatibleIPhoneDark,
                 .localNetworkDeniedIPadDark,
                 .deviceBusyIPhoneDark:
                .dark
            }
        }

        var size: CGSize {
            switch self {
            case .liveLandscapeIPadTargetIPhoneDark:
                CGSize(width: 956, height: 440)
            case .emptyIPhoneLight,
                 .pairingIPhoneDark,
                 .connectingIPhoneLight,
                 .liveIPhoneDark,
                 .offlineIPhoneDark,
                 .lockedIPhoneAccessibility,
                 .deviceBusyIPhoneDark,
                 .developerImageIncompatibleIPhoneDark,
                 .noticesUnavailableIPhoneDark:
                CGSize(width: 440, height: 956)
            default:
                CGSize(width: 1180, height: 820)
            }
        }

        var usesAccessibilityText: Bool {
            self == .lockedIPhoneAccessibility
                || self == .developerModeIPadAccessibility
        }
    }
#endif
