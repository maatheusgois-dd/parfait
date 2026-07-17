import XCTest
@testable import Nutola

@MainActor
final class UseCaseTests: XCTestCase {
    // MARK: - Prepare

    func testPrepareMeetingCreatesPrepStateMeeting() {
        let meetings = MockMeetingRepository()
        let folders = MeetingFolderStore()
        let settings = MockSettingsRepository()
        let useCase = PrepareMeetingUseCase(
            meetingRepository: meetings,
            folderRepository: folders,
            settings: settings)

        let result = useCase.execute(calendarEvent: ArchitectureFixtures.sampleCalendarEvent())
        guard case .success(let meeting) = result else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(meeting.state, .prep)
        XCTAssertEqual(meeting.title, "Weekly Standup")
        XCTAssertEqual(meeting.calendarEventID, "evt-1")
        XCTAssertEqual(meetings.meetings.count, 1)
    }

    func testPrepareMeetingUsesDefaultTemplate() {
        let meetings = MockMeetingRepository()
        var settings = MockSettingsRepository()
        settings.defaultTemplate = "1-on-1"
        let useCase = PrepareMeetingUseCase(
            meetingRepository: meetings,
            folderRepository: MeetingFolderStore(),
            settings: settings)

        guard case .success(let meeting) = useCase.execute(
            calendarEvent: ArchitectureFixtures.sampleCalendarEvent()) else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(meeting.templateName, "1-on-1")
    }

    // MARK: - Open calendar event

    func testOpenCalendarEventReturnsExistingMeeting() async {
        let meetings = MockMeetingRepository()
        let event = ArchitectureFixtures.sampleCalendarEvent()
        var existing = Meeting(title: "Prior", createdAt: Date())
        existing.calendarEventID = event.id
        existing.calendarEventStart = event.start
        try? meetings.archive.createFolder(for: existing.id)
        meetings.upsert(existing)

        let calendar = MockCalendarRepository()
        let prepare = PrepareMeetingUseCase(
            meetingRepository: meetings,
            folderRepository: MeetingFolderStore(),
            settings: MockSettingsRepository())
        let useCase = OpenCalendarEventUseCase(
            meetingRepository: meetings,
            calendarRepository: calendar,
            prepareMeeting: prepare)

        let outcome = await useCase.execute(event)
        XCTAssertEqual(outcome, .openExisting(existing.id))
    }

    func testOpenCalendarEventPreparesWhenMissing() async {
        let meetings = MockMeetingRepository()
        let calendar = MockCalendarRepository()
        let prepare = PrepareMeetingUseCase(
            meetingRepository: meetings,
            folderRepository: MeetingFolderStore(),
            settings: MockSettingsRepository())
        let useCase = OpenCalendarEventUseCase(
            meetingRepository: meetings,
            calendarRepository: calendar,
            prepareMeeting: prepare)

        let outcome = await useCase.execute(ArchitectureFixtures.sampleCalendarEvent())
        guard case .prepared(let id) = outcome else {
            return XCTFail("Expected prepared")
        }
        XCTAssertEqual(meetings.meeting(id: id)?.state, .prep)
    }

    // MARK: - Process

    func testProcessMeetingUpdatesStateAndNotifies() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Test", createdAt: Date())
        meeting.state = .processing
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let notifications = MockNotificationService()
        var progressStages: [String] = []
        let processing = MockProcessingService()
        processing.outcome = ProcessingPipeline.Outcome(state: .ready)

        let useCase = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: notifications)
        useCase.onProgress = { _, stage in
            if let stage { progressStages.append(stage) }
        }

        await useCase.execute(meeting)

        XCTAssertEqual(meetings.meeting(id: meeting.id)?.state, .ready)
        XCTAssertEqual(notifications.readyMeetings.count, 1)
        XCTAssertFalse(progressStages.isEmpty)
    }

    func testProcessMeetingMergesLiveTranscriptBeforePipeline() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Live", createdAt: Date())
        meeting.state = .processing
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let live = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Hello"),
            TranscriptSegment(speakerID: "s1", start: 1, end: 2, text: "Hi"),
        ]
        meetings.archive.saveLiveTranscript(live, for: meeting.id)

        let useCase = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: MockProcessingService(),
            notificationService: MockNotificationService())

        await useCase.execute(meeting)

        let saved = meetings.transcript(for: meeting.id)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.map(\.text), ["Hello", "Hi"])
        XCTAssertTrue(meetings.archive.liveTranscript(for: meeting.id).isEmpty)
    }

    func testProcessMeetingPreservesUserSpeakerRenames() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Rename", createdAt: Date())
        meeting.state = .processing
        meeting.speakers = [Speaker(id: "s1", name: "Alice")]
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let processing = MockProcessingService()
        processing.outcome = ProcessingPipeline.Outcome(
            state: .ready,
            speakers: [Speaker(id: "s1", name: "Speaker 1")])

        let useCase = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: MockNotificationService())

        await useCase.execute(meeting)

        XCTAssertEqual(meetings.meeting(id: meeting.id)?.speakers.first?.name, "Alice")
    }

    func testProcessMeetingDoesNotNotifyWhenFailed() async {
        let meetings = MockMeetingRepository()
        let meeting = Meeting(title: "Fail", createdAt: Date())
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let notifications = MockNotificationService()
        let processing = MockProcessingService()
        processing.outcome = ProcessingPipeline.Outcome(state: .failed, notice: "No audio")

        let useCase = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: notifications)

        await useCase.execute(meeting)

        XCTAssertEqual(meetings.meeting(id: meeting.id)?.state, .failed)
        XCTAssertTrue(notifications.readyMeetings.isEmpty)
    }

    // MARK: - Regenerate

    func testRegenerateSummarySavesMarkdownAndTitle() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Untitled", createdAt: Date())
        meeting.state = .ready
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)
        meetings.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "We shipped it.")],
            for: meeting.id)

        let processing = MockProcessingService()
        let useCase = RegenerateSummaryUseCase(
            meetingRepository: meetings,
            processingService: processing)

        var streamed: [String?] = []
        useCase.onStreamingSummary = { _, text in streamed.append(text) }

        await useCase.execute(meetingID: meeting.id)

        XCTAssertEqual(meetings.summary(for: meeting.id), "# Notes\n\nTest summary")
        XCTAssertEqual(meetings.meeting(id: meeting.id)?.title, "Test Meeting Title")
        XCTAssertEqual(meetings.meeting(id: meeting.id)?.summaryProvider, "apple")
        XCTAssertTrue(streamed.contains("partial"))
    }

    func testRegenerateSummaryKeepsCalendarTitle() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Standup", createdAt: Date())
        meeting.calendarEventTitle = "Standup"
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)
        meetings.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Done.")],
            for: meeting.id)

        let useCase = RegenerateSummaryUseCase(
            meetingRepository: meetings,
            processingService: MockProcessingService())

        await useCase.execute(meetingID: meeting.id)

        XCTAssertEqual(meetings.meeting(id: meeting.id)?.title, "Standup")
    }

    // MARK: - Retry

    func testRetryFailedMeetingRunsProcess() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Failed", createdAt: Date())
        meeting.state = .failed
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let processing = MockProcessingService()
        let processUC = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: MockNotificationService())
        let regenerate = RegenerateSummaryUseCase(
            meetingRepository: meetings,
            processingService: processing)
        let retry = RetryMeetingUseCase(
            meetingRepository: meetings,
            processMeeting: processUC,
            regenerateSummary: regenerate)

        await retry.execute(meetingID: meeting.id)

        XCTAssertEqual(processing.processCallCount, 1)
        XCTAssertEqual(processing.summarizeCallCount, 0)
        XCTAssertEqual(meetings.meeting(id: meeting.id)?.state, .ready)
    }

    func testRetryReadyMeetingRegeneratesSummary() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Ready", createdAt: Date())
        meeting.state = .ready
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)
        meetings.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Notes.")],
            for: meeting.id)

        let processing = MockProcessingService()
        let processUC = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: MockNotificationService())
        let regenerate = RegenerateSummaryUseCase(
            meetingRepository: meetings,
            processingService: processing)
        let retry = RetryMeetingUseCase(
            meetingRepository: meetings,
            processMeeting: processUC,
            regenerateSummary: regenerate)

        await retry.execute(meetingID: meeting.id)

        XCTAssertEqual(processing.processCallCount, 0)
        XCTAssertEqual(processing.summarizeCallCount, 1)
    }
}
