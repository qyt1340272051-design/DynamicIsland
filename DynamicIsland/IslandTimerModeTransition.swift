import SwiftUI

public enum IslandTimerModeTransition {
    public static let duration: Double = 0.22

    public static var animation: Animation {
        .easeInOut(duration: duration)
    }

    public static var content: AnyTransition {
        .opacity
    }
}
