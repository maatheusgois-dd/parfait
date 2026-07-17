import SwiftUI

struct TranscriptTurn: Identifiable, Equatable, Sendable {
    /// Stable key for scroll/search: "\(speakerID)-\(start)".
    var id: String
    var speakerID: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var segmentCount: Int
}

enum TranscriptTurnBuilder {
    private static let remotePalette: [Color] = [
        Theme.raspberry, Theme.honey, Theme.mint,
        Theme.blueberry,
    ]

    static func turns(from segments: [TranscriptSegment]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var speaker: String?
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var texts: [String] = []
        var count = 0

        func flush() {
            guard let speaker, !texts.isEmpty else { return }
            turns.append(TranscriptTurn(
                id: "\(speaker)-\(Int((start * 1000).rounded()))",
                speakerID: speaker,
                start: start,
                end: end,
                text: texts.joined(separator: " "),
                segmentCount: count))
        }

        for seg in segments {
            if seg.speakerID != speaker {
                flush()
                speaker = seg.speakerID
                start = seg.start
                end = seg.end
                texts = []
                count = 0
            }
            texts.append(seg.text)
            end = seg.end
            count += 1
        }
        flush()
        return turns
    }

    /// "You" / `isMe` → blueberry; remote speakers get a stable color by first-seen order.
    static func speakerColor(
        speakerID: String,
        speakers: [Speaker],
        turns: [TranscriptTurn],
        scheme: ColorScheme
    ) -> Color {
        if speakerID == LiveTranscriber.youSpeakerID
            || speakers.first(where: { $0.id == speakerID })?.isMe == true {
            return Theme.blueberry(scheme)
        }

        let remoteIDs = orderedRemoteSpeakerIDs(speakers: speakers, turns: turns)
        let index = remoteIDs.firstIndex(of: speakerID) ?? remoteIDs.count
        if index < remotePalette.count {
            return remotePalette[index]
        }
        return Theme.secondary(scheme).opacity(0.85)
    }

    private static func orderedRemoteSpeakerIDs(
        speakers: [Speaker],
        turns: [TranscriptTurn]
    ) -> [String] {
        var seen: [String] = []
        var ids: [String] = []

        func consider(_ speakerID: String) {
            guard speakerID != LiveTranscriber.youSpeakerID,
                  speakers.first(where: { $0.id == speakerID })?.isMe != true,
                  !seen.contains(speakerID) else { return }
            seen.append(speakerID)
            ids.append(speakerID)
        }

        for turn in turns { consider(turn.speakerID) }
        for speaker in speakers where !speaker.isMe && speaker.id != LiveTranscriber.youSpeakerID {
            consider(speaker.id)
        }
        return ids
    }
}
