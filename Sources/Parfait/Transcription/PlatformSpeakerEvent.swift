import Foundation

/// A stretch of time when a conferencing app reported someone as the active speaker.
/// Collected during recording (Zoom today) and correlated with the system-audio
/// transcript after Stop.
struct PlatformSpeakerEvent: Codable, Equatable, Sendable {
    /// Display name from the meeting client (e.g. Zoom roster / active-speaker UI).
    var name: String
    var start: TimeInterval
    var end: TimeInterval
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
