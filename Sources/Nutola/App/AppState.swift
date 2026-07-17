import AppKit
import AVFoundation
import Combine
import Foundation
import os
import SwiftUI
import UserNotifications

extension Notification.Name {
    /// Posted after bootstrap warms Claude/Codex auth caches off the main thread.
    static let nutolaCLIAvailabilityChanged = Notification.Name("NutolaCLIAvailabilityChanged")
}

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
    /// Signal-safe mirror of the in-flight meeting metadata, kept in sync with
    /// `recordingMeeting` so `CrashDiagnosticLog` can read it from a signal handler
    /// without touching the @MainActor. Only id/title/state/notice — never audio.
    nonisolated(unsafe) private var inFlightCrashMirror: CrashDiagnosticLog.InFlightMeeting?
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

    func meetingForCalendarEvent(_ event: CalendarEventSummary) -> Meeting? {
        container.calendarRepository.meetingForCalendarEvent(event, in: store.meetings)
    }

    var isRecording: Bool { session != nil || container.recordingService.isRecording }

    /// A meeting left in a resumable state (failed/ready/prep) when no session is
    /// active — e.g. a crash-orphaned recording the user is about to rejoin. The
    /// menu bar uses this to swap "Start recording" for "Resume recording".
    var resumableMeeting: Meeting? {
        guard session == nil, !container.recordingService.isRecording else { return nil }
        return store.meetings.first { $0.canResumeRecording(isRecording: false) }
    }

    /// Resume the most recent resumable meeting, if any. Used by the menu bar's
    /// "Resume recording" button when no session is live.
    func resumeOrphanIfAny() async {
        guard let meeting = resumableMeeting else { return }
        await continueRecording(meetingID: meeting.id)
    }

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
        coordinator.onAutoRecord = { [weak self] name in
            await self?.startRecording(sourceApp: name)
        }
        coordinator.onAutoStop = { [weak self] in
            await self?.stopRecording()
        }
    }

    /// Heals a stale UI when capture is live in `RecordingService` but `session` was never set.
    func reconcileRecordingState() {
        guard session == nil,
              let svcSession = container.recordingService.currentSession,
              let meeting = container.recordingService.recordingMeeting else { return }
        applyRecordingHandle(RecordingSessionHandle(session: svcSession, meeting: meeting))
        lastError = nil
    }

    func bootstrap() {
        NutolaConsoleLog.app("bootstrap starting")
        // Hand the crash logger a signal-safe reader for the in-flight meeting.
        CrashDiagnosticLog.inFlightMeetingSnapshot = { [weak self] in
            // Plain struct read — safe from a signal handler. The mirror is
            // updated on the main thread whenever recording starts/stops.
            return self?.inFlightCrashMirror
        }
        container.notificationService.configure { [weak self] id in
            Task { @MainActor in
                self?.openMeetingID = id
            }
        }
        finalizeOrphans()
        Task.detached {
            _ = ClaudeCLI.resolveBlocking()
            _ = CodexCLI.resolveBlocking()
            ClaudeCLI.warmAuthCache()
            CodexCLI.warmAuthCache()
            await MainActor.run {
                NutolaConsoleLog.app("CLI availability refreshed")
                NotificationCenter.default.post(name: .nutolaCLIAvailabilityChanged, object: nil)
            }
        }
        Task { @MainActor in
            await Task.detached { SystemAudioTap.destroyLeftoverAggregates() }.value
            if container.settings.detectMeetings {
                NutolaConsoleLog.app("starting meeting detection")
                startDetection()
            }
            await calendar.refreshAgenda()
            notificationAuthStatus = await container.notificationService.refreshAuthorizationStatus()
            NutolaConsoleLog.app(
                "bootstrap done — meetings=\(store.meetings.count) calendarAuth=\(CalendarAuthorization.isAuthorized)"
                    + " detect=\(container.settings.detectMeetings)")
        }
    }

    private func updateInFlightCrashMirror() {
        guard let meeting = recordingMeeting else { inFlightCrashMirror = nil; return }
        inFlightCrashMirror = CrashDiagnosticLog.InFlightMeeting(
            id: meeting.id.uuidString,
            title: meeting.title,
            state: meeting.state.rawValue,
            notice: meeting.notice)
    }

    func prepareForTermination() {
        container.recordingService.prepareForTermination(meetingRepository: store)
        session = nil
        recordingMeeting = nil
        updateInFlightCrashMirror()
    }

    // MARK: - Detection

    func startDetection() {
        NutolaConsoleLog.detection("AppState.startDetection")
        container.detectionCoordinator.start()
    }

    func stopDetection() {
        NutolaConsoleLog.detection("AppState.stopDetection")
        container.detectionCoordinator.stop()
    }

    func acceptDetection() async {
        lastError = nil
        resetRecordingCardState()
        let appName = detectedAppName
        container.detectionCoordinator.dismissDetection()
        switch await container.startRecording.execute(
            sourceApp: appName,
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
        let resolvedSource = sourceApp ?? inferredMeetingSource()
        container.detectionCoordinator.dismissDetection()
        switch await container.startRecording.execute(
            sourceApp: resolvedSource,
            calendarEvent: calendarEvent) {
        case .success(let handle):
            applyRecordingHandle(handle)
        case .failure(let error):
            if error == .alreadyRecording {
                reconcileRecordingState()
                if session != nil { return }
            }
            lastError = error.localizedDescription
            NutolaConsoleLog.recording("start failed — \(error.localizedDescription)")
        }
    }

    /// Manual starts still tag Zoom/Teams when that app is on the mic.
    private func inferredMeetingSource() -> String? {
        guard !activeMicAppNames.isEmpty else { return nil }
        let inferred = MeetingDetector.inferSourceApp(from: activeMicAppNames)
        if let inferred {
            NutolaConsoleLog.recording(
                "inferred source=\(inferred) from active mic [\(activeMicAppNames.joined(separator: ", "))]")
        }
        return inferred
    }

    func stopRecording() async {
        NutolaConsoleLog.recording("AppState.stopRecording")
        session = nil
        recordingMeeting = nil
        updateInFlightCrashMirror()
        _ = await container.stopRecording.execute()
    }

    func discardRecording() {
        NutolaConsoleLog.recording("AppState.discardRecording")
        session = nil
        recordingMeeting = nil
        updateInFlightCrashMirror()
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
        updateInFlightCrashMirror()
        openMeetingID = handle.meeting.id
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

    func regenerateSummary(meetingID: UUID, templateName: String? = nil, forceProvider: AIProvider? = nil) async {
        await container.regenerateSummary.execute(
            meetingID: meetingID, templateName: templateName, forceProvider: forceProvider)
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
        let orphans = store.meetings.filter { $0.state == .recording || $0.state == .processing }
        if !orphans.isEmpty {
            NutolaConsoleLog.processing("finalizing \(orphans.count) orphan meeting(s)")
        }
        for meeting in orphans {
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