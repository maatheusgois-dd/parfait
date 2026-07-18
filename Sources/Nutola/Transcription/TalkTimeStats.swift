import Foundation

/// Per-speaker talk-time summary for a single meeting.
struct SpeakerStats: Identifiable, Equatable, Sendable {
    let speakerID: String
    let name: String
    let talkTime: TimeInterval
    let wordCount: Int
    let segmentCount: Int
    let percentage: Double

    var id: String { speakerID }
}

/// Computes talk-time statistics from transcript segments.
///
/// For each speaker: sums `(end - start)` for talk time, counts words in the
/// segment text, and counts segments. `percentage` is `talkTime / totalTalkTime * 100`.
/// Results are sorted by talk time descending.
enum TalkTimeStats {
    static func compute(
        segments: [TranscriptSegment],
        speakers: [Speaker]
    ) -> [SpeakerStats] {
        // Preserve declaration order for stable ties (Swift `Dictionary` keeps
        // insertion order over `reserveCapacity` but not over random mutation,
        // so we track first-seen order explicitly).
        var order: [String] = []
        var talkTime: [String: TimeInterval] = [:]
        var words: [String: Int] = [:]
        var counts: [String: Int] = [:]

        for seg in segments {
            let dur = max(0, seg.end - seg.start)
            if talkTime[seg.speakerID] == nil { order.append(seg.speakerID) }
            talkTime[seg.speakerID, default: 0] += dur
            words[seg.speakerID, default: 0] += Self.wordCount(in: seg.text)
            counts[seg.speakerID, default: 0] += 1
        }

        let total = talkTime.values.reduce(0, +)
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })

        let stats: [SpeakerStats] = order.map { id in
            let time = talkTime[id, default: 0]
            let pct = total > 0 ? time / total * 100 : 0
            return SpeakerStats(
                speakerID: id,
                name: names[id] ?? id,
                talkTime: time,
                wordCount: words[id, default: 0],
                segmentCount: counts[id, default: 0],
                percentage: pct)
        }

        return stats.sorted { lhs, rhs in
            lhs.talkTime != rhs.talkTime
                ? lhs.talkTime > rhs.talkTime
                : lhs.speakerID < rhs.speakerID
        }
    }

    /// Word count for a single segment. Splits on whitespace runs; empty strings
    /// (leading/trailing/doubled whitespace) are not counted as words.
    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
