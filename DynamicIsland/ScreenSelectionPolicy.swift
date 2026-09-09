import CoreGraphics

public enum ScreenSelectionPolicy: Equatable, Sendable {
    case builtIn
    case main
    case display(CGDirectDisplayID)

    public nonisolated func select(
        from screens: [ScreenEnvironment],
        mainDisplayID: CGDirectDisplayID?
    ) -> ScreenEnvironment? {
        let builtInScreen = screens.first(where: \.isBuiltIn)
        let mainScreen = mainDisplayID.flatMap { displayID in
            screens.first(where: { $0.displayID == displayID })
        }

        switch self {
        case .builtIn:
            return builtInScreen ?? mainScreen ?? screens.first
        case .main:
            return mainScreen ?? builtInScreen ?? screens.first
        case .display(let displayID):
            return screens.first(where: { $0.displayID == displayID })
                ?? builtInScreen
                ?? mainScreen
                ?? screens.first
        }
    }
}
