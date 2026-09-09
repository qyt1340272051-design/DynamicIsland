import SwiftUI

public enum IslandPomodoroPresetAnimation {
    public static let duration: Double = 0.2

    public static var animation: Animation {
        .easeInOut(duration: duration)
    }
}
