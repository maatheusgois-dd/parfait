import Combine
import Foundation
import SwiftUI

/// MVVM view model for the Coming Up calendar agenda screen.
@MainActor
final class ComingUpViewModel: ObservableObject {
    @Published private(set) var agenda: [CalendarAgendaDay] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let calendarRepository: CalendarRepository
    private let meetingRepository: MeetingRepository
    private let openCalendarEvent: OpenCalendarEventUseCase
    private let startRecording: StartRecordingUseCase
    var onOpenMeeting: ((UUID) -> Void)?

    init(container: DependencyContainer) {
        self.calendarRepository = container.calendarRepository
        self.meetingRepository = container.meetingRepository
        self.openCalendarEvent = container.openCalendarEvent
        self.startRecording = container.startRecording
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await calendarRepository.refreshAgenda(now: .now, horizonDays: nil)
        agenda = calendarRepository.agenda
    }

    func meetingForEvent(_ event: CalendarEventSummary) -> Meeting? {
        calendarRepository.meetingForCalendarEvent(event, in: meetingRepository.meetings)
    }

    func openEvent(_ event: CalendarEventSummary) async {
        switch await openCalendarEvent.execute(event) {
        case .openExisting(let id), .prepared(let id):
            onOpenMeeting?(id)
        case .failed:
            lastError = "Could not open meeting."
        }
    }

    func recordEvent(_ event: CalendarEventSummary) async {
        lastError = nil
        switch await startRecording.execute(sourceApp: nil, calendarEvent: event) {
        case .success:
            break
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }
}
