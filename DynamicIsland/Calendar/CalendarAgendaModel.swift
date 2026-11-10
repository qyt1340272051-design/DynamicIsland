import AppKit
import Combine
import EventKit
import Foundation

@MainActor
public final class CalendarAgendaModel: ObservableObject {
    @Published public private(set) var authorization: CalendarAuthorization = .notDetermined
    @Published public private(set) var calendars: [AgendaCalendar] = []
    @Published public private(set) var events: [AgendaEvent] = []
    @Published public private(set) var selectedCalendarIDs: Set<String>
    @Published public private(set) var calendarKinds: [String: AgendaEventKind]
    @Published public private(set) var remindersEnabled: Bool
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isLoading = false
    @Published public var reminderMinutes: Int {
        didSet {
            let bounded = max(0, min(1_440, reminderMinutes))
            if reminderMinutes != bounded { reminderMinutes = bounded }
            defaults.set(bounded, forKey: Keys.reminderMinutes)
            queueRefresh(clearPending: true)
        }
    }
    public var onReminder: ((AgendaEvent) -> Void)?

    private enum Keys {
        static let selection = "agenda.selectedCalendarIDs"
        static let kinds = "agenda.calendarKinds"
        static let reminders = "agenda.remindersEnabled"
        static let reminderMinutes = "agenda.reminderMinutes"
    }
    private let defaults: UserDefaults
    private let service: any AgendaCalendarService
    private let scheduler: any AgendaReminderScheduling
    private let now: () -> Date
    private var hasStoredSelection: Bool
    private var refreshGeneration: UInt64 = 0
    private var preferenceGeneration: UInt64 = 0
    private var hasRequestedAccess = false
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var observations: [AnyCancellable] = []
    private var deliveredReminderIDs = Set<String>()

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, service: EventKitCalendarService(), scheduler: CalendarReminderScheduler())
    }

    init(defaults: UserDefaults, service: any AgendaCalendarService,
         scheduler: any AgendaReminderScheduling, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.service = service
        self.scheduler = scheduler
        self.now = now
        hasStoredSelection = defaults.object(forKey: Keys.selection) != nil
        selectedCalendarIDs = Set(defaults.stringArray(forKey: Keys.selection) ?? [])
        calendarKinds = (defaults.dictionary(forKey: Keys.kinds) as? [String: String] ?? [:])
            .compactMapValues(AgendaEventKind.init(rawValue:))
        remindersEnabled = defaults.bool(forKey: Keys.reminders)
        reminderMinutes = max(0, min(1_440, defaults.object(forKey: Keys.reminderMinutes) as? Int ?? 10))
    }

    public func start() {
        guard pollingTask == nil else { return }
        observations = [NotificationCenter.default.publisher(for: .EKEventStoreChanged),
                        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification),
                        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)]
            .map { publisher in publisher.sink { [weak self] _ in
                Task { @MainActor in self?.queueRefresh(clearPending: true) }
            } }
        queueRefresh(clearPending: true)
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                guard let self, !Task.isCancelled else { break }
                await self.refresh()
            }
        }
    }

    public func stop() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        observations.removeAll()
        isLoading = false
    }

    public func requestAccess() async {
        guard !hasRequestedAccess else { return }
        hasRequestedAccess = true
        defer { hasRequestedAccess = false }
        do {
            _ = try await service.requestAccess()
            await refresh()
        } catch {
            errorMessage = "无法获取日历权限：\(error.localizedDescription)"
        }
    }

    public func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        defer { if refreshGeneration == generation { isLoading = false } }
        let status = await service.authorization()
        guard refreshGeneration == generation, !Task.isCancelled else { return }
        authorization = status
        guard status == .authorized else {
            calendars = []
            events = []
            if status == .denied || status == .restricted { disableRemindersAfterRevocation() }
            errorMessage = status == .denied || status == .restricted
                ? "请在系统设置的“隐私与安全性 > 日历”中允许 Dynamic Island 访问日历。" : nil
            await scheduler.clear()
            return
        }
        do {
            let instant = now()
            let end = Calendar.current.date(byAdding: .day, value: 7, to: instant) ?? instant.addingTimeInterval(7 * 86_400)
            let snapshot = try await service.fetch(from: instant, to: end)
            let currentStatus = await service.authorization()
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            guard currentStatus == .authorized else {
                authorization = currentStatus
                calendars = []
                events = []
                disableRemindersAfterRevocation()
                errorMessage = "日历访问已关闭，请在系统设置的“隐私与安全性 > 日历”中重新授权。"
                await scheduler.clear()
                return
            }
            calendars = snapshot.calendars
            if !hasStoredSelection {
                selectedCalendarIDs = Set(calendars.map(\.id))
                persistSelection()
            }
            var seen = Set<String>()
            events = snapshot.events.filter {
                selectedCalendarIDs.contains($0.calendarID) && $0.endDate > instant && $0.startDate < end
                    && seen.insert($0.id).inserted
            }.map { event in
                var value = event
                value.kind = calendarKinds[event.calendarID] ?? event.kind
                return value
            }.sorted {
                $0.startDate == $1.startDate ? $0.id < $1.id : $0.startDate < $1.startDate
            }
            errorMessage = nil
            await updateReminders(generation: generation, now: instant)
        } catch {
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            errorMessage = "无法刷新日历：\(error.localizedDescription)"
        }
    }

    public func setCalendarSelected(_ id: String, isSelected: Bool) {
        if isSelected { selectedCalendarIDs.insert(id) } else { selectedCalendarIDs.remove(id) }
        persistSelection()
        // Immediately hide deselected data, even while a fresh fetch is pending.
        events.removeAll { !selectedCalendarIDs.contains($0.calendarID) }
        queueRefresh(clearPending: true)
    }

    public func kind(for calendarID: String) -> AgendaEventKind {
        calendarKinds[calendarID] ?? .suggested(forCalendarTitle: calendars.first { $0.id == calendarID }?.title ?? "")
    }

    public func setKind(_ kind: AgendaEventKind, for calendarID: String) {
        calendarKinds[calendarID] = kind
        defaults.set(calendarKinds.mapValues(\.rawValue), forKey: Keys.kinds)
        events = events.map {
            var event = $0
            if event.calendarID == calendarID { event.kind = kind }
            return event
        }
        queueRefresh(clearPending: true)
    }

    public func setRemindersEnabled(_ enabled: Bool) async {
        preferenceGeneration &+= 1
        let generation = preferenceGeneration
        if !enabled {
            refreshGeneration &+= 1
            refreshTask?.cancel()
            refreshTask = nil
            isLoading = false
            remindersEnabled = false
            defaults.set(false, forKey: Keys.reminders)
            await scheduler.clear()
            return
        }
        do {
            let allowed = try await scheduler.requestAuthorization()
            guard preferenceGeneration == generation else { return }
            guard allowed else {
                errorMessage = "通知权限未开启，请在系统设置的“通知 > Dynamic Island”中允许通知。"
                return
            }
            remindersEnabled = true
            defaults.set(true, forKey: Keys.reminders)
            await refresh()
        } catch {
            guard preferenceGeneration == generation else { return }
            errorMessage = "无法开启提醒：\(error.localizedDescription)"
        }
    }

    private func persistSelection() {
        hasStoredSelection = true
        defaults.set(selectedCalendarIDs.sorted(), forKey: Keys.selection)
    }

    private func queueRefresh(clearPending: Bool = false) {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            if clearPending { await self.scheduler.clear() }
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    private func updateReminders(generation: UInt64, now instant: Date) async {
        guard remindersEnabled else { return }
        let allowed = await scheduler.isAuthorized()
        guard refreshGeneration == generation, !Task.isCancelled, remindersEnabled else { return }
        guard allowed else {
            disableRemindersAfterRevocation()
            await scheduler.clear()
            errorMessage = "通知权限未开启，请在系统设置的“通知 > Dynamic Island”中允许通知。"
            return
        }
        do {
            let plan = AgendaReminderPlan.reminders(events: events, leadMinutes: reminderMinutes, now: instant)
            try await scheduler.replace(plan)
            guard refreshGeneration == generation, !Task.isCancelled, remindersEnabled else { return }
            let activeIDs = Set(events.map(\.id))
            deliveredReminderIDs = deliveredReminderIDs.intersection(activeIDs)
            for event in events where !event.isAllDay && event.endDate > instant {
                let reminder = AgendaReminder(event: event, fireDate: event.startDate.addingTimeInterval(-Double(reminderMinutes * 60)))
                let elapsed = instant.timeIntervalSince(reminder.fireDate)
                if elapsed >= 0, elapsed <= 60, deliveredReminderIDs.insert(event.id).inserted {
                    onReminder?(event)
                }
            }
        } catch {
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            errorMessage = "无法安排日程提醒：\(error.localizedDescription)"
        }
    }

    private func disableRemindersAfterRevocation() {
        preferenceGeneration &+= 1
        remindersEnabled = false
        defaults.set(false, forKey: Keys.reminders)
    }
}
