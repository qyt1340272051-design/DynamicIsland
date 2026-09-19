import SwiftUI

public enum IslandFileTrayAnimation {
    public static let lockDuration: Double = 0.22
    public static let fileFadeDuration: Double = 0.24
    public static let impactHoldNanoseconds: UInt64 = 260_000_000

    public static var lock: Animation {
        .easeInOut(duration: lockDuration)
    }

    public static var fileFade: Animation {
        .easeInOut(duration: fileFadeDuration)
    }

    public static var impact: Animation {
        .spring(response: 0.22, dampingFraction: 0.58)
    }
}
