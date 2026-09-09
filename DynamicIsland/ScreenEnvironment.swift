import CoreGraphics

public nonisolated struct ScreenEdgeInsets: Equatable, Sendable {
    public let top: CGFloat
    public let left: CGFloat
    public let bottom: CGFloat
    public let right: CGFloat

    public nonisolated init(
        top: CGFloat = 0,
        left: CGFloat = 0,
        bottom: CGFloat = 0,
        right: CGFloat = 0
    ) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public nonisolated static let zero = ScreenEdgeInsets()
}

public nonisolated struct ScreenEnvironment: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let name: String
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let safeAreaInsets: ScreenEdgeInsets
    public let auxiliaryTopLeftArea: CGRect
    public let auxiliaryTopRightArea: CGRect
    public let backingScaleFactor: CGFloat
    public let isBuiltIn: Bool

    public nonisolated init(
        displayID: CGDirectDisplayID,
        name: String,
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaInsets: ScreenEdgeInsets = .zero,
        auxiliaryTopLeftArea: CGRect = .zero,
        auxiliaryTopRightArea: CGRect = .zero,
        backingScaleFactor: CGFloat = 1,
        isBuiltIn: Bool
    ) {
        self.displayID = displayID
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaInsets = safeAreaInsets
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.backingScaleFactor = backingScaleFactor
        self.isBuiltIn = isBuiltIn
    }

    public nonisolated var hasNotch: Bool {
        safeAreaInsets.top > 0
            && !auxiliaryTopLeftArea.isEmpty
            && !auxiliaryTopRightArea.isEmpty
            && auxiliaryTopRightArea.minX > auxiliaryTopLeftArea.maxX
    }
}
