import Foundation

extension MeetingStore: MeetingRepository {}

extension MeetingFolderStore: FolderRepository {}

extension CalendarStore: CalendarRepository {
    func countdownText(for event: CalendarEventSummary) -> String? {
        if event.isInProgress {
            return RelativeTimeFormatter.left(until: event.end, now: .now)
        }
        return RelativeTimeFormatter.until(event.start, now: .now)
    }

    func meetingForCalendarEvent(_ event: CalendarEventSummary, in meetings: [Meeting]) -> Meeting? {
        meetings
            .filter { Self.matchesCalendarInstance($0, event: event) }
            .max { a, b in
                if a.duration != b.duration { return a.duration < b.duration }
                return a.createdAt > b.createdAt
            }
    }

    private static func matchesCalendarInstance(_ meeting: Meeting, event: CalendarEventSummary) -> Bool {
        guard meeting.calendarEventID == event.id else { return false }
        if let start = meeting.calendarEventStart { return start == event.start }
        guard let end = meeting.calendarEventEnd else { return false }
        return meeting.createdAt >= event.start.addingTimeInterval(-3600) && meeting.createdAt < end
    }
}

@MainActor
final class TemplateRepositoryImpl: TemplateRepository {
    let store: TemplateStore

    init(store: TemplateStore) {
        self.store = store
    }

    func template(named: String) -> SummaryTemplate? {
        store.template(named: named)
    }

    var allTemplates: [SummaryTemplate] {
        store.list()
    }
}

struct UserDefaultsSettingsRepository: SettingsRepository {
    var autoRecord: Bool { AppSettings.autoRecord }
    var detectMeetings: Bool { AppSettings.detectMeetings }
    var identifySpeakers: Bool { AppSettings.identifySpeakers }
    var useCalendar: Bool { AppSettings.useCalendar }
    var autoStopRecording: Bool { AppSettings.autoStopRecording }
    var defaultTemplate: String { AppSettings.defaultTemplate }
    var preferredAIProvider: AIProvider { AppSettings.preferredAIProvider }
    var preferClaudeSummaries: Bool { AppSettings.preferClaudeSummaries }
    var showLiveRecordingCard: Bool { AppSettings.showLiveRecordingCard }
}
