import CoreGraphics
import Foundation

public enum IslandCompactPlaybackAnimation {
    public nonisolated static let dotCount = 6
    public nonisolated static let dotWidth: CGFloat = 3
    public nonisolated static let dotSpacing: CGFloat = 2
    public nonisolated static let minimumHeight: CGFloat = 3
    public nonisolated static let maximumHeight: CGFloat = 16

    public nonisolated static var indicatorWidth: CGFloat {
        dotWidth * CGFloat(dotCount) + dotSpacing * CGFloat(dotCount - 1)
    }

    public nonisolated static func height(for index: Int, at time: TimeInterval) -> CGFloat {
        guard (0..<dotCount).contains(index) else {
            return minimumHeight
        }

        let localTime = time.truncatingRemainder(dividingBy: 240)
        let phase = Double(index) * 1.41
        let primarySpeed = 4.1 + Double(index % 3) * 0.63
        let secondarySpeed = 2.2 + Double((index * 2) % 5) * 0.27
        let primary = sin(localTime * primarySpeed + phase)
        let secondary = sin(localTime * secondarySpeed + phase * 0.67)
        let normalized = max(0, min(1, (primary * 0.68 + secondary * 0.32 + 1) / 2))

        return minimumHeight + (maximumHeight - minimumHeight) * CGFloat(normalized)
    }
}
