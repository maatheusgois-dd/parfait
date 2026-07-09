import Foundation

/// A word (or larger chunk when word timing is unavailable) with audio timestamps.
struct TranscribedWord: Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Output of transcribing one audio file (one channel of a meeting).
struct TranscriptionOutput: Sendable, Equatable {
    /// Finest-grained timing available (per-word when the model provides it).
    var words: [TranscribedWord]
    /// Result-level segments (sentence/phrase sized).
    var segments: [TranscribedWord]
}

/// One diarized speaker turn on the system-audio channel. Speaker keys are the
/// diarizer's ("S1", "S2", …) — mapped to display speakers by SpeakerLabeler.
struct DiarizedTurn: Sendable, Equatable {
    var speaker: String
    var start: TimeInterval
    var end: TimeInterval
}
