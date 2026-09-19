import SwiftUI

public enum IslandTimerModeTransition {
    public static let duration: Double = 0.3
    public static let shellDuration: Double = 0.16
    public static let outgoingDuration: Double = 0.12
    public static let incomingDuration: Double = 0.14
    public static let incomingDelay: Double = shellDuration
    public static let shellShrinkDelay: Double = outgoingDuration

    public static var animation: Animation {
        .easeInOut(duration: duration)
    }

    public static var shellGrowth: Animation {
        .easeOut(duration: shellDuration)
    }

    public static var shellShrink: Animation {
        .easeInOut(duration: shellDuration).delay(shellShrinkDelay)
    }

    public static var content: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeInOut(duration: incomingDuration).delay(incomingDelay)),
            removal: .opacity.animation(.easeOut(duration: outgoingDuration))
        )
    }
}
