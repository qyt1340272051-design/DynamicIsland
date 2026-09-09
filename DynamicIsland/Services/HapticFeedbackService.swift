import AppKit

public protocol HapticFeedbackService {
    func performExpansionFeedback()
}

public struct TrackpadHapticFeedbackService: HapticFeedbackService {
    public static let expansionPattern: NSHapticFeedbackManager.FeedbackPattern = .generic

    public init() {}

    public func performExpansionFeedback() {
        NSHapticFeedbackManager.defaultPerformer.perform(Self.expansionPattern, performanceTime: .now)
    }
}
