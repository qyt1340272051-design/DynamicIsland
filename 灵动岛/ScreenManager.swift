import AppKit
import Combine
import CoreGraphics

struct ScreenSnapshot: Equatable {
    let screens: [ScreenEnvironment]
    let mainDisplayID: CGDirectDisplayID?
}

@MainActor
public final class ScreenManager: ObservableObject {
    @Published public private(set) var screens: [ScreenEnvironment] = []
    @Published public private(set) var activeScreen: ScreenEnvironment?
    @Published public private(set) var selectionPolicy: ScreenSelectionPolicy

    private let notificationCenter: NotificationCenter
    private let snapshotProvider: () -> ScreenSnapshot
    private var screenParametersObservation: AnyCancellable?
    private var mainDisplayID: CGDirectDisplayID?

    public init(selectionPolicy: ScreenSelectionPolicy = .builtIn) {
        self.selectionPolicy = selectionPolicy
        self.notificationCenter = .default
        self.snapshotProvider = Self.captureSystemSnapshot
    }

    init(
        selectionPolicy: ScreenSelectionPolicy = .builtIn,
        notificationCenter: NotificationCenter,
        snapshotProvider: @escaping () -> ScreenSnapshot
    ) {
        self.selectionPolicy = selectionPolicy
        self.notificationCenter = notificationCenter
        self.snapshotProvider = snapshotProvider
    }

    public func startMonitoring() {
        if screenParametersObservation == nil {
            screenParametersObservation = notificationCenter
                .publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in
                    self?.refresh()
                }
        }

        refresh()
    }

    public func stopMonitoring() {
        screenParametersObservation?.cancel()
        screenParametersObservation = nil
    }

    public func setSelectionPolicy(_ selectionPolicy: ScreenSelectionPolicy) {
        guard self.selectionPolicy != selectionPolicy else {
            return
        }

        self.selectionPolicy = selectionPolicy
        selectActiveScreen()
    }

    public func refresh() {
        let snapshot = snapshotProvider()
        screens = snapshot.screens
        mainDisplayID = snapshot.mainDisplayID
        activeScreen = selectionPolicy.select(
            from: snapshot.screens,
            mainDisplayID: snapshot.mainDisplayID
        )
    }

    private func selectActiveScreen() {
        activeScreen = selectionPolicy.select(from: screens, mainDisplayID: mainDisplayID)
    }

    private static func captureSystemSnapshot() -> ScreenSnapshot {
        let appKitScreens = NSScreen.screens
        return ScreenSnapshot(
            screens: appKitScreens.compactMap(makeEnvironment),
            mainDisplayID: appKitScreens.first.flatMap(displayID)
        )
    }

    private static func makeEnvironment(from screen: NSScreen) -> ScreenEnvironment? {
        guard let displayID = displayID(from: screen) else {
            return nil
        }

        let safeAreaInsets = screen.safeAreaInsets
        return ScreenEnvironment(
            displayID: displayID,
            name: screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaInsets: ScreenEdgeInsets(
                top: safeAreaInsets.top,
                left: safeAreaInsets.left,
                bottom: safeAreaInsets.bottom,
                right: safeAreaInsets.right
            ),
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea ?? .zero,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea ?? .zero,
            backingScaleFactor: screen.backingScaleFactor,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0
        )
    }

    private static func displayID(from screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
