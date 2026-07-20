import Foundation

/// A decision explicitly made during a meeting, extracted from the transcript.
struct Decision: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    /// The full segment text that contained the decision phrase.
    let quote: String
    let speakerID: String
    let speakerName: String
    /// Seconds from recording start, taken from the segment's `start`.
    let timestamp: TimeInterval
    /// The full segment text the decision was found in (same as `quote`).
    let context: String
}

/// Extracts explicit decisions from a transcript using phrase pattern matching.
///
/// Scans each segment for a set of decision phrases (e.g. "let's go with",
/// "we decided"), case-insensitively. The matching segment's full text becomes
/// the `quote`/`context`, its `start` becomes the `timestamp`, and the speaker
/// name is resolved from the provided speakers list (falling back to the
/// speaker ID). Near-duplicate decisions — those sharing the same first 50
/// characters of their quote — are collapsed to the first occurrence.
enum DecisionExtractor {
    /// Phrases that signal an explicit decision. Matched case-insensitively
    /// as substrings anywhere in a segment.
    static let phrases: [String] = [
        "let's go with",
        "we decided",
        "i'll approve",
        "let's do",
        "we should use",
        "agreed on",
        "final decision",
        "going with",
        "i think we should",
        "the plan is",
    ]

    /// Extract decisions from transcript segments, resolving speaker names.
    static func extract(from segments: [TranscriptSegment], speakers: [Speaker]) -> [Decision] {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        var seen = Set<String>()
        var results: [Decision] = []

        for segment in segments {
            let lower = segment.text.lowercased()
            guard phrases.contains(where: { lower.contains($0) }) else { continue }

            // Deduplicate by the first 50 characters of the quote, lowercased.
            let prefix = String(lower.prefix(50))
            guard !seen.contains(prefix) else { continue }
            seen.insert(prefix)

            let name = names[segment.speakerID] ?? segment.speakerID
            results.append(Decision(
                quote: segment.text,
                speakerID: segment.speakerID,
                speakerName: name,
                timestamp: segment.start,
                context: segment.text))
        }
        return results
    }
}
