import SwiftUI

public enum IslandQuitAnimation {
    public static let impactHoldNanoseconds: UInt64 = 120_000_000
    public static let reboundWaitNanoseconds: UInt64 = 150_000_000
    public static let fadeDuration: Double = 0.36
    public static let fadeWaitNanoseconds: UInt64 = 400_000_000
    public static let pressedScale: CGFloat = 0.74

    public static var impact: Animation {
        .spring(response: 0.18, dampingFraction: 0.65)
    }

    public static var islandFade: Animation {
        .easeInOut(duration: fadeDuration)
    }
}
