import Foundation

struct ProcessingServiceImpl: ProcessingService {
    func process(
        meeting: Meeting,
        archive: MeetingArchive,
        onProgress: @escaping @Sendable (String) -> Void,
        onSummary: @escaping @Sendable (ProcessingPipeline.SummaryUpdate) -> Void
    ) async -> ProcessingPipeline.Outcome {
        await ProcessingPipeline.run(
            meeting: meeting,
            archive: archive,
            onProgress: onProgress,
            onSummary: onSummary)
    }

    func summarize(
        meeting: Meeting,
        transcript: String,
        userNotes: String,
        forceProvider: AIProvider? = nil,
        onDelta: (@Sendable (String) -> Void)?
    ) async -> ProcessingPipeline.SummaryOutcome {
        await ProcessingPipeline.summarize(
            meeting: meeting,
            transcript: transcript,
            userNotes: userNotes,
            forceProvider: forceProvider,
            onDelta: onDelta)
    }

    func generateTitle(summary: String, provider: String) async -> String? {
        await ProcessingPipeline.generateTitle(summary: summary, provider: provider)
    }
}

struct MeetingDetectionServiceImpl: MeetingDetectionService {
    private let detector = MeetingDetector()

    func start(onEvent: @escaping @Sendable (MicEvent) -> Void) {
        detector.start { event in
            onEvent(event)
        }
    }

    func stop() {
        detector.stop()
    }

    static func displayName(for event: MicEvent) -> String {
        MeetingDetector.displayName(for: event)
    }

    static func isIgnored(bundleID: String?) -> Bool {
        MeetingDetector.isIgnored(bundleID: bundleID)
    }
}
