import SwiftUI

public enum IslandVolumeAnimation {
    public static let sliderTravelDuration: Double = 0.22
    public static let muteSlashDuration: Double = 0.24
    public static let muteIconDimmedOpacity: Double = 0.5

    public static var sliderTravel: Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: sliderTravelDuration)
    }

    public static var muteSlash: Animation {
        .easeInOut(duration: muteSlashDuration)
    }
}
