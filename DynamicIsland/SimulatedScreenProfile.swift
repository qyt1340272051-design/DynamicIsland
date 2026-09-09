import CoreGraphics

public enum SimulatedScreenProfile: String, CaseIterable, Identifiable, Sendable {
    case macBookAir13 = "macbook-air-13"
    case macBookAir15 = "macbook-air-15"
    case macBookPro14 = "macbook-pro-14"
    case macBookPro16 = "macbook-pro-16"
    case external1080p = "external-1080p"
    case external1440p = "external-1440p"
    case external4K = "external-4k"
    case external5K = "external-5k"

    public nonisolated static let allCases: [SimulatedScreenProfile] = [
        .macBookAir13,
        .macBookAir15,
        .macBookPro14,
        .macBookPro16,
        .external1080p,
        .external1440p,
        .external4K,
        .external5K
    ]

    public nonisolated var id: String { rawValue }

    public nonisolated var displayName: String {
        switch self {
        case .macBookAir13:
            return "MacBook Air 13-inch"
        case .macBookAir15:
            return "MacBook Air 15-inch"
        case .macBookPro14:
            return "MacBook Pro 14-inch"
        case .macBookPro16:
            return "MacBook Pro 16-inch"
        case .external1080p:
            return "External 1080p"
        case .external1440p:
            return "External 1440p"
        case .external4K:
            return "External 4K"
        case .external5K:
            return "External 5K"
        }
    }

    public nonisolated var logicalSize: CGSize {
        switch self {
        case .macBookAir13:
            return CGSize(width: 1280, height: 832)
        case .macBookAir15:
            return CGSize(width: 1440, height: 932)
        case .macBookPro14:
            return CGSize(width: 1512, height: 982)
        case .macBookPro16:
            return CGSize(width: 1728, height: 1117)
        case .external1080p, .external4K:
            return CGSize(width: 1920, height: 1080)
        case .external1440p, .external5K:
            return CGSize(width: 2560, height: 1440)
        }
    }

    public nonisolated var defaultScaleFactor: CGFloat {
        switch self {
        case .external1080p, .external1440p:
            return 1
        case .macBookAir13, .macBookAir15, .macBookPro14, .macBookPro16, .external4K, .external5K:
            return 2
        }
    }

    public nonisolated var defaultNotchSize: CGSize {
        switch self {
        case .macBookAir13, .macBookAir15:
            return CGSize(width: 210, height: 36)
        case .macBookPro14, .macBookPro16:
            return CGSize(width: 216, height: 38)
        case .external1080p, .external1440p, .external4K, .external5K:
            return CGSize(width: 210, height: 32)
        }
    }

    public nonisolated var hasNotchByDefault: Bool {
        switch self {
        case .macBookAir13, .macBookAir15, .macBookPro14, .macBookPro16:
            return true
        case .external1080p, .external1440p, .external4K, .external5K:
            return false
        }
    }

    public nonisolated var isBuiltIn: Bool { hasNotchByDefault }

    public nonisolated var menuBarHeight: CGFloat {
        hasNotchByDefault ? defaultNotchSize.height : 24
    }

    public nonisolated var simulatedDisplayID: CGDirectDisplayID {
        switch self {
        case .macBookAir13:
            return 0xFFFF_0001
        case .macBookAir15:
            return 0xFFFF_0002
        case .macBookPro14:
            return 0xFFFF_0003
        case .macBookPro16:
            return 0xFFFF_0004
        case .external1080p:
            return 0xFFFF_0005
        case .external1440p:
            return 0xFFFF_0006
        case .external4K:
            return 0xFFFF_0007
        case .external5K:
            return 0xFFFF_0008
        }
    }

    public nonisolated var defaultConfiguration: ScreenSimulationConfiguration {
        ScreenSimulationConfiguration(profile: self)
    }
}

public struct ScreenSimulationConfiguration: Equatable, Sendable {
    public nonisolated static let minimumNotchWidth: CGFloat = 80
    public nonisolated static let maximumNotchWidth: CGFloat = 420
    public nonisolated static let minimumNotchHeight: CGFloat = 20
    public nonisolated static let maximumNotchHeight: CGFloat = 60
    public nonisolated static let minimumScaleFactor: CGFloat = 1
    public nonisolated static let maximumScaleFactor: CGFloat = 3

    public var profile: SimulatedScreenProfile
    public var simulatesNotch: Bool
    public var notchWidth: CGFloat
    public var notchHeight: CGFloat
    public var scaleFactor: CGFloat

    public nonisolated init(profile: SimulatedScreenProfile) {
        self.profile = profile
        self.simulatesNotch = profile.hasNotchByDefault
        self.notchWidth = profile.defaultNotchSize.width
        self.notchHeight = profile.defaultNotchSize.height
        self.scaleFactor = profile.defaultScaleFactor
    }

    public nonisolated init(
        profile: SimulatedScreenProfile,
        simulatesNotch: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        scaleFactor: CGFloat
    ) {
        self.profile = profile
        self.simulatesNotch = simulatesNotch
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.scaleFactor = scaleFactor
    }

    public nonisolated var logicalSize: CGSize { profile.logicalSize }

    public nonisolated var pixelSize: CGSize {
        let configuration = normalized
        return CGSize(
            width: configuration.logicalSize.width * configuration.scaleFactor,
            height: configuration.logicalSize.height * configuration.scaleFactor
        )
    }

    public nonisolated var normalized: ScreenSimulationConfiguration {
        var configuration = self
        let maximumWidth = min(Self.maximumNotchWidth, logicalSize.width / 2)
        configuration.notchWidth = min(max(notchWidth, Self.minimumNotchWidth), maximumWidth)
        configuration.notchHeight = min(
            max(notchHeight, Self.minimumNotchHeight),
            min(Self.maximumNotchHeight, logicalSize.height)
        )
        configuration.scaleFactor = min(
            max(scaleFactor, Self.minimumScaleFactor),
            Self.maximumScaleFactor
        )
        return configuration
    }

    public nonisolated func makeEnvironment(anchoredTo anchor: ScreenEnvironment? = nil) -> ScreenEnvironment {
        let configuration = normalized
        let size = configuration.logicalSize
        let origin = anchor.map { screen in
            CGPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height
            )
        } ?? .zero
        let frame = CGRect(origin: origin, size: size)
        let notchHeight = configuration.simulatesNotch ? configuration.notchHeight : 0
        let topReservedHeight = max(configuration.profile.menuBarHeight, notchHeight)
        let visibleFrame = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: max(frame.height - topReservedHeight, 0)
        )

        let auxiliaryAreas = configuration.auxiliaryAreas(in: frame)
        return ScreenEnvironment(
            displayID: configuration.profile.simulatedDisplayID,
            name: "Simulated \(configuration.profile.displayName)",
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaInsets: ScreenEdgeInsets(top: notchHeight),
            auxiliaryTopLeftArea: auxiliaryAreas.left,
            auxiliaryTopRightArea: auxiliaryAreas.right,
            backingScaleFactor: configuration.scaleFactor,
            isBuiltIn: configuration.profile.isBuiltIn
        )
    }

    private nonisolated func auxiliaryAreas(in frame: CGRect) -> (left: CGRect, right: CGRect) {
        guard simulatesNotch else {
            return (.zero, .zero)
        }

        let width = normalized.notchWidth
        let height = normalized.notchHeight
        let sideWidth = max((frame.width - width) / 2, 0)
        let y = frame.maxY - height
        return (
            CGRect(x: frame.minX, y: y, width: sideWidth, height: height),
            CGRect(x: frame.midX + width / 2, y: y, width: sideWidth, height: height)
        )
    }
}
