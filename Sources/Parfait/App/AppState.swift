import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppState: NSObject, ObservableObject {
    static let shared = AppState()

    let store = MeetingStore()
    let templates = TemplateStore()

    @Published private(set) var session: RecordingSession?
    @Published private(set) var recordingMeeting: Meeting?
    /// meeting id → human-readable pipeline stage, while processing.
    @Published private(set) var processingStage: [UUID: String] = [:]
    /// A meeting-ish app started using the mic and we're waiting on the user.
    @Published private(set) var detectedAppName: String?
    @Published var lastError: String?
    /// Set by the menu bar to steer the main window's selection.
    @Published var openMeetingID: UUID?

    private let detector = MeetingDetector()
    private var triggerPID: pid_t?
    private var autoStarted = false
    private var pendingAutoStop: Task<Void, Never>?

    var isRecording: Bool { session != nil }

    private override init() {
        super.init()
        AppSettings.registerDefaults()
    }

    func bootstrap() {
        configureNotifications()
        if AppSettings.detectMeetings { startDetection() }
        finalizeOrphans()
    }

    // MARK: - Detection

    func startDetection() {
        detector.start { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func stopDetection() {
        detector.stop()
        detectedAppName = nil
    }

    private func handle(_ event: MicEvent) {
        guard !MeetingDetector.isIgnored(bundleID: event.bundleID) else { return }
        let name = MeetingDetector.displayName(for: event)

        if event.isRunningInput {
            pendingAutoStop?.cancel()
            pendingAutoStop = nil
            guard !isRecording else { return }
            if AppSettings.autoRecord {
                triggerPID = event.pid
                autoStarted = true
                Task { await startRecording(sourceApp: name) }
            } else {
                detectedAppName = name
                triggerPID = event.pid
                notifyMeetingDetected(app: name)
            }
        } else {
            if event.pid == triggerPID, !isRecording {
                detectedAppName = nil
                triggerPID = nil
            }
            // Auto-started recordings end shortly after the meeting app lets go
            // of the mic (debounced — apps drop and re-grab during reconnects).
            if event.pid == triggerPID, isRecording, autoStarted {
                pendingAutoStop?.cancel()
                pendingAutoStop = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    await self?.stopRecording()
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording(sourceApp: String? = nil) async {
        guard !isRecording else { return }
        detectedAppName = nil
        lastError = nil

        if !MicRecorder.permissionGranted {
            _ = await MicRecorder.requestPermission()
        }

        var meeting = Meeting(title: Meeting.placeholderTitle(for: Date()), createdAt: Date())
        meeting.sourceApp = sourceApp
        meeting.templateName = AppSettings.defaultTemplate

        if AppSettings.useCalendar, CalendarMatcher.isAuthorized,
           let event = await CalendarMatcher.currentEvent() {
            meeting.title = event.title
            meeting.calendarEventTitle = event.title
            meeting.attendees = event.attendees
        }

        let archive = store.archive
        try? FileManager.default.createDirectory(
            at: archive.folder(for: meeting.id), withIntermediateDirectories: true)

        let newSession = RecordingSession(meetingID: meeting.id)
        do {
            try newSession.start(
                micURL: archive.micURL(for: meeting.id),
                systemURL: archive.systemURL(for: meeting.id))
        } catch {
            lastError = error.localizedDescription
            try? FileManager.default.removeItem(at: archive.folder(for: meeting.id))
            return
        }
        meeting.notice = newSession.startupNotice
        store.upsert(meeting)
        recordingMeeting = meeting
        session = newSession
    }

    func stopRecording() async {
        guard let session, var meeting = recordingMeeting else { return }
        pendingAutoStop?.cancel()
        pendingAutoStop = nil
        session.stop()
        meeting.duration = session.elapsed
        self.session = nil
        recordingMeeting = nil
        autoStarted = false
        triggerPID = nil
        store.upsert(meeting)
        await process(meeting)
    }

    func discardRecording() {
        guard let session, let meeting = recordingMeeting else { return }
        session.stop()
        self.session = nil
        recordingMeeting = nil
        autoStarted = false
        triggerPID = nil
        store.delete(id: meeting.id)
    }

    func dismissDetection() {
        detectedAppName = nil
        triggerPID = nil
    }

    // MARK: - Processing

    func process(_ meeting: Meeting) async {
        processingStage[meeting.id] = "Starting…"
        var processing = meeting
        processing.state = .processing
        store.upsert(processing)
        let archive = store.archive
        let id = meeting.id
        let result = await ProcessingPipeline.run(meeting: meeting, archive: archive) { stage in
            Task { @MainActor in AppState.shared.processingStage[id] = stage }
        }
        processingStage[id] = nil
        store.upsert(result)
        if result.state == .ready {
            notifyReady(result)
        }
    }

    /// Re-run summary+title only (transcript already exists), e.g. after the user
    /// edited the transcript, switched template, or fixed an AI backend.
    func regenerateSummary(meetingID: UUID, templateName: String? = nil) async {
        guard var meeting = store.meeting(id: meetingID) else { return }
        if let templateName { meeting.templateName = templateName }
        processingStage[meetingID] = "Summarizing…"
        let segments = store.transcript(for: meetingID)
        let text = TranscriptFormatter.plainText(segments, speakers: meeting.speakers)
        let outcome = await ProcessingPipeline.summarize(meeting: meeting, transcript: text)
        switch outcome {
        case .success(let summary, let provider):
            store.saveSummary(summary, for: meetingID)
            meeting.summaryProvider = provider
            meeting.notice = nil
            if meeting.calendarEventTitle == nil,
               let title = await ProcessingPipeline.generateTitle(summary: summary, provider: provider) {
                meeting.title = title
            }
        case .failure(let why):
            meeting.notice = why
        }
        processingStage[meetingID] = nil
        store.upsert(meeting)
    }

    /// Meetings left mid-flight by a crash/quit: anything still marked
    /// recording/processing gets pushed through the pipeline (audio files are
    /// flushed continuously, so whatever was captured is usable).
    private func finalizeOrphans() {
        for meeting in store.meetings where meeting.state == .recording || meeting.state == .processing {
            var m = meeting
            if m.duration == 0 {
                m.duration = audioDuration(archive: store.archive, id: m.id)
            }
            Task { await process(m) }
        }
    }

    private nonisolated func audioDuration(archive: MeetingArchive, id: UUID) -> TimeInterval {
        for url in [archive.micURL(for: id), archive.systemURL(for: id)] {
            if let file = try? AVAudioFileLength(url), file > 0 { return file }
        }
        return 0
    }

    // MARK: - Notifications

    private func configureNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return } // bare `swift run` has no bundle
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let record = UNNotificationAction(
            identifier: "RECORD", title: "Record", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: "MEETING_DETECTED", actions: [record], intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyMeetingDetected(app: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "\(app) started using the microphone. Record it?"
        content.categoryIdentifier = "MEETING_DETECTED"
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "detected-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func notifyReady(_ meeting: Meeting) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = meeting.title
        content.body = "Your meeting notes are ready."
        let request = UNNotificationRequest(
            identifier: "ready-\(meeting.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension AppState: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.actionIdentifier
        await MainActor.run {
            if id == "RECORD" || id == UNNotificationDefaultActionIdentifier {
                let app = AppState.shared.detectedAppName
                Task { await AppState.shared.startRecording(sourceApp: app) }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

private func AVAudioFileLength(_ url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}
