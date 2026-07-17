import Foundation

/// How a platform speaker event was observed. Higher-confidence sources win when
/// correlating diarization clusters with Zoom display names.
enum PlatformSpeakerSource: String, Codable, Sendable {
    /// Zoom video tile marked ", active speaker".
    case activeSpeaker
    /// Zoom live-transcript / closed-caption line with a speaker prefix.
    case caption
    /// Participant tile with AXSelected set (fallback when no active-speaker tile).
    case selectedTile
}

/// A stretch of time when a conferencing app reported someone as the active speaker.
/// Collected during recording (Zoom today) and correlated with the system-audio
/// transcript after Stop.
struct PlatformSpeakerEvent: Codable, Equatable, Sendable {
    /// Display name from the meeting client (e.g. Zoom roster / active-speaker UI).
    var name: String
    var start: TimeInterval
    var end: TimeInterval
    var source: PlatformSpeakerSource = .activeSpeaker
}

enum PlatformSpeakerTurnBuilder {
    static func turns(from events: [PlatformSpeakerEvent]) -> [DiarizedTurn] {
        events.map { DiarizedTurn(speaker: $0.name, start: $0.start, end: $0.end) }
    }

    /// Collapse consecutive same-name events and close any zero-length spans.
    static func normalized(_ events: [PlatformSpeakerEvent]) -> [PlatformSpeakerEvent] {
        guard !events.isEmpty else { return [] }
        var out: [PlatformSpeakerEvent] = []
        for event in events.sorted(by: { $0.start < $1.start }) {
            guard event.end > event.start else { continue }
            if var last = out.last, last.name == event.name, event.start <= last.end + 0.5 {
                last.end = max(last.end, event.end)
                out[out.count - 1] = last
            } else {
                out.append(event)
            }
        }
        return out
    }
}
