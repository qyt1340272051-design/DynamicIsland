import SwiftUI

public enum IslandSurfaceTransition {
    public static let duration: Double = 0.24

    public static var animation: Animation {
        .easeInOut(duration: duration)
    }

    public static var content: AnyTransition {
        .opacity
    }
}
