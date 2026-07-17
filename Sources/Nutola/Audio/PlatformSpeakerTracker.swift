import Foundation

/// A per-conferencing-app speaker tracker that polls the client's UI during
/// recording and reports who is speaking, for attributing system-audio
/// transcript segments to named participants instead of generic
/// "Speaker 1..N".
///
/// Today only Zoom is implemented (`ZoomSpeakerTracker`); Meet/Teams/FaceTime
/// fall back to `NoopSpeakerTracker` (diarization-only). Adding a platform is
/// a new conformer + a line in `PlatformSpeakerTrackerFactory.forApp(_:)`,
/// not a change to `RecordingSession`.
protocol PlatformSpeakerTracker: AnyObject {
    /// Called on the main queue whenever the active remote speaker changes.
    var onActiveSpeaker: (@MainActor (String?) -> Void)? { get set }

    /// Thread-safe snapshot of the active speaker name at elapsed time `t`,
    /// for attributing live system-audio segments.
    func speakerAt(_ elapsed: TimeInterval) -> String?

    /// Thread-safe snapshot of the current participant roster.
    func currentRoster() -> [String]

    func start()
    func stop()
}

/// Chooses a speaker tracker for the detected source app. Returns a no-op
/// tracker for platforms without an AX/caption reader, so `RecordingSession`
/// always has *something* conforming and never nil-checks the platform.
enum PlatformSpeakerTrackerFactory {
    static func forApp(
        bundleID: String?,
        meetingID: UUID,
        archive: MeetingArchive,
        startDate: Date,
        elapsedOffset: TimeInterval
    ) -> PlatformSpeakerTracker {
        switch bundleID {
        case "us.zoom.xos", "us.zoom.VideoHost":
            return ZoomSpeakerTracker(
                meetingID: meetingID,
                archive: archive,
                startDate: startDate,
                elapsedOffset: elapsedOffset)
        default:
            // Meet, Teams, FaceTime, Webex, manual — no AX reader yet.
            // Diarization + the fallback "Others" speaker carry the load.
            return NoopSpeakerTracker()
        }
    }
}

/// A no-op tracker for platforms Nutola can't read by AX yet. Conforms so
/// `RecordingSession` treats every platform uniformly; `speakerAt` returns
/// nil (so diarization owns attribution) and the roster stays empty.
final class NoopSpeakerTracker: PlatformSpeakerTracker {
    var onActiveSpeaker: (@MainActor (String?) -> Void)?
    func speakerAt(_ elapsed: TimeInterval) -> String? { nil }
    func currentRoster() -> [String] { [] }
    func start() {}
    func stop() {}
}
