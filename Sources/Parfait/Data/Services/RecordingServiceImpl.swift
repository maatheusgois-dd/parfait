import AppKit
import AVFoundation
import Foundation
import os
import UserNotifications

@MainActor
final class RecordingServiceImpl: RecordingService {
    private(set) var currentSession: RecordingSession?
    private(set) var recordingMeeting: Meeting?
    private var _isStartingRecording = false
    private let log = Logger(subsystem: "io.github.conrad-vanl.Parfait", category: "recording")

    var isRecording: Bool { currentSession != nil }
    var isStartingRecording: Bool { _isStartingRecording }

    func startRecording(
        sourceApp: String?,
        calendarEvent: CalendarEventSummary?,
        meetingRepository: MeetingRepository,
        folderRepository: FolderRepository,
        calendarRepository: CalendarRepository,
        settings: SettingsRepository
    ) async -> Result<RecordingSessionHandle, RecordingError> {
        guard !isRecording, !isStartingRecording else { return .failure(.alreadyRecording) }
        _isStartingRecording = true
        defer { _isStartingRecording = false }

        if !MicRecorder.permissionGranted {
            _ = await MicRecorder.requestPermission()
        }

        var meeting = Meeting(title: Meeting.placeholderTitle(for: Date()), createdAt: Date())
        meeting.sourceApp = sourceApp
        meeting.templateName = settings.defaultTemplate

        if let calendarEvent {
            applyCalendarEvent(calendarEvent, to: &meeting)
        } else if settings.useCalendar, CalendarAuthorization.isAuthorized,
                  let event = await calendarRepository.currentEvent(at: .now, sourceApp: sourceApp) {
            applyCalendarEvent(event, to: &meeting)
        }

        if let title = meeting.calendarEventTitle,
           let folder = folderRepository.folder(forTitle: title) {
            meeting.folderID = folder.id
        }

        guard !isRecording else { return .failure(.alreadyRecording) }

        return startSession(for: meeting, meetingRepository: meetingRepository)
    }

    func continueRecording(
        meetingID: UUID,
        meetingRepository: MeetingRepository
    ) async -> Result<RecordingSessionHandle, RecordingError> {
        guard !isRecording, !isStartingRecording else { return .failure(.alreadyRecording) }
        guard var meeting = meetingRepository.meeting(id: meetingID) else {
            return .failure(.meetingNotFound)
        }
        let fromPrep = meeting.canStartFromPrep(isRecording: false)
        guard fromPrep || meeting.canContinueRecording(isRecording: false) else {
            return .failure(.cannotContinue)
        }

        _isStartingRecording = true
        defer { _isStartingRecording = false }

        if !MicRecorder.permissionGranted {
            _ = await MicRecorder.requestPermission()
        }
        guard !isRecording else { return .failure(.alreadyRecording) }

        let archive = meetingRepository.archive
        if !fromPrep {
            for url in [archive.micURL(for: meetingID), archive.systemURL(for: meetingID)] {
                try? FileManager.default.removeItem(at: url)
            }
            archive.removeLiveTranscript(for: meetingID)
        }

        meeting.state = .recording
        meeting.notice = nil
        meetingRepository.upsert(meeting)

        let newSession = RecordingSession(
            meetingID: meeting.id, archive: archive, elapsedOffset: meeting.duration)
        do {
            try newSession.start(
                micURL: archive.micURL(for: meeting.id),
                systemURL: archive.systemURL(for: meeting.id))
        } catch {
            meeting.state = .failed
            meeting.notice = error.localizedDescription
            meetingRepository.upsert(meeting)
            return .failure(.sessionStartFailed(error.localizedDescription))
        }
        meeting.notice = newSession.startupNotice
        meetingRepository.upsert(meeting)
        currentSession = newSession
        recordingMeeting = meeting
        return .success(RecordingSessionHandle(session: newSession, meeting: meeting))
    }

    func stop() -> (session: RecordingSession, meeting: Meeting)? {
        guard let session = currentSession, let meeting = recordingMeeting else { return nil }
        clear()
        session.stop()
        return (session, meeting)
    }

    func discard() -> (session: RecordingSession, meeting: Meeting)? {
        guard let session = currentSession, let meeting = recordingMeeting else { return nil }
        clear()
        session.stop()
        return (session, meeting)
    }

    func prepareForTermination(meetingRepository: MeetingRepository) {
        guard let session = currentSession, let meeting = recordingMeeting else { return }
        session.stop()
        if var fresh = meetingRepository.meeting(id: meeting.id) ?? recordingMeeting {
            fresh.duration = session.elapsed
            fresh.state = .processing
            meetingRepository.upsert(fresh)
        }
        clear()
    }

    private func startSession(
        for meeting: Meeting,
        meetingRepository: MeetingRepository
    ) -> Result<RecordingSessionHandle, RecordingError> {
        let archive = meetingRepository.archive
        do {
            try archive.createFolder(for: meeting.id)
        } catch {
            return .failure(.archiveCreationFailed(error.localizedDescription))
        }

        let newSession = RecordingSession(meetingID: meeting.id, archive: archive)
        do {
            try newSession.start(
                micURL: archive.micURL(for: meeting.id),
                systemURL: archive.systemURL(for: meeting.id))
        } catch {
            try? FileManager.default.removeItem(at: archive.folder(for: meeting.id))
            return .failure(.sessionStartFailed(error.localizedDescription))
        }
        var saved = meeting
        saved.notice = newSession.startupNotice
        meetingRepository.upsert(saved)
        currentSession = newSession
        recordingMeeting = saved
        return .success(RecordingSessionHandle(session: newSession, meeting: saved))
    }

    private func clear() {
        currentSession = nil
        recordingMeeting = nil
    }

    private func applyCalendarEvent(_ event: CalendarEventSummary, to meeting: inout Meeting) {
        meeting.title = event.title
        meeting.calendarEventTitle = event.title
        meeting.attendees = event.attendees
        meeting.calendarEventID = event.id
        meeting.calendarEventStart = event.start
        meeting.calendarEventEnd = event.end
    }
}

final class NotificationServiceImpl: NotificationService, @unchecked Sendable {
    private var onReadyTapped: (@Sendable (UUID) -> Void)?
    private var detectionChime: NSSound?
    private let log = Logger(subsystem: "io.github.conrad-vanl.Parfait", category: "notifications")

    func configure(onReadyTapped: @escaping @Sendable (UUID) -> Void) {
        self.onReadyTapped = onReadyTapped
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationCenterDelegate.shared
        NotificationCenterDelegate.shared.onReadyTapped = onReadyTapped
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.log.info("notification auth granted=\(granted) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        }
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func refreshAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func notifyMeetingReady(_ meeting: Meeting) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = meeting.title
        content.body = "Your meeting notes are ready."
        let request = UNNotificationRequest(
            identifier: "ready-\(meeting.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func playDetectionChime() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        if detectionChime?.isPlaying == true { return }
        let sound = NSSound(named: NSSound.Name("Ping"))
        detectionChime = sound
        sound?.play()
    }
}

/// Bridges UNUserNotificationCenterDelegate to the Sendable notification service.
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationCenterDelegate()
    var onReadyTapped: (@Sendable (UUID) -> Void)?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        guard identifier.hasPrefix("ready-"),
              let id = UUID(uuidString: String(identifier.dropFirst("ready-".count))) else { return }
        await MainActor.run {
            onReadyTapped?(id)
            NSApp.activate()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
