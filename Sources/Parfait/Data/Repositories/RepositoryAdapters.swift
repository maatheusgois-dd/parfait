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

    func meetingForCalendarEvent(_ eventID: String, in meetings: [Meeting]) -> Meeting? {
        meetings
            .filter { $0.calendarEventID == eventID }
            .max(by: { $0.createdAt < $1.createdAt })
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
