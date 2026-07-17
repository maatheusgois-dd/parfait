import Combine
import Foundation
import SwiftUI

/// Composition root — wires repositories, services, and use cases (DIP).
@MainActor
final class DependencyContainer {
    let meetingRepository: MeetingRepository
    let folderRepository: FolderRepository
    let calendarRepository: CalendarRepository
    let templateRepository: TemplateRepository
    let settings: SettingsRepository

    let recordingService: RecordingService
    let processingService: ProcessingService
    let detectionService: MeetingDetectionService
    let notificationService: NotificationService

    let startRecording: StartRecordingUseCase
    let stopRecording: StopRecordingUseCase
    let discardRecording: DiscardRecordingUseCase
    let continueRecording: ContinueRecordingUseCase
    let prepareMeeting: PrepareMeetingUseCase
    let openCalendarEvent: OpenCalendarEventUseCase
    let processMeeting: ProcessMeetingUseCase
    let regenerateSummary: RegenerateSummaryUseCase
    let retryMeeting: RetryMeetingUseCase

    let detectionCoordinator: MeetingDetectionCoordinator

    var meetingStore: MeetingStore { meetingRepository as! MeetingStore }
    var folderStore: MeetingFolderStore { folderRepository as! MeetingFolderStore }
    var calendarStore: CalendarStore { calendarRepository as! CalendarStore }
    var templateStore: TemplateStore { (templateRepository as! TemplateRepositoryImpl).store }

    static func live(
        meetingStore: MeetingStore? = nil,
        folderStore: MeetingFolderStore? = nil,
        calendarStore: CalendarStore? = nil,
        templateStore: TemplateStore? = nil,
        settings: SettingsRepository = UserDefaultsSettingsRepository(),
        recordingService: RecordingService? = nil,
        processingService: ProcessingService = ProcessingServiceImpl(),
        detectionService: MeetingDetectionService = MeetingDetectionServiceImpl(),
        notificationService: NotificationService = NotificationServiceImpl()
    ) -> DependencyContainer {
        DependencyContainer(
            meetingStore: meetingStore ?? MeetingStore(),
            folderStore: folderStore ?? MeetingFolderStore(),
            calendarStore: calendarStore ?? CalendarStore(),
            templateStore: templateStore ?? TemplateStore(),
            settings: settings,
            recordingService: recordingService,
            processingService: processingService,
            detectionService: detectionService,
            notificationService: notificationService)
    }

    init(
        meetingStore: MeetingStore,
        folderStore: MeetingFolderStore,
        calendarStore: CalendarStore,
        templateStore: TemplateStore,
        settings: SettingsRepository,
        recordingService: RecordingService?,
        processingService: ProcessingService,
        detectionService: MeetingDetectionService,
        notificationService: NotificationService
    ) {
        self.meetingRepository = meetingStore
        self.folderRepository = folderStore
        self.calendarRepository = calendarStore
        self.templateRepository = TemplateRepositoryImpl(store: templateStore)
        self.settings = settings
        self.recordingService = recordingService ?? RecordingServiceImpl()
        self.processingService = processingService
        self.detectionService = detectionService
        self.notificationService = notificationService

        self.prepareMeeting = PrepareMeetingUseCase(
            meetingRepository: meetingRepository,
            folderRepository: folderRepository,
            settings: settings)
        self.openCalendarEvent = OpenCalendarEventUseCase(
            meetingRepository: meetingRepository,
            calendarRepository: calendarRepository,
            prepareMeeting: prepareMeeting)
        self.startRecording = StartRecordingUseCase(
            recordingService: self.recordingService,
            meetingRepository: meetingRepository,
            folderRepository: folderRepository,
            calendarRepository: calendarRepository,
            settings: settings)
        self.discardRecording = DiscardRecordingUseCase(
            recordingService: self.recordingService,
            meetingRepository: meetingRepository)
        self.continueRecording = ContinueRecordingUseCase(
            recordingService: self.recordingService,
            meetingRepository: meetingRepository)

        let processUC = ProcessMeetingUseCase(
            meetingRepository: meetingRepository,
            processingService: processingService,
            notificationService: notificationService)
        self.processMeeting = processUC

        self.stopRecording = StopRecordingUseCase(
            recordingService: self.recordingService,
            meetingRepository: meetingRepository,
            processMeeting: processUC)

        self.regenerateSummary = RegenerateSummaryUseCase(
            meetingRepository: meetingRepository,
            processingService: processingService)
        self.retryMeeting = RetryMeetingUseCase(
            meetingRepository: meetingRepository,
            processMeeting: processUC,
            regenerateSummary: regenerateSummary)

        self.detectionCoordinator = MeetingDetectionCoordinator(
            detectionService: detectionService,
            settings: settings)
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment(container: .live())

    let container: DependencyContainer

    var store: MeetingStore { container.meetingStore }
    var templates: TemplateStore { container.templateStore }
    var calendar: CalendarStore { container.calendarStore }
    var folders: MeetingFolderStore { container.folderStore }

    init(container: DependencyContainer) {
        self.container = container
    }
}
