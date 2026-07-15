import Combine
import Foundation
import SwiftUI

/// MVVM view model for a single meeting detail screen.
@MainActor
final class MeetingDetailViewModel: ObservableObject {
    @Published private(set) var meeting: Meeting
    @Published private(set) var processingStage: String?
    @Published private(set) var streamingSummary: String?
    @Published private(set) var summaryProgress: SummaryProgress?
    @Published var lastError: String?

    private let meetingRepository: MeetingRepository
    private let regenerateSummary: RegenerateSummaryUseCase
    private let retryMeeting: RetryMeetingUseCase
    private let continueRecording: ContinueRecordingUseCase
    private var cancellables = Set<AnyCancellable>()

    init(meeting: Meeting, container: DependencyContainer, appState: AppState) {
        self.meeting = meeting
        self.meetingRepository = container.meetingRepository
        self.regenerateSummary = container.regenerateSummary
        self.retryMeeting = container.retryMeeting
        self.continueRecording = container.continueRecording

        appState.$processingStage
            .map { $0[meeting.id] }
            .receive(on: DispatchQueue.main)
            .assign(to: &$processingStage)

        appState.$streamingSummaries
            .map { $0[meeting.id] }
            .receive(on: DispatchQueue.main)
            .assign(to: &$streamingSummary)

        appState.$summaryProgress
            .map { $0[meeting.id] }
            .receive(on: DispatchQueue.main)
            .assign(to: &$summaryProgress)

        appState.store.objectWillChange
            .sink { [weak self] _ in self?.refreshMeeting() }
            .store(in: &cancellables)
    }

    func refreshMeeting() {
        if let fresh = meetingRepository.meeting(id: meeting.id) {
            meeting = fresh
        }
    }

    var transcript: [TranscriptSegment] {
        meetingRepository.transcript(for: meeting.id)
    }

    var summary: String {
        meetingRepository.summary(for: meeting.id)
    }

    var sideNotes: String {
        meetingRepository.sideNotes(for: meeting.id)
    }

    func saveSideNotes(_ text: String) {
        meetingRepository.saveSideNotes(text, for: meeting.id)
    }

    func saveSummary(_ markdown: String) {
        meetingRepository.saveSummary(markdown, for: meeting.id)
    }

    func saveTranscript(_ segments: [TranscriptSegment]) {
        meetingRepository.saveTranscript(segments, for: meeting.id)
    }

    func updateMeeting(_ updated: Meeting) {
        meeting = meetingRepository.upsert(updated)
    }

    func renameSpeaker(speakerID: String, to name: String) {
        meetingRepository.renameSpeaker(meetingID: meeting.id, speakerID: speakerID, to: name)
        refreshMeeting()
    }

    func retry() async {
        await retryMeeting.execute(meetingID: meeting.id)
        refreshMeeting()
    }

    func regenerateSummary(templateName: String? = nil, forceProvider: AIProvider? = nil) async {
        await regenerateSummary.execute(
            meetingID: meeting.id, templateName: templateName, forceProvider: forceProvider)
        refreshMeeting()
    }

    func continueRecording() async {
        switch await continueRecording.execute(meetingID: meeting.id) {
        case .success:
            refreshMeeting()
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }
}
