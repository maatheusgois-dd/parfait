import AppKit
import AVFoundation
import Combine
import Foundation
import os
import SwiftUI
import UserNotifications

@MainActor
final class AppState: NSObject, ObservableObject {
    static let shared: AppState = {
        MainActor.assumeIsolated {
            AppState(container: DependencyContainer.live())
        }
    }()

    private let container: DependencyContainer

    var store: MeetingStore { container.meetingStore }
    var templates: TemplateStore { container.templateStore }
    var calendar: CalendarStore { container.calendarStore }
    var folders: MeetingFolderStore { container.folderStore }

    @Published private(set) var session: RecordingSession?
    @Published private(set) var recordingMeeting: Meeting?
    @Published var recordingCardDismissed = false
    @Published var recordingCardMinimized = true
    @Published var showLiveRecordingCard: Bool
    @Published private(set) var processingStage: [UUID: String] = [:]
    @Published private(set) var streamingSummaries: [UUID: String] = [:]
    @Published private(set) var summaryProgress: [UUID: SummaryProgress] = [:]
    @Published private(set) var detectedAppName: String?
    @Published var lastError: String?
    @Published var openMeetingID: UUID?
    @Published private(set) var activeMicApps: [pid_t: String] = [:]
    @Published private(set) var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    var activeMicAppNames: [String] { Array(Set(activeMicApps.values)).sorted() }

    private var cancellables = Set<AnyCancellable>()

    func meetingForCalendarEvent(_ eventID: String) -> Meeting? {
        container.calendarRepository.meetingForCalendarEvent(eventID, in: store.meetings)
    }

    var isRecording: Bool { session != nil }

    private init(container: DependencyContainer) {
        self.container = container
        showLiveRecordingCard = container.settings.showLiveRecordingCard
        super.init()
        wireUseCaseCallbacks()
        wireDetectionCoordinator()
        wireStoreForwarding()
    }

    private func wireStoreForwarding() {
        AppSettings.registerDefaults()
        showLiveRecordingCard = container.settings.showLiveRecordingCard
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        calendar.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        folders.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func wireUseCaseCallbacks() {
        container.processMeeting.onProgress = { [weak self] id, stage in
            if let stage { self?.processingStage[id] = stage }
            else { self?.processingStage[id] = nil }
        }
        container.processMeeting.onSummaryProgress = { [weak self] id, progress in
            self?.summaryProgress[id] = progress
        }
        container.processMeeting.onSummaryUpdate = { [weak self] id, update in
            self?.applySummaryUpdate(update, for: id)
        }
        container.regenerateSummary.onProgress = { [weak self] id, stage in
            if let stage { self?.processingStage[id] = stage }
            else { self?.processingStage[id] = nil }
        }
        container.regenerateSummary.onStreamingSummary = { [weak self] id, text in
            if let text { self?.streamingSummaries[id] = text }
            else { self?.streamingSummaries[id] = nil }
        }
        container.regenerateSummary.onSummaryProgress = { [weak self] id, progress in
            self?.summaryProgress[id] = progress
        }
    }

    private func wireDetectionCoordinator() {
        let coordinator = container.detectionCoordinator
        coordinator.isRecording = { [weak self] in self?.isRecording ?? false }
        coordinator.isStartingRecording = { [weak self] in
            self?.container.recordingService.isStartingRecording ?? false
        }
        coordinator.onDetectedAppNameChanged = { [weak self] name in
            self?.detectedAppName = name
        }
        coordinator.onActiveMicAppsChanged = { [weak self] apps in
            self?.activeMicApps = apps
        }
        coordinator.onDetectionChime = { [weak self] in
            self?.container.notificationService.playDetectionChime()
        }
    }

    func bootstrap() {
        container.notificationService.configure { [weak self] id in
            Task { @MainActor in
                self?.openMeetingID = id
            }
        }
        finalizeOrphans()
        Task.detached {
            _ = ClaudeCLI.resolveBlocking()
            _ = CodexCLI.resolveBlocking()
        }
        Task { @MainActor in
            await Task.detached { SystemAudioTap.destroyLeftoverAggregates() }.value
            if container.settings.detectMeetings { startDetection() }
            await calendar.refreshAgenda()
            notificationAuthStatus = await container.notificationService.refreshAuthorizationStatus()
        }
    }

    func prepareForTermination() {
        container.recordingService.prepareForTermination(meetingRepository: store)
        session = nil
        recordingMeeting = nil
    }

    // MARK: - Detection

    func startDetection() {
        container.detectionCoordinator.start()
    }

    func stopDetection() {
        container.detectionCoordinator.stop()
    }

    func acceptDetection() async {
        lastError = nil
        resetRecordingCardState()
        switch await container.startRecording.execute(
            sourceApp: detectedAppName,
            calendarEvent: nil) {
        case .success(let handle):
            applyRecordingHandle(handle)
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    func dismissDetection() {
        container.detectionCoordinator.dismissDetection()
    }

    // MARK: - Recording

    func startRecording(
        sourceApp: String? = nil,
        trigger: MicEvent? = nil,
        calendarEvent: CalendarEventSummary? = nil
    ) async {
        lastError = nil
        resetRecordingCardState()
        container.detectionCoordinator.dismissDetection()
        switch await container.startRecording.execute(
            sourceApp: sourceApp,
            calendarEvent: calendarEvent) {
        case .success(let handle):
            applyRecordingHandle(handle)
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    func stopRecording() async {
        session = nil
        recordingMeeting = nil
        _ = await container.stopRecording.execute()
    }

    func discardRecording() {
        session = nil
        recordingMeeting = nil
        container.discardRecording.execute()
    }

    func openCalendarEvent(_ event: CalendarEventSummary) {
        Task {
            switch await container.openCalendarEvent.execute(event) {
            case .openExisting(let id), .prepared(let id):
                openMeetingID = id
            case .failed:
                lastError = "Could not prepare meeting."
            }
        }
    }

    func prepareMeeting(calendarEvent: CalendarEventSummary) async {
        switch container.prepareMeeting.execute(calendarEvent: calendarEvent) {
        case .success(let meeting):
            openMeetingID = meeting.id
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    func continueRecording(meetingID: UUID) async {
        lastError = nil
        resetRecordingCardState()
        container.detectionCoordinator.dismissDetection()
        switch await container.continueRecording.execute(meetingID: meetingID) {
        case .success(let handle):
            applyRecordingHandle(handle)
            openMeetingID = handle.meeting.id
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    private func applyRecordingHandle(_ handle: RecordingSessionHandle) {
        session = handle.session
        recordingMeeting = handle.meeting
    }

    private func resetRecordingCardState() {
        recordingCardDismissed = false
        recordingCardMinimized = true
    }

    // MARK: - Processing

    func process(_ meeting: Meeting) async {
        await container.processMeeting.execute(meeting)
        streamingSummaries[meeting.id] = nil
    }

    func retry(meetingID: UUID) async {
        await container.retryMeeting.execute(meetingID: meetingID)
    }

    func regenerateSummary(meetingID: UUID, templateName: String? = nil) async {
        await container.regenerateSummary.execute(meetingID: meetingID, templateName: templateName)
    }

    private func applySummaryUpdate(_ update: ProcessingPipeline.SummaryUpdate, for id: UUID) {
        switch update {
        case .streaming(let text):
            summaryProgress[id] = .streaming
            streamingSummaries[id] = text
        case .draftSaved:
            summaryProgress[id] = .improving
            streamingSummaries[id] = nil
        case .done:
            summaryProgress[id] = nil
            streamingSummaries[id] = nil
        }
    }

    private func finalizeOrphans() {
        for meeting in store.meetings where meeting.state == .recording || meeting.state == .processing {
            var m = meeting
            if m.duration == 0 {
                m.duration = audioDuration(archive: store.archive, id: m.id)
                store.upsert(m)
            }
            Task { await process(m) }
        }
    }

    private nonisolated func audioDuration(archive: MeetingArchive, id: UUID) -> TimeInterval {
        for url in [archive.micURL(for: id), archive.systemURL(for: id)] {
            if let seconds = try? AVAudioFileLength(url), seconds > 0 { return seconds }
        }
        return 0
    }

    // MARK: - Notifications

    func refreshNotificationStatus() async {
        notificationAuthStatus = await container.notificationService.refreshAuthorizationStatus()
    }

    func requestNotificationAuthorization() async {
        await container.notificationService.requestAuthorization()
        await refreshNotificationStatus()
    }
}

private func AVAudioFileLength(_ url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}