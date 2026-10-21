import Foundation
import SwiftUI

public enum IslandExpansionAnimation {
    public static let shellDuration: Double = 0.42
    public static let contentRevealDelay: Double = 0.1
    public static let contentRevealDuration: Double = 0.16
    public static let contentDismissDuration: Double = 0.19
    public static let compactContentScale: CGFloat = 0.9
    public static let compactActivityShellDuration: Double = 0.28
    public static let compactActivityContentScale: CGFloat = 0.94
    public static let expandedContentScale: CGFloat = 1
    public static let pointerHoverScale: CGFloat = 1.04

    public static var shell: Animation {
        .timingCurve(0.22, 0.0, 0.18, 1.0, duration: shellDuration)
    }

    public static var pointerHover: Animation {
        .easeOut(duration: 0.16)
    }

    /// A quick, non-overshooting horizontal reveal for transient compact
    /// content such as power and volume feedback.
    public static var compactActivityShell: Animation {
        .timingCurve(0.20, 0.82, 0.22, 1.0, duration: compactActivityShellDuration)
    }

    public static var contentReveal: Animation {
        .easeInOut(duration: contentRevealDuration).delay(contentRevealDelay)
    }

    public static var contentDismiss: Animation {
        .easeInOut(duration: contentDismissDuration)
    }
}
