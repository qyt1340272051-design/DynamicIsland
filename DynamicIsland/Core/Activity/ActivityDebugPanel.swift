#if DEBUG
import AppKit
import SwiftUI

enum ActivityDebugSample: String, CaseIterable, Identifiable {
    case music
    case battery
    case download

    var id: String { rawValue }

    var name: String {
        switch self {
        case .music: return "Music"
        case .battery: return "Battery"
        case .download: return "Download"
        }
    }

    var activityID: String { "debug.activity.\(rawValue)" }

    var source: ActivitySource {
        switch self {
        case .music: return ActivitySource(kind: .builtIn, identifier: "debug.music")
        case .battery: return ActivitySource(kind: .external, identifier: "debug.battery")
        case .download: return ActivitySource(kind: .plugin, identifier: "debug.download")
        }
    }

    var priority: ActivityPriority {
        switch self {
        case .music: return .background
        case .battery: return .important
        case .download: return .normal
        }
    }

    var policy: ActivityLifecycle.Policy {
        switch self {
        case .music: return .persistent
        case .battery: return .transient
        case .download: return .progress
        }
    }
}

/// Sends example data through the same public write API used by future
/// providers. The panel never mutates ActivityManager.current itself.
@MainActor
final class ActivityDebugProvider {
    let manager: ActivityManager
    private var revisions: [ActivityDebugSample: Int] = [:]

    init(manager: ActivityManager) {
        self.manager = manager
    }

    func publish(_ sample: ActivityDebugSample) throws {
        try manager.publish(makeActivity(sample, revision: 0))
        revisions[sample] = 0
    }

    func update(_ sample: ActivityDebugSample) throws {
        let revision = revisions[sample, default: 0] + 1
        try manager.update(makeActivity(sample, revision: revision))
        revisions[sample] = revision
    }

    func end(_ sample: ActivityDebugSample) throws {
        try manager.end(id: sample.activityID, source: sample.source)
        revisions.removeValue(forKey: sample)
    }

    private func makeActivity(_ sample: ActivityDebugSample, revision: Int) -> IslandActivity {
        let presentation: ActivityPresentation
        let actions: [ActivityAction]
        switch sample {
        case .music:
            presentation = ActivityPresentation(
                title: "Music · Track \(revision + 1)",
                subtitle: "Debug Artist",
                symbolName: "music.note"
            )
            actions = [ActivityAction(id: "playPause", title: "Play or pause")]
        case .battery:
            presentation = ActivityPresentation(
                title: "Battery · \(max(1, 15 - revision))%",
                subtitle: "Low battery sample",
                symbolName: "battery.25percent"
            )
            actions = []
        case .download:
            presentation = ActivityPresentation(
                title: "Download · \(min(95, 25 + revision * 20))%",
                subtitle: "Sample.zip",
                symbolName: "arrow.down.circle",
                progress: Double(min(95, 25 + revision * 20)) / 100
            )
            actions = [ActivityAction(id: "cancel", title: "Cancel")]
        }
        return IslandActivity(
            id: sample.activityID,
            source: sample.source,
            priority: sample.priority,
            lifecycle: ActivityLifecycle(policy: sample.policy),
            presentation: presentation,
            createdAt: Date(),
            actions: actions
        )
    }
}

@MainActor
final class ActivityDebugWindowController: NSWindowController {
    private let manager: ActivityManager
    private let provider: ActivityDebugProvider
    private let router: ActionRouter

    init() {
        let manager = ActivityManager()
        let provider = ActivityDebugProvider(manager: manager)
        let router = ActionRouter(manager: manager)
        self.manager = manager
        self.provider = provider
        self.router = router

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 470, height: 440),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Activity Debug"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 440, height: 400)
        panel.contentViewController = NSHostingController(
            rootView: ActivityDebugView(
                manager: manager,
                provider: provider,
                router: router
            )
        )
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }
}

struct ActivityDebugView: View {
    @ObservedObject var manager: ActivityManager
    let provider: ActivityDebugProvider
    let router: ActionRouter
    @State private var errorText: String?
    @State private var previewMode: ActivityPresentation.Mode = .expanded

    init(
        manager: ActivityManager,
        provider: ActivityDebugProvider,
        router: ActionRouter? = nil
    ) {
        self.manager = manager
        self.provider = provider
        self.router = router ?? ActionRouter(manager: manager)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Activity Engine · Debug")
                    .font(.headline)

                ForEach(ActivityDebugSample.allCases) { sample in
                    HStack {
                        Text(sample.name)
                            .frame(width: 90, alignment: .leading)
                        Button("Publish") { perform { try provider.publish(sample) } }
                        Button("Update") { perform { try provider.update(sample) } }
                        Button("End") { perform { try provider.end(sample) } }
                        Spacer(minLength: 0)
                    }
                }

                Divider()

                if let snapshot = manager.currentSnapshot {
                    let current = snapshot.activity
                    VStack(alignment: .leading, spacing: 6) {
                        Text(current.presentation.title)
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier("activity-debug-current-title")
                        if let subtitle = current.presentation.subtitle {
                            Text(subtitle).foregroundStyle(.secondary)
                        }
                        if let progress = current.presentation.progress {
                            ProgressView(value: min(max(progress, 0), 1))
                        }
                        Text("\(current.id) · \(current.source.kind.rawValue) · \(current.lifecycle.state.rawValue)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        Picker("Presentation", selection: $previewMode) {
                            ForEach(ActivityPresentation.Mode.allCases, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        IslandRenderer(
                            presentation: current.presentation,
                            mode: previewMode,
                            shellSize: previewShellSize,
                            onAction: { action in
                                let result = router.dispatch(
                                    id: current.id,
                                    source: current.source,
                                    instanceToken: snapshot.instanceToken,
                                    action: action
                                )
                                if result != .handled { errorText = String(describing: result) }
                            }
                        )
                        .frame(width: previewShellSize.width, height: previewShellSize.height)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("activity-debug-renderer")
                    }
                } else {
                    Text("No current Activity")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("activity-debug-empty")
                }

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 440, idealWidth: 470, minHeight: 400, idealHeight: 440)
    }

    private var previewShellSize: CGSize {
        switch previewMode {
        case .minimal: CGSize(width: 120, height: 32)
        case .compact: CGSize(width: 220, height: 38)
        case .expanded: CGSize(width: 350, height: 190)
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }
}
#endif
