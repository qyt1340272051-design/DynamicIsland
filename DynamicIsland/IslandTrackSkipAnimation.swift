import CoreGraphics
import Foundation

public enum IslandTrackSkipDirection: Equatable, Sendable {
    case backward
    case forward

    public nonisolated var multiplier: CGFloat {
        switch self {
        case .backward:
            return -1
        case .forward:
            return 1
        }
    }
}

public enum IslandTrackSkipAnimation {
    public nonisolated static let travelDistance: CGFloat = 8
    public nonisolated static let resetDistance: CGFloat = 6
    public nonisolated static let entryDuration: Double = 0.14
    public nonisolated static let exitDuration: Double = 0.26
    public nonisolated static let loopCount = 1

    public nonisolated static var totalDuration: Double {
        exitDuration + entryDuration
    }

    public nonisolated static func offset(
        for direction: IslandTrackSkipDirection,
        distance: CGFloat
    ) -> CGFloat {
        direction.multiplier * distance
    }
}
