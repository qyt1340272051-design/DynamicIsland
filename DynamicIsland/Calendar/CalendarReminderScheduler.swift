import CryptoKit
import Foundation
import UserNotifications

nonisolated struct AgendaReminder: Equatable, Sendable {
    let event: AgendaEvent
    let fireDate: Date

    var identifier: String {
        let key = "\(event.id)|\(fireDate.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "island.agenda.\(digest)"
    }
}

nonisolated enum AgendaReminderPlan {
    static func reminders(events: [AgendaEvent], leadMinutes: Int, now: Date, limit: Int = 50) -> [AgendaReminder] {
        let lead = TimeInterval(max(0, min(1_440, leadMinutes)) * 60)
        var seen = Set<String>()
        var result: [AgendaReminder] = []
        for event in events where !event.isAllDay && event.endDate > now {
            let reminder = AgendaReminder(event: event, fireDate: event.startDate.addingTimeInterval(-lead))
            if reminder.fireDate > now, seen.insert(reminder.identifier).inserted { result.append(reminder) }
        }
        result.sort { lhs, rhs in
            if lhs.fireDate == rhs.fireDate { return lhs.event.id < rhs.event.id }
            return lhs.fireDate < rhs.fireDate
        }
        return Array(result.prefix(max(0, limit)))
    }
}

@MainActor
protocol AgendaReminderScheduling: AnyObject {
    func requestAuthorization() async throws -> Bool
    func isAuthorized() async -> Bool
    func replace(_ reminders: [AgendaReminder]) async throws
    func clear() async
}

@MainActor
final class CalendarReminderScheduler: AgendaReminderScheduling {
    private let center: UNUserNotificationCenter
    private let presentationDelegate = CalendarNotificationPresentationDelegate()
    private var generation = UUID()
    private var scheduledPlan: [AgendaReminder]?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        // A reminder must still appear when settings has activated the app or
        // the user has hidden the island. UN delegates are weakly retained.
        if center.delegate == nil { center.delegate = presentationDelegate }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func replace(_ reminders: [AgendaReminder]) async throws {
        // The model refreshes every 15 seconds. An unchanged plan must retain
        // its existing requests instead of issuing 50 remove/add IPCs each tick.
        guard scheduledPlan != reminders else { return }
        scheduledPlan = nil
        let requestGeneration = UUID()
        generation = requestGeneration
        let existing = await center.pendingNotificationRequests()
        guard generation == requestGeneration else { return }
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix("island.agenda.") })
        var addedIDs: [String] = []
        for reminder in reminders {
            guard generation == requestGeneration, !Task.isCancelled else { break }
            let interval = reminder.fireDate.timeIntervalSinceNow
            guard interval > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = reminder.event.kind == .event ? "日程提醒" : "\(reminder.event.kind.title)提醒"
            content.body = reminder.event.title
            if let location = reminder.event.location, !location.isEmpty { content.body += " · \(location)" }
            content.sound = .default
            // Generation suffix prevents a superseded task from removing a
            // newer reminder with the same event identifier during cleanup.
            let id = reminder.identifier + "." + requestGeneration.uuidString
            let request = UNNotificationRequest(identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false))
            do {
                try await center.add(request)
                addedIDs.append(id)
            } catch {
                center.removePendingNotificationRequests(withIdentifiers: addedIDs)
                throw error
            }
        }
        if generation != requestGeneration || Task.isCancelled {
            center.removePendingNotificationRequests(withIdentifiers: addedIDs)
        } else {
            scheduledPlan = reminders
        }
    }

    func clear() async {
        scheduledPlan = nil
        generation = UUID()
        let clearGeneration = generation
        let pending = await center.pendingNotificationRequests()
        guard generation == clearGeneration else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("island.agenda.") })
        let delivered = await center.deliveredNotifications()
        guard generation == clearGeneration else { return }
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix("island.agenda.") })
    }
}

private final class CalendarNotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
