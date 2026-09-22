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

    init() {
        let manager = ActivityManager()
        let provider = ActivityDebugProvider(manager: manager)
        self.manager = manager
        self.provider = provider

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 470, height: 350),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Activity Debug"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 440, height: 320)
        panel.contentViewController = NSHostingController(
            rootView: ActivityDebugView(manager: manager, provider: provider)
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
    @State private var errorText: String?

    var body: some View {
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

            if let current = manager.current {
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
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 440, idealWidth: 470, minHeight: 320, idealHeight: 350)
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
