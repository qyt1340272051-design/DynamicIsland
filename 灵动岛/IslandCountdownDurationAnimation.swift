import SwiftUI

public enum IslandCountdownDurationAnimation {
    public static let duration: Double = 0.2

    public static var animation: Animation {
        .easeInOut(duration: duration)
    }
}
