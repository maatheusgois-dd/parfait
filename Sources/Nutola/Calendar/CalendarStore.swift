import AppKit
import Combine
import EventKit
import Foundation

@MainActor
final class CalendarStore: ObservableObject {
    static let defaultFetchHorizonDays = 30

    @Published private(set) var agenda: [CalendarAgendaDay] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var fetchHorizonDays = defaultFetchHorizonDays

    private let eventStore = EKEventStore()
    private var observers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var ticker: Timer?

    static var isAuthorized: Bool { CalendarAuthorization.isAuthorized }
    static var isDenied: Bool { CalendarAuthorization.isDenied }
    static func requestAccess() async -> Bool { await CalendarAuthorization.requestAccess() }

    init() {
        startObserving()
        startTicker()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        ticker?.invalidate()
    }

    func refreshAgenda(
        now: Date = .now,
        horizonDays: Int? = nil
    ) async {
        guard AppSettings.useCalendar, CalendarAuthorization.isAuthorized else {
            NutolaConsoleLog.calendar("refresh skipped — disabled or unauthorized")
            agenda = []
            fetchHorizonDays = Self.defaultFetchHorizonDays
            lastRefresh = now
            return
        }
        let targetHorizon = max(horizonDays ?? fetchHorizonDays, Self.defaultFetchHorizonDays)
        isLoading = true
        defer { isLoading = false }

        let enabledCalendars = CalendarSources.enabledEKCalendars()
        let events = await Task.detached { [eventStore, enabledCalendars] in
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: targetHorizon, to: start)
            else { return [EKEvent]() }
            if enabledCalendars?.isEmpty == true { return [EKEvent]() }
            let predicate = eventStore.predicateForEvents(
                withStart: start,
                end: end,
                calendars: enabledCalendars)
            return eventStore.events(matching: predicate)
        }.value

        agenda = CalendarAgendaBuilder.buildAgenda(
            from: events,
            now: now,
            offsetDays: 0,
            horizonDays: targetHorizon)
        fetchHorizonDays = targetHorizon
        lastRefresh = now
        let eventCount = agenda.reduce(0) { $0 + $1.events.count }
        NutolaConsoleLog.calendar("refreshed \(eventCount) events across \(agenda.count) days (horizon=\(targetHorizon)d)")
    }

    func currentEvent(at now: Date = .now, sourceApp: String? = nil) async -> CalendarEventSummary? {
        guard CalendarAuthorization.isAuthorized else { return nil }
        let enabledCalendars = CalendarSources.enabledEKCalendars()
        return await Task.detached { [eventStore, enabledCalendars] in
            if enabledCalendars?.isEmpty == true { return nil }
            let predicate = eventStore.predicateForEvents(
                withStart: now.addingTimeInterval(-4 * 3600),
                end: now.addingTimeInterval(60),
                calendars: enabledCalendars)
            let events = eventStore.events(matching: predicate)
            guard let selected = CalendarEventSelector.select(from: events, at: now, sourceApp: sourceApp)
            else { return nil }
            guard let mapped = CalendarAgendaBuilder.map(selected) else { return nil }
            NutolaConsoleLog.calendar("current event → \"\(mapped.title)\" source=\(sourceApp ?? "none")")
            return mapped
        }.value
    }

    var nextUpcomingEvent: CalendarEventSummary? {
        CalendarAgendaBuilder.nextUpcoming(in: agenda)
    }

    func upcomingDays(limit: Int = UpcomingMeetings.defaultLimit, now: Date = .now) -> [UpcomingMeetingsDay] {
        UpcomingMeetings.grouped(from: agenda, now: now, limit: limit)
    }

    func timelineDays(
        offsetDays: Int = 0,
        pageDays: Int = UpcomingMeetings.timelinePageDays,
        now: Date = .now
    ) -> [CalendarAgendaDay] {
        UpcomingMeetings.timelineDays(
            from: agenda,
            offsetDays: offsetDays,
            pageDays: pageDays,
            now: now)
    }

    func maxTimelineOffset(pageDays: Int = UpcomingMeetings.timelinePageDays, now: Date = .now) -> Int {
        guard let lastDay = agenda.last?.date else { return 0 }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let lastOffset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: lastDay)).day ?? 0
        return max(0, lastOffset - pageDays + 1)
    }

    func ensureHorizon(forOffsetDays offsetDays: Int, pageDays: Int = UpcomingMeetings.timelinePageDays) async {
        let needed = offsetDays + pageDays
        guard needed > fetchHorizonDays else { return }
        await refreshAgenda(horizonDays: needed + 14)
    }

    func startsInText(for event: CalendarEventSummary, now: Date = .now) -> String? {
        if event.isInProgress { return nil }
        return RelativeTimeFormatter.startsIn(event.start, now: now)
    }

    func endsInText(for event: CalendarEventSummary, now: Date = .now) -> String? {
        guard event.isInProgress else { return nil }
        return RelativeTimeFormatter.endsIn(event.end, now: now)
    }

    func countdownText(for event: CalendarEventSummary, now: Date = .now) -> String? {
        if event.isInProgress {
            return RelativeTimeFormatter.left(until: event.end, now: now)
        }
        return RelativeTimeFormatter.until(event.start, now: now)
    }

    func event(id: String, start: Date? = nil) -> CalendarEventSummary? {
        let matches = agenda.flatMap(\.events).filter { $0.id == id }
        if let start {
            return matches.first { abs($0.start.timeIntervalSince(start)) < 60 }
        }
        return matches.first { !$0.isPast() } ?? matches.first
    }

    private func startObserving() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAgenda() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAgenda() }
        })
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refreshAgenda()
        }
    }

    /// Recompute countdown labels every minute without re-querying EventKit.
    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.objectWillChange.send()
            }
        }
    }
}
