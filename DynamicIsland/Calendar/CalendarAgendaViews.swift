import AppKit
import SwiftUI

@MainActor
struct IslandAgendaView: View {
    @ObservedObject var model: CalendarAgendaModel
    let filter: AgendaEventKind?
    let onOpenSettings: @MainActor () -> Void
    @Environment(\.islandLayoutScale) private var scale

    private func p(_ value: CGFloat) -> CGFloat { value * scale }

    private var filteredEvents: [AgendaEvent] {
        model.events.filter { filter == nil || $0.kind == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: p(7)) {
            HStack(spacing: p(6)) {
                Text(Date.now.formatted(.dateTime.month().day().weekday(.abbreviated)))
                    .font(.system(size: p(12), weight: .semibold))
                Spacer(minLength: 0)
                if model.isLoading {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                Text("未来 7 天")
                    .font(.system(size: p(10)))
                    .foregroundStyle(.white.opacity(0.46))
                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: p(11), weight: .medium))
                        .frame(width: p(22), height: p(22))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("设置日历与提醒")
                .accessibilityLabel("设置日历与提醒")
                .accessibilityIdentifier("island-agenda-settings")
            }
            .frame(height: p(22))

            if model.authorization != .authorized {
                emptyState(symbol: "calendar.badge.exclamationmark", title: "连接你的日历",
                           detail: "在设置中接入 Apple 和 Google 日历", action: "连接日历")
            } else if let error = model.errorMessage, filteredEvents.isEmpty {
                emptyState(symbol: "exclamationmark.circle", title: "暂时无法读取日程",
                           detail: error, action: "查看设置")
            } else if filteredEvents.isEmpty {
                emptyState(symbol: filter?.systemImage ?? "calendar", title: emptyTitle,
                           detail: model.selectedCalendarIDs.isEmpty ? "先在设置中选择日历" : "未来 7 天没有安排，留一点时间给自己。",
                           action: "管理日历")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: p(5)) {
                        ForEach(filteredEvents) { event in
                            eventRow(event)
                        }
                    }
                }
                .accessibilityIdentifier("island-agenda-events")
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("island-agenda-\(filter?.rawValue ?? "all")")
    }

    private var emptyTitle: String {
        switch filter {
        case .course: "暂无课程"
        case .meeting: "暂无会议"
        default: "暂无日程"
        }
    }

    private func emptyState(symbol: String, title: String, detail: String, action: String) -> some View {
        HStack(spacing: p(12)) {
            Image(systemName: symbol)
                .font(.system(size: p(27), weight: .light))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: p(38))
            VStack(alignment: .leading, spacing: p(4)) {
                Text(title).font(.system(size: p(12), weight: .semibold))
                Text(detail)
                    .font(.system(size: p(10)))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                Button(action, action: onOpenSettings)
                    .font(.system(size: p(10), weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.cyan.opacity(0.9))
                    .padding(.top, p(2))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func eventRow(_ event: AgendaEvent) -> some View {
        HStack(spacing: p(9)) {
            RoundedRectangle(cornerRadius: p(2))
                .fill(tint(for: event.kind))
                .frame(width: p(3))
                .padding(.vertical, p(2))
            VStack(alignment: .leading, spacing: p(3)) {
                HStack(spacing: p(6)) {
                    Text(event.title)
                        .font(.system(size: p(12), weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: p(3))
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(AgendaEventTimeLabel.relativeLabel(for: event, now: context.date))
                            .font(.system(size: p(9), weight: .medium))
                            .foregroundStyle(tint(for: event.kind).opacity(0.95))
                            .lineLimit(1)
                    }
                    .fixedSize()
                }
                HStack(spacing: p(5)) {
                    Text(AgendaEventTimeLabel.scheduleLabel(for: event))
                    if let location = event.location, !location.isEmpty {
                        Text("·")
                        Text(location).lineLimit(1)
                    } else if let calendar = model.calendars.first(where: { $0.id == event.calendarID }) {
                        Text("·")
                        Text(calendar.title).lineLimit(1)
                    }
                }
                .font(.system(size: p(9)))
                .foregroundStyle(.white.opacity(0.47))
                .lineLimit(1)
            }
            if let url = event.meetingURL, AgendaEventTimeLabel.isOpenableMeetingURL(url) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: p(11)))
                        .frame(width: p(26), height: p(26))
                        .background(tint(for: .meeting).opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint(for: .meeting))
                .help("加入会议")
                .accessibilityLabel("加入会议：\(event.title)")
            }
        }
        .padding(.horizontal, p(8))
        .padding(.vertical, p(6))
        .frame(height: p(43))
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: p(9)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("island-agenda-event-\(event.id)")
    }

    private func tint(for kind: AgendaEventKind) -> Color {
        switch kind {
        case .event: .cyan
        case .course: .orange
        case .meeting: .mint
        }
    }
}

/// Keeps date boundaries and all-day semantics identical across the agenda layers.
nonisolated enum AgendaEventTimeLabel {
    static func relativeLabel(for event: AgendaEvent, now: Date, calendar: Calendar = .current) -> String {
        if event.isAllDay { return "全天" }
        if event.endDate <= now { return "已结束" }
        if event.startDate <= now { return "进行中" }
        let interval = event.startDate.timeIntervalSince(now)
        if interval < 60 { return "即将开始" }
        if interval < 3600 { return "\(Int(ceil(interval / 60))) 分钟后" }
        if calendar.isDate(event.startDate, inSameDayAs: now) {
            return "\(Int(ceil(interval / 3600))) 小时后"
        }
        return event.startDate.formatted(.dateTime.month().day())
    }

    static func scheduleLabel(for event: AgendaEvent, now: Date = .now, calendar: Calendar = .current) -> String {
        let day = calendar.isDate(event.startDate, inSameDayAs: now)
            ? "今天" : event.startDate.formatted(.dateTime.month().day())
        if event.isAllDay { return day }
        return "\(day) \(event.startDate.formatted(date: .omitted, time: .shortened))"
    }

    static func isOpenableMeetingURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
}

@MainActor
struct CalendarSettingsView: View {
    @ObservedObject var model: CalendarAgendaModel
    @State private var isChangingReminderPermission = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("日历与提醒").font(.largeTitle.weight(.semibold))
                    Text("将日程、课程与会议放进分层主页，在开始前收到提醒。")
                        .foregroundStyle(.secondary)
                }
                connectionSection
                if model.authorization == .authorized {
                    calendarsSection
                    remindersSection
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-calendar-error")
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("settings-calendar")
    }

    private var connectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("日历账户", systemImage: "calendar").font(.headline)
                    Spacer()
                    if model.isLoading { ProgressView().controlSize(.small) }
                }
                HStack(alignment: .top, spacing: 12) {
                    sourceCard(title: "Apple 日历", subtitle: "iCloud 与本机日历", symbol: "calendar", tint: .red)
                    sourceCard(title: "Google 日历", subtitle: "通过 macOS 账户同步", symbol: "globe", tint: .blue)
                }
                Text("在 macOS「互联网账户」中添加 Google 账户并开启日历同步，即可与 Apple 日历一起显示在这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                permissionControls
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceCard(title: String, subtitle: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(.body, weight: .medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var permissionControls: some View {
        switch model.authorization {
        case .notDetermined:
            HStack(spacing: 12) {
                Text("授权后可读取已同步的日历和日程。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("连接日历") { Task { await model.requestAccess() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("settings-calendar-authorize")
            }
        case .authorized:
            HStack {
                Label("已授权日历访问", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                Spacer()
                Button("管理系统账户", action: openInternetAccounts)
                    .accessibilityIdentifier("settings-calendar-accounts")
                Button("刷新") { Task { await model.refresh() } }
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("settings-calendar-refresh")
            }
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 10) {
                Text(model.authorization == .restricted
                     ? "系统限制了日历访问，请检查系统访问限制。"
                     : "日历访问已关闭，请在系统设置中允许 Dynamic Island 访问日历。")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("打开日历隐私设置") {
                        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                    }
                    Button("重新检查") { Task { await model.refresh() } }
                        .disabled(model.isLoading)
                }
            }
        }
        if model.authorization != .authorized {
            Button("管理系统账户", action: openInternetAccounts)
                .accessibilityIdentifier("settings-calendar-accounts")
        }
    }

    private var calendarsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("显示的日历", systemImage: "list.bullet.rectangle").font(.headline)
                Text("勾选需要显示和提醒的日历，再为它选择日程、课程或会议分类。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.calendars.isEmpty {
                    Text("尚未找到日历。添加系统账户并完成同步后，点击刷新。")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.calendars) { calendar in
                        HStack(spacing: 16) {
                            Toggle(isOn: Binding(
                                get: { model.selectedCalendarIDs.contains(calendar.id) },
                                set: { model.setCalendarSelected(calendar.id, isSelected: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(calendar.title).font(.system(.body, weight: .medium))
                                    Text("\(calendar.source.title) · \(calendar.sourceTitle)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("settings-calendar-select-\(calendar.id)")
                            Spacer(minLength: 0)
                            Picker("分类", selection: Binding(
                                get: { model.kind(for: calendar.id) },
                                set: { model.setKind($0, for: calendar.id) }
                            )) {
                                ForEach(AgendaEventKind.allCases) { kind in
                                    Label(kind == .event ? "日程" : kind.title, systemImage: kind.systemImage).tag(kind)
                                }
                            }
                            .frame(width: 150)
                            .accessibilityLabel("\(calendar.title)的分类")
                            .accessibilityIdentifier("settings-calendar-kind-\(calendar.id)")
                            .islandPagingExcluded()
                        }
                        if calendar.id != model.calendars.last?.id { Divider() }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var remindersSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: Binding(get: { model.remindersEnabled }, set: changeReminders)) {
                    Label("日程提醒", systemImage: "bell.badge").font(.headline)
                }
                .toggleStyle(.switch)
                .disabled(isChangingReminderPermission)
                .accessibilityIdentifier("settings-calendar-reminders")
                .islandPagingExcluded()
                Text("使用系统通知提醒所选日历中的日程、课程和会议。首次开启时会请求通知权限。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("提醒时间", selection: $model.reminderMinutes) {
                    Text("开始时").tag(0)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text("提前 \(minutes) 分钟").tag(minutes)
                    }
                }
                .frame(maxWidth: 300)
                .disabled(!model.remindersEnabled)
                .accessibilityIdentifier("settings-calendar-reminder-lead")
                .islandPagingExcluded()
                Text("全天日程只在主页展示，不发送提醒。关闭提醒会取消已安排的日历通知。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("系统通知设置") {
                    openSystemSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                }
                .font(.callout)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func changeReminders(_ enabled: Bool) {
        isChangingReminderPermission = true
        Task {
            await model.setRemindersEnabled(enabled)
            isChangingReminderPermission = false
        }
    }

    private func openInternetAccounts() {
        openSystemSettings("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
    }

    private func openSystemSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
