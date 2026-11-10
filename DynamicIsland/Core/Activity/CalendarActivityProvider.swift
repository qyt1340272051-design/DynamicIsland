import Combine
import Foundation
import OSLog

/// Delivers the same selected-calendar reminder to the island while the app is
/// running. System notifications remain available when the island is hidden.
@MainActor
final class CalendarActivityProvider {
    nonisolated static let source = ActivitySource(kind: .builtIn, identifier: "calendar")
    private let manager: ActivityManager
    private var enabledObservation: AnyCancellable?
    private var eventsObservation: AnyCancellable?
    private var presentedEvents: [String: AgendaEvent] = [:]
    private let logger = Logger(subsystem: "DynamicIsland", category: "CalendarActivity")

    init(model: CalendarAgendaModel, manager: ActivityManager) {
        self.manager = manager
        model.onReminder = { [weak self] event in self?.publish(event) }
        enabledObservation = Publishers.CombineLatest(model.$remindersEnabled, model.$authorization).sink { [weak self] enabled, authorization in
            guard !enabled || authorization != .authorized, let self else { return }
            self.manager.endAll(source: Self.source)
            self.presentedEvents.removeAll()
        }
        eventsObservation = model.$events.sink { [weak self] events in
            guard let self else { return }
            let latest = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, event) in self.presentedEvents {
                let activityID = "builtin.calendar.\(id)"
                if latest[id] != event || self.manager.activity(id: activityID) == nil {
                    try? self.manager.end(id: activityID, source: Self.source)
                    self.presentedEvents.removeValue(forKey: id)
                }
            }
        }
    }

    private func publish(_ event: AgendaEvent) {
        do {
            try manager.publish(Self.makeActivity(for: event, createdAt: Date()))
            presentedEvents[event.id] = event
        }
        catch { logger.error("Calendar reminder could not be presented: \(String(describing: error), privacy: .public)") }
    }

    nonisolated static func makeActivity(for event: AgendaEvent, createdAt: Date) -> IslandActivity {
        let minutes = max(0, Int(ceil(event.startDate.timeIntervalSince(createdAt) / 60)))
        let time = minutes > 0 ? "\(minutes) 分钟后" : "即将开始"
        let title = shortened(event.title)
        let subtitle = shortened([time, event.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        let symbol = event.kind.systemImage
        return IslandActivity(
            id: "builtin.calendar.\(event.id)", source: source, priority: .important,
            lifecycle: .init(policy: .transient),
            presentation: .init(title: title, subtitle: subtitle, symbolName: symbol,
                minimal: .icon(.init(symbol)),
                compact: .hStack(.init([
                    .icon(.init(symbol)), .spacer(.init()), .text(.init(time))
                ])),
                expanded: .vStack(.init([
                    .text(.init("\(event.kind.title)提醒", color: .accent, font: .caption)),
                    .text(.init(title, font: .headline)),
                    .text(.init(subtitle, color: .secondary))
                ]))),
            createdAt: createdAt, expiresAt: createdAt.addingTimeInterval(12))
    }

    private nonisolated static func shortened(_ text: String) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= 128 else { break }
            result.append(character)
        }
        return result
    }
}
