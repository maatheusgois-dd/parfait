import Foundation

// MARK: - Meeting

/// Persistence boundary for meetings and their on-disk artifacts.
/// Single-responsibility: meeting CRUD + transcript/summary I/O (DIP).
@MainActor
protocol MeetingRepository: AnyObject {
    var meetings: [Meeting] { get }
    var archive: MeetingArchive { get }

    func reload()
    func meeting(id: UUID) -> Meeting?
    @discardableResult func upsert(_ meeting: Meeting) -> Meeting
    func delete(id: UUID)

    func transcript(for id: UUID) -> [TranscriptSegment]
    func saveTranscript(_ segments: [TranscriptSegment], for id: UUID)
    func summary(for id: UUID) -> String
    func saveSummary(_ markdown: String, for id: UUID)
    func sideNotes(for id: UUID) -> String
    func saveSideNotes(_ text: String, for id: UUID)
    func renameSpeaker(meetingID: UUID, speakerID: String, to newName: String)
}

// MARK: - Folder

@MainActor
protocol FolderRepository: AnyObject {
    var folders: [MeetingFolder] { get }
    var titleRules: [FolderTitleRule] { get }

    func reload()
    @discardableResult func createFolder(
        name: String,
        description: String?,
        iconKind: FolderIconKind,
        iconValue: String,
        iconColorHex: String
    ) -> MeetingFolder
    func updateFolder(_ folder: MeetingFolder)
    func deleteFolder(id: UUID, meetingRepository: MeetingRepository)
    func assign(meetingID: UUID, to folderID: UUID?, meetingRepository: MeetingRepository)
    func assign(calendarTitle: String, to folderID: UUID, meetingRepository: MeetingRepository)
    func folder(forTitle title: String) -> MeetingFolder?
    func folder(id: UUID) -> MeetingFolder?
}

// MARK: - Calendar

@MainActor
protocol CalendarRepository: AnyObject {
    var agenda: [CalendarAgendaDay] { get }
    var isLoading: Bool { get }
    var lastRefresh: Date? { get }
    var fetchHorizonDays: Int { get }
    var nextUpcomingEvent: CalendarEventSummary? { get }

    func refreshAgenda(now: Date, horizonDays: Int?) async
    func currentEvent(at now: Date, sourceApp: String?) async -> CalendarEventSummary?
    func countdownText(for event: CalendarEventSummary) -> String?
    func meetingForCalendarEvent(_ event: CalendarEventSummary, in meetings: [Meeting]) -> Meeting?
}

// MARK: - Template

@MainActor
protocol TemplateRepository: AnyObject {
    func template(named: String) -> SummaryTemplate?
    var allTemplates: [SummaryTemplate] { get }
}

// MARK: - Template overrides (per calendar event)

/// Read-only view of per-event template assignments used by the recording
/// use cases. The UI writes through `TemplateOverrideStore` (a subclass-free
/// concrete type); use cases only need to look up an override for a calendar
/// event ID, and prune stale ones when the template list changes.
@MainActor
protocol TemplateOverrideRepository: AnyObject {
    /// Returns the template name assigned to `eventID`, or nil. `available`
    /// is the current list of template names; an override whose template no
    /// longer exists returns nil (and the store prunes it lazily).
    func templateName(forEventID eventID: String, available: [String]) -> String?
    func clear(eventID: String)
    func pruneUnavailable(available: [String])
}

// MARK: - Settings

/// Abstracts user preferences so use cases stay free of UserDefaults (DIP + testability).
protocol SettingsRepository: Sendable {
    var autoRecord: Bool { get }
    var detectMeetings: Bool { get }
    var identifySpeakers: Bool { get }
    var useCalendar: Bool { get }
    var autoStopRecording: Bool { get }
    var defaultTemplate: String { get }
    var preferredAIProvider: AIProvider { get }
    var preferClaudeSummaries: Bool { get }
    var showLiveRecordingCard: Bool { get }
    /// When true, the meeting template is auto-selected from the detected
    /// meeting type instead of always using `defaultTemplate`.
    var smartTemplatesEnabled: Bool { get }
}
