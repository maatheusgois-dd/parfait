import Foundation

enum SpeakerLabeler {
    /// Silence between consecutive words that forces a new segment even for the same speaker.
    private static let maxWordGap: TimeInterval = 1.5

    static func label(
        mic: TranscriptionOutput?,
        system: TranscriptionOutput?,
        systemTurns: [DiarizedTurn]?,
        myName: String
    ) -> (segments: [TranscriptSegment], speakers: [Speaker]) {
        var segments: [TranscriptSegment] = []
        var speakers: [Speaker] = []

        if let mic {
            let micSegments = mic.segments.map {
                TranscriptSegment(speakerID: "me", start: $0.start, end: $0.end, text: $0.text)
            }
            if !micSegments.isEmpty {
                speakers.append(Speaker(id: "me", name: myName, isMe: true))
            }
            segments.append(contentsOf: micSegments)
        }

        if let system {
            let (systemSegments, systemSpeakers) = labelSystem(system, turns: systemTurns)
            segments.append(contentsOf: systemSegments)
            speakers.append(contentsOf: systemSpeakers)
        }

        // Stable merge: mic segments precede system segments on start-time ties.
        let merged = segments.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        return (merged, speakers)
    }

    private static func labelSystem(
        _ system: TranscriptionOutput,
        turns: [DiarizedTurn]?
    ) -> ([TranscriptSegment], [Speaker]) {
        guard let turns, !turns.isEmpty else {
            let segs = system.segments.map {
                TranscriptSegment(speakerID: "s1", start: $0.start, end: $0.end, text: $0.text)
            }
            return (segs, segs.isEmpty ? [] : [Speaker(id: "s1", name: "Speaker 1")])
        }

        var idForTurnKey: [String: String] = [:]
        var speakers: [Speaker] = []
        var segments: [TranscriptSegment] = []
        var groupWords: [TranscribedWord] = []
        var groupSpeakerID = ""

        func flush() {
            guard let first = groupWords.first, let last = groupWords.last else { return }
            let text = groupWords
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            segments.append(
                TranscriptSegment(speakerID: groupSpeakerID, start: first.start, end: last.end, text: text)
            )
            groupWords.removeAll()
        }

        for word in system.words {
            let key = turns[turnIndex(for: word, in: turns)].speaker
            let speakerID: String
            if let existing = idForTurnKey[key] {
                speakerID = existing
            } else {
                speakerID = "s\(speakers.count + 1)"
                idForTurnKey[key] = speakerID
                speakers.append(Speaker(id: speakerID, name: "Speaker \(speakers.count + 1)"))
            }
            let gap = groupWords.last.map { word.start - $0.end } ?? 0
            if speakerID != groupSpeakerID || gap > maxWordGap {
                flush()
            }
            groupSpeakerID = speakerID
            groupWords.append(word)
        }
        flush()
        return (segments, speakers)
    }

    private static func turnIndex(for word: TranscribedWord, in turns: [DiarizedTurn]) -> Int {
        var bestIndex = 0
        var bestOverlap: TimeInterval = 0
        for (i, turn) in turns.enumerated() {
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestIndex = i
            }
        }
        if bestOverlap > 0 { return bestIndex }

        let wordMid = (word.start + word.end) / 2
        var nearest = 0
        var bestDistance = TimeInterval.infinity
        for (i, turn) in turns.enumerated() {
            let distance = abs((turn.start + turn.end) / 2 - wordMid)
            if distance < bestDistance {
                bestDistance = distance
                nearest = i
            }
        }
        return nearest
    }
}
