import Foundation

/// Orchestrates mic detection → auto-record / prompt / auto-stop (SRP).
@MainActor
final class MeetingDetectionCoordinator {
    private let detectionService: MeetingDetectionService
    private let settings: SettingsRepository
    private let startRecording: StartRecordingUseCase
    private let stopRecording: StopRecordingUseCase

    var onDetectedAppNameChanged: ((String?) -> Void)?
    var onActiveMicAppsChanged: (([pid_t: String]) -> Void)?
    var onDetectionChime: (() -> Void)?

    private(set) var activeMicApps: [pid_t: String] = [:]
    private var pendingDetection: MicEvent?
    private var pendingDetections: [pid_t: MicEvent] = [:]
    private var lastDetectionAnnounce: [pid_t: ContinuousClock.Instant] = [:]
    private static let announceCooldown: Duration = .seconds(15)
    private var pendingAutoStop: Task<Void, Never>?
    private static let autoStopGrace: Duration = .seconds(8)
    var isRecording: () -> Bool = { false }
    var isStartingRecording: () -> Bool = { false }

    init(
        detectionService: MeetingDetectionService,
        settings: SettingsRepository,
        startRecording: StartRecordingUseCase,
        stopRecording: StopRecordingUseCase
    ) {
        self.detectionService = detectionService
        self.settings = settings
        self.startRecording = startRecording
        self.stopRecording = stopRecording
    }

    func start() {
        ParfaitConsoleLog.detection("coordinator starting")
        detectionService.start { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func stop() {
        ParfaitConsoleLog.detection("coordinator stopping")
        detectionService.stop()
        pendingDetection = nil
        pendingDetections.removeAll()
        lastDetectionAnnounce.removeAll()
        activeMicApps.removeAll()
        onActiveMicAppsChanged?(activeMicApps)
        onDetectedAppNameChanged?(nil)
        pendingAutoStop?.cancel()
        pendingAutoStop = nil
    }

    func acceptDetection() async {
        let name = pendingDetection.map(MeetingDetectionServiceImpl.displayName)
        ParfaitConsoleLog.detection("user accepted prompt for \(name ?? "?")")
        _ = await startRecording.execute(sourceApp: name, calendarEvent: nil)
        clearPendingDetection()
    }

    func dismissDetection() {
        ParfaitConsoleLog.detection("user dismissed prompt")
        clearPendingDetection()
    }

    var detectedAppName: String? {
        pendingDetection.map(MeetingDetectionServiceImpl.displayName)
    }

    private func clearPendingDetection() {
        pendingDetection = nil
        pendingDetections.removeAll()
        onDetectedAppNameChanged?(nil)
    }

    private func handle(_ event: MicEvent) {
        guard !MeetingDetectionServiceImpl.isIgnored(bundleID: event.bundleID) else { return }
        let name = MeetingDetectionServiceImpl.displayName(for: event)

        if event.isRunningInput {
            ParfaitConsoleLog.detection("mic on — \(name) pid=\(event.pid) bundle=\(event.bundleID ?? "?")")
            activeMicApps[event.pid] = name
            onActiveMicAppsChanged?(activeMicApps)
            pendingAutoStop?.cancel()
            pendingAutoStop = nil

            if isRecording() { return }
            guard !isStartingRecording() else { return }

            if settings.autoRecord {
                ParfaitConsoleLog.detection("auto-record for \(name)")
                Task { await startRecording.execute(sourceApp: name, calendarEvent: nil) }
            } else {
                let now = ContinuousClock.now
                let recentlyAnnounced = lastDetectionAnnounce[event.pid]
                    .map { now - $0 < Self.announceCooldown } ?? false
                lastDetectionAnnounce[event.pid] = now
                pendingDetections[event.pid] = event
                onDetectedAppNameChanged?(name)
                pendingDetection = event
                if !recentlyAnnounced {
                    ParfaitConsoleLog.detection("showing prompt for \(name)")
                    onDetectionChime?()
                }
            }
        } else {
            ParfaitConsoleLog.detection("mic off — \(name) pid=\(event.pid)")
            activeMicApps.removeValue(forKey: event.pid)
            onActiveMicAppsChanged?(activeMicApps)
            pendingDetections.removeValue(forKey: event.pid)
            if !isRecording(), event.pid == pendingDetection?.pid {
                if let next = pendingDetections.values.first {
                    onDetectedAppNameChanged?(MeetingDetectionServiceImpl.displayName(for: next))
                    pendingDetection = next
                } else {
                    onDetectedAppNameChanged?(nil)
                    pendingDetection = nil
                }
            }
            guard isRecording(), settings.autoStopRecording, activeMicApps.isEmpty else { return }
            ParfaitConsoleLog.detection("scheduling auto-stop in 8s")
            pendingAutoStop = Task { [weak self] in
                try? await Task.sleep(for: Self.autoStopGrace)
                guard !Task.isCancelled else { return }
                await self?.autoStop()
            }
        }
    }

    private func autoStop() async {
        guard isRecording(), settings.autoStopRecording, activeMicApps.isEmpty else { return }
        ParfaitConsoleLog.detection("auto-stop firing")
        _ = await stopRecording.execute()
    }
}
