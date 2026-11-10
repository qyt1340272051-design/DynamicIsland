import AppKit
import SwiftUI
import Vision
import XCTest
@testable import DynamicIsland

/// Native windows and pixel-derived clicks exercise the authored home shell.
/// These fixtures do not substitute for physical trackpad/notch acceptance.
@MainActor
final class IslandHomeIntegrationTests: XCTestCase {
    func testLayerSelectorStaysCenteredBesideTrailingPageCounterAtNativeScales() async throws {
        for notchHeight: CGFloat in [32, 56] {
            let fixture = try await makeFixture(notchHeight: notchHeight)
            defer { fixture.close() }
            try capture(fixture, name: "selector-centered-\(Int(notchHeight))")
            let image = try bitmap(in: fixture)
            let scale = fixture.model.displayLayout.expandedScale
            let pixelScale = CGFloat(image.pixelsWide) / fixture.hosting.bounds.width
            let selectorTop = (IslandVisualStyle.expandedContentPadding
                + IslandVisualStyle.expandedSurfaceSwitcherHeight + IslandVisualStyle.expandedSurfaceSpacing) * scale
            let rowStart = Int(selectorTop * pixelScale)
            let rowEnd = Int((selectorTop + 20 * scale) * pixelScale)
            // Measure the four painted label groups rather than relying on
            // OCR for 8.8pt Chinese glyphs. Capsule fill stays below this text
            // threshold; the trailing counter lies outside the central strip.
            let start = Int((fixture.hosting.bounds.midX - 150 * scale) * pixelScale)
            let end = Int((fixture.hosting.bounds.midX + 150 * scale) * pixelScale)
            let active = (start..<end).filter { x in
                (rowStart..<rowEnd).contains { y in
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.alphaComponent > 0.5 && max(color.redComponent, color.greenComponent, color.blueComponent) > 0.28
                }
            }
            let labelGap = Int(ceil(6 * scale * pixelScale))
            var groups: [ClosedRange<Int>] = []
            for column in active {
                if let last = groups.last, column - last.upperBound <= labelGap {
                    groups[groups.count - 1] = last.lowerBound...column
                } else { groups.append(column...column) }
            }
            XCTAssertEqual(groups.count, IslandHomeLayer.allCases.count, "All four selector labels must remain visible.")
            let first = try XCTUnwrap(groups.first)
            let last = try XCTUnwrap(groups.last)
            let clusterMidpoint = CGFloat(first.lowerBound + last.upperBound) / 2 / pixelScale
            XCTAssertEqual(clusterMidpoint, fixture.hosting.bounds.midX,
                           accuracy: 2 * scale,
                           "The trailing page count must not displace the selector from the home center.")
        }
    }

    func testHidingSelectorPersistsAndKeepsSwipeNavigationAndMusicControlsAvailable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let scale = fixture.model.displayLayout.expandedScale
        fixture.homeSettings.showsLayerButtons = false
        try await settle(fixture)
        XCTAssertFalse(IslandHomeSettings(defaults: fixture.defaults).showsLayerButtons)
        XCTAssertEqual(fixture.runtime.expandedShellSize.height, IslandVisualStyle.expandedMusicHeight)
        let music = try renderedText(in: fixture)
        XCTAssertTrue(music.contains("Home test song"), music)
        XCTAssertFalse(music.contains("音乐"), music)
        XCTAssertFalse(music.contains("课程"), music)
        let monitor = try XCTUnwrap(descendants(fixture.hosting)
            .compactMap { $0 as? IslandHomeScrollMonitorView }
            .first { $0.isPagingEnabled && $0.bounds.height > 40 * scale })
        XCTAssertTrue(monitor.isPagingEnabled)
        XCTAssertGreaterThanOrEqual(monitor.exclusionRects.count, 2)
        let shell = fixture.model.displayLayout.scaledExpanded(fixture.runtime.expandedShellSize)
        let top = fixture.hosting.isFlipped ? CGFloat(0) : fixture.hosting.bounds.height - shell.height
        let shellBounds = CGRect(x: (fixture.hosting.bounds.width - shell.width) / 2,
                                y: top, width: shell.width, height: shell.height)
        for exclusion in monitor.exclusionRects {
            XCTAssertGreaterThan(exclusion.width, 60 * scale)
            XCTAssertTrue(shellBounds.insetBy(dx: -1, dy: -1).contains(monitor.convert(exclusion, to: fixture.hosting)))
        }
        try capture(fixture, name: "selector-hidden-music")

        monitor.onStep?(1)
        try await settle(fixture)
        XCTAssertEqual(fixture.model.homeLayer, .calendar)
        XCTAssertTrue(try renderedText(in: fixture).contains("Dentist visit"))
        XCTAssertTrue(monitor.isPagingEnabled)
        let center = monitor.convert(CGPoint(x: monitor.bounds.midX, y: monitor.bounds.midY), to: nil)
        XCTAssertTrue(monitor.isGestureEligible(at: center, in: fixture.panel))
        try capture(fixture, name: "selector-hidden-calendar")

        fixture.homeSettings.showsLayerButtons = true
        try await settle(fixture)
        XCTAssertTrue(IslandHomeSettings(defaults: fixture.defaults).showsLayerButtons)
        XCTAssertEqual(fixture.model.homeLayer, .calendar)
        XCTAssertEqual(fixture.runtime.expandedShellSize.height, IslandVisualStyle.expandedHomeHeight)
        try await clickText("课程", in: fixture)
        XCTAssertEqual(fixture.model.homeLayer, .courses)
    }

    func testLayerButtonsFilterRenderedAgendaAndHomeReturnsFromTools() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        XCTAssertEqual(fixture.model.homeLayer, .music)
        let initialLabels = accessibilityLabels(fixture.hosting)
        if initialLabels.contains("主页") {
            XCTAssertFalse(initialLabels.contains("island-surface-music"))
        }

        for (layer, expected, excluded) in [
            (IslandHomeLayer.calendar, "Dentist visit", ""),
            (.courses, "Calculus lecture", "Dentist visit"),
            (.meetings, "Design review", "Calculus lecture"),
            (.music, "Home test song", "Design review")
        ] {
            try await clickText(layer.title, in: fixture)
            XCTAssertEqual(fixture.model.homeLayer, layer)
            let text = try renderedText(in: fixture)
            XCTAssertTrue(text.contains(expected), "\(layer): missing event/music content; OCR=\(text)")
            if !excluded.isEmpty { XCTAssertFalse(text.contains(excluded), "\(layer): OCR=\(text)") }
            try capture(fixture, name: layer.rawValue)
        }

        fixture.runtime.selectLegacySurface(.tools)
        try await settle(fixture)
        XCTAssertEqual(fixture.model.expandedSurface, .tools)
        // The first native input target in the switcher is the house button.
        // Its position is shared with the previous music-region control.
        let scale = fixture.model.displayLayout.expandedScale
        let leading = (fixture.hosting.bounds.width - IslandVisualStyle.expandedContentSize.width * scale) / 2
            + IslandVisualStyle.expandedContentPadding * scale
        let topPoint = CGPoint(x: leading + 14 * scale,
                               y: (IslandVisualStyle.expandedContentPadding + 14) * scale)
        let point = fixture.hosting.isFlipped ? topPoint
            : CGPoint(x: topPoint.x, y: fixture.hosting.bounds.height - topPoint.y)
        try await click(point, in: fixture)
        XCTAssertEqual(fixture.model.expandedSurface, .music)
        XCTAssertEqual(fixture.model.homeLayer, .music)
        XCTAssertTrue(try renderedText(in: fixture).contains("Home test song"))
        try capture(fixture, name: "house-button-return")
    }

    func testCalendarPermissionAndEmptyStatesRemainActionable() async throws {
        let fixture = try await makeFixture(authorization: .notDetermined)
        defer { fixture.close() }
        fixture.model.selectHomeLayer(.calendar)
        try await settle(fixture)
        var text = try renderedText(in: fixture)
        XCTAssertTrue(text.contains("连接你的日历"), text)
        try capture(fixture, name: "permission")
        try await clickText("连接日历", in: fixture)
        XCTAssertEqual(fixture.witness.settingsRequests, 1)

        await fixture.service.set(authorization: .authorized, events: [])
        await fixture.agenda.refresh()
        for (layer, title) in [(IslandHomeLayer.calendar, "暂无日程"), (.courses, "暂无课程"), (.meetings, "暂无会议")] {
            fixture.model.selectHomeLayer(layer)
            try await settle(fixture)
            text = try renderedText(in: fixture)
            XCTAssertTrue(text.contains(title), text)
            XCTAssertTrue(text.contains("管理日历"), text)
            try capture(fixture, name: "empty-\(layer.rawValue)")
        }
    }

    func testHomeLayerUsesDefaultAfterFoldingAndPreservesRegionNavigationAndSteppingGuards() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let model = fixture.model
        model.selectHomeLayer(.courses)
        model.endHovering()
        XCTAssertEqual(model.presentationState, .compact)
        XCTAssertEqual(model.homeLayer, .courses)
        model.setHovering(true)
        XCTAssertEqual(model.expandedSurface, .music)
        XCTAssertEqual(model.homeLayer, .music, "A new expansion applies the configured default layer.")
        model.selectHomeLayer(.courses)
        for surface in [IslandExpandedSurface.fileTray, .tools, .utilities] {
            fixture.runtime.selectLegacySurface(surface)
            model.stepHomeLayer(by: 1)
            XCTAssertEqual(model.homeLayer, .courses)
            fixture.runtime.selectLegacySurface(.music)
            XCTAssertEqual(model.homeLayer, .courses)
        }
        model.setDragging(true)
        model.selectExpandedSurface(.music)
        model.stepHomeLayer(by: 1)
        XCTAssertEqual(model.homeLayer, .courses)
        model.setDragging(false)
        model.setIslandPanelVisible(false)
        model.stepHomeLayer(by: 1)
        XCTAssertEqual(model.homeLayer, .courses)
        model.setIslandPanelVisible(true)
        model.stepHomeLayer(by: 1)
        XCTAssertEqual(model.homeLayer, .meetings)
        model.stepHomeLayer(by: 1)
        XCTAssertEqual(model.homeLayer, .music, "The fourth layer wraps to the first.")
        model.stepHomeLayer(by: -1)
        XCTAssertEqual(model.homeLayer, .meetings, "The first layer wraps back to the fourth.")
        model.stepHomeLayer(by: -1)
        XCTAssertEqual(model.homeLayer, .courses)

        let start = Date()
        model.timerTools.selectedMode = .countdown
        model.timerTools.startSelectedTimer(at: start)
        model.timerTools.refresh(at: start.addingTimeInterval(model.timerTools.countdownDuration))
        XCTAssertTrue(model.isTimerCompletionPresented)
        model.selectExpandedSurface(.music)
        model.stepHomeLayer(by: 1)
        XCTAssertEqual(model.expandedSurface, .tools)
        XCTAssertEqual(model.homeLayer, .courses)
    }

    func testMusicKeepsBothSlidersAndTimelineInsideHomeShellAtNativeScales() async throws {
        for notchHeight: CGFloat in [32, 56] {
            let fixture = try await makeFixture(notchHeight: notchHeight)
            defer { fixture.close() }
            let scale = fixture.model.displayLayout.expandedScale
            let shell = fixture.model.displayLayout.scaledExpanded(fixture.runtime.expandedShellSize)
            let top = fixture.hosting.isFlipped ? CGFloat(0) : fixture.hosting.bounds.height - shell.height
            let visibleShell = CGRect(x: (fixture.hosting.bounds.width - shell.width) / 2,
                                      y: top, width: shell.width, height: shell.height)
            let monitor = try XCTUnwrap(descendants(fixture.hosting)
                .compactMap { $0 as? IslandHomeScrollMonitorView }
                .first { $0.isPagingEnabled && $0.bounds.height > 40 * scale })
            XCTAssertGreaterThan(monitor.bounds.width, 200 * scale)
            XCTAssertGreaterThan(monitor.bounds.height, 80 * scale)
            XCTAssertGreaterThanOrEqual(monitor.exclusionRects.count, 2,
                                       "Playback and volume must report their actual SwiftUI slider bounds.")
            for exclusion in monitor.exclusionRects {
                let rect = monitor.convert(exclusion, to: fixture.hosting)
                XCTAssertGreaterThan(rect.width, 60 * scale)
                XCTAssertTrue(visibleShell.insetBy(dx: -1, dy: -1).contains(rect),
                              "Music slider cropped by home shell: \(rect) outside \(visibleShell)")
                let windowPoint = monitor.convert(CGPoint(x: exclusion.midX, y: exclusion.midY), to: nil)
                XCTAssertFalse(monitor.isGestureEligible(at: windowPoint, in: fixture.panel),
                               "Two-finger scrolling a SwiftUI slider must not turn the page.")
            }
            if scale > 1.3 {
                let text = try renderedText(in: fixture)
                XCTAssertTrue(text.contains("1:25") && text.contains("5:00"), text)
            }
            try capture(fixture, name: "music-controls-\(Int(notchHeight))")
        }
    }

    private func makeFixture(authorization: CalendarAuthorization = .authorized,
                             notchHeight: CGFloat = 56) async throws -> HomeIntegrationFixture {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Native home input fixtures require an unlocked macOS session.")
        }
        let fixture = try await HomeIntegrationFixture(authorization: authorization, notchHeight: notchHeight)
        try await settle(fixture)
        return fixture
    }

    private func clickText(_ label: String, in fixture: HomeIntegrationFixture) async throws {
        let matches = try recognizedText(in: fixture).compactMap { observation -> CGRect? in
            guard let candidate = observation.topCandidates(1).first,
                  let range = candidate.string.range(of: label),
                  let bounds = try? candidate.boundingBox(for: range) else { return nil }
            return bounds.boundingBox
        }
        let text = try renderedText(in: fixture)
        let bounds = try XCTUnwrap(matches.max { $0.midY < $1.midY },
                                   "Missing rendered clickable label \(label): \(text)")
        try await click(CGPoint(x: bounds.midX * fixture.hosting.bounds.width,
            y: (fixture.hosting.isFlipped ? 1 - bounds.midY : bounds.midY) * fixture.hosting.bounds.height), in: fixture)
    }

    private func click(_ point: CGPoint, in fixture: HomeIntegrationFixture) async throws {
        NSApp.activate()
        fixture.panel.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !fixture.panel.isKeyWindow {
            guard ContinuousClock.now < deadline else {
                NativeWindowTestingDiagnostics.keyTimeout(fixture.panel)
                throw HomeIntegrationError.keyWindowTimeout
            }
            fixture.panel.makeKey()
            try await Task.sleep(for: .milliseconds(10))
        }
        let location = fixture.hosting.convert(point, to: nil)
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(events[1], atStart: true)
        NSApp.sendEvent(events[0])
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                    inMode: .eventTracking, dequeue: true) { NSApp.sendEvent(up) }
        try await settle(fixture)
    }

    private func settle(_ fixture: HomeIntegrationFixture) async throws {
        // Home layers now crossfade for 300 ms. Capture the settled destination
        // after that interval so outgoing controls do not pollute evidence.
        try await Task.sleep(for: .milliseconds(400))
        fixture.hosting.layoutSubtreeIfNeeded()
        fixture.hosting.displayIfNeeded()
    }

    private func bitmap(in fixture: HomeIntegrationFixture) throws -> NSBitmapImageRep {
        let view = fixture.hosting
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(view.bounds.width * 2)), pixelsHigh: Int(ceil(view.bounds.height * 2)), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func recognizedText(in fixture: HomeIntegrationFixture) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.customWords = ["Dentist visit", "Calculus lecture", "Design review", "Home test song", "1:25", "5:00"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap(in: fixture).cgImage), options: [:]).perform([request])
        return request.results ?? []
    }

    private func renderedText(in fixture: HomeIntegrationFixture) throws -> String {
        try recognizedText(in: fixture).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func capture(_ fixture: HomeIntegrationFixture, name: String) throws {
        let data = try XCTUnwrap(bitmap(in: fixture).representation(using: .png, properties: [:]))
        try data.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamic-island-home-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "Home-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }

    private func accessibilityLabels(_ root: NSView) -> Set<String> {
        var labels = Set<String>(), seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) {
            let object = value as AnyObject
            guard seen.count < 4_096, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let element = value as? NSAccessibilityProtocol {
                if let label = element.accessibilityLabel() { labels.insert(label) }
                if let identifier = element.accessibilityIdentifier() { labels.insert(identifier) }
                element.accessibilityChildren()?.forEach(visit)
            }
            (value as? NSView)?.subviews.forEach(visit)
        }
        visit(root)
        return labels
    }
}

@MainActor
private final class HomeIntegrationFixture {
    let model: IslandViewModel
    let agenda: CalendarAgendaModel
    let service: HomeIntegrationCalendarService
    let runtime: IslandActivityRuntime
    let hosting: NSHostingView<AnyView>
    let panel: NSPanel
    let witness = HomeIntegrationSettingsWitness()
    let defaults: UserDefaults
    let homeSettings: IslandHomeSettings
    private let suite = "IslandHomeIntegrationTests.\(UUID().uuidString)"

    init(authorization: CalendarAuthorization, notchHeight: CGFloat) async throws {
        let now = Date()
        service = HomeIntegrationCalendarService(authorization: authorization, now: now)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        homeSettings = IslandHomeSettings(defaults: defaults)
        agenda = CalendarAgendaModel(defaults: defaults, service: service,
                                    scheduler: HomeIntegrationScheduler(), now: { now })
        await agenda.refresh()
        let music = MusicActivityTestService(info: .init(isPlaying: false, title: "Home test song", artist: "Artist",
            album: "Album", duration: 300, position: 85, trackIdentifier: "home-test"))
        model = IslandViewModel(volumeService: MusicActivityTestVolume(), fileTrayService: MusicActivityTestTray(),
            sharingService: MusicActivityTestSharing(), musicService: music,
            hapticFeedbackService: MusicActivityTestHaptic(), nowPlayingPollIntervalNanoseconds: 3_600_000_000_000,
            calendarAgenda: agenda, homeSettings: homeSettings)
        let screenWidth: CGFloat = 2560, height: CGFloat = 1664, notchWidth = notchHeight * 5.6
        let side = (screenWidth - notchWidth) / 2
        model.setScreenEnvironment(.init(displayID: 1, name: "Home Synthetic Display",
            frame: CGRect(x: 0, y: 0, width: screenWidth, height: height),
            visibleFrame: CGRect(x: 0, y: 0, width: screenWidth, height: height - notchHeight),
            safeAreaInsets: .init(top: notchHeight),
            auxiliaryTopLeftArea: CGRect(x: 0, y: height - notchHeight, width: side, height: notchHeight),
            auxiliaryTopRightArea: CGRect(x: side + notchWidth, y: height - notchHeight, width: side, height: notchHeight),
            backingScaleFactor: 2, isBuiltIn: true))
        model.setHovering(true)
        await model.refreshNowPlaying()
        runtime = IslandActivityRuntime(viewModel: model)
        let witness = witness
        hosting = NSHostingView(rootView: AnyView(IslandView(viewModel: model, activityRuntime: runtime,
            requestTermination: { XCTFail("Home navigation must never activate Quit.") },
            onOpenSettings: { witness.settingsRequests += 1 })
            .environment(\.colorScheme, .dark).transaction { $0.disablesAnimations = true }))
        hosting.frame = CGRect(origin: .zero, size: model.displayLayout.panelSize)
        panel = NSPanel(contentRect: hosting.frame, styleMask: [.titled, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let container = NSView(frame: hosting.frame)
        panel.contentView = container
        container.addSubview(hosting)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.close()
        runtime.shutdownPlugins()
        agenda.stop()
        model.setIslandPanelVisible(false)
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor HomeIntegrationCalendarService: AgendaCalendarService {
    private var status: CalendarAuthorization
    private var snapshot: AgendaStoreSnapshot

    init(authorization: CalendarAuthorization, now: Date) {
        status = authorization
        snapshot = .init(calendars: [
            .init(id: "personal", title: "Personal", sourceTitle: "iCloud", source: .apple),
            .init(id: "courses", title: "Courses", sourceTitle: "Google", source: .google),
            .init(id: "meetings", title: "Meetings", sourceTitle: "Google", source: .google)
        ], events: [
            .init(id: "dentist", title: "Dentist visit", startDate: now.addingTimeInterval(600),
                  endDate: now.addingTimeInterval(1200), calendarID: "personal"),
            .init(id: "calculus", title: "Calculus lecture", startDate: now.addingTimeInterval(1200),
                  endDate: now.addingTimeInterval(2400), calendarID: "courses", kind: .course),
            .init(id: "review", title: "Design review", startDate: now.addingTimeInterval(2400),
                  endDate: now.addingTimeInterval(3600), calendarID: "meetings", kind: .meeting)
        ])
    }

    func authorization() -> CalendarAuthorization { status }
    func requestAccess() -> Bool { status == .authorized }
    func fetch(from start: Date, to end: Date) -> AgendaStoreSnapshot { snapshot }
    func set(authorization: CalendarAuthorization, events: [AgendaEvent]) {
        status = authorization
        snapshot.events = events
    }
}

@MainActor
private final class HomeIntegrationScheduler: AgendaReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func isAuthorized() async -> Bool { true }
    func replace(_ reminders: [AgendaReminder]) async throws {}
    func clear() async {}
}

@MainActor
private final class HomeIntegrationSettingsWitness { var settingsRequests = 0 }
private enum HomeIntegrationError: Error { case keyWindowTimeout }
