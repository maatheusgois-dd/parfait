import Foundation

/// Coarse sentiment label assigned to a single transcript segment.
///
/// Keyword-based (no model): the analyzer counts sentiment-bearing words
/// and returns the category with the most hits. `neutral` is the fallback
/// when no keyword appears at all. The four cases exist because meeting
/// talk often distinguishes "I disagree" (negative) from "this is a
/// blocker, ship is failing" (critical) — collapsing them would erase
/// the signal the UI surfaces next to each turn.
enum Sentiment: String, CaseIterable, Sendable {
    case positive
    case neutral
    case negative
    case critical

    /// Short glyph shown next to a turn card. Kept to single emojis so the
    /// indicator stays subtle — color carries the rest of the signal.
    var emoji: String {
        switch self {
        case .positive: return "🙂"
        case .neutral: return "😐"
        case .negative: return "😕"
        case .critical: return "🚨"
        }
    }

    /// Theme palette hex used by the transcript indicator. Stored as a
    /// string so this type stays free of SwiftUI/AppKit imports — the view
    /// layer resolves it to `Color` via `Color(hex:)`.
    var color: String {
        switch self {
        case .positive: return "#1A8917"   // medium green
        case .neutral: return "#8A8A8A"    // medium gray
        case .negative: return "#F2A93B"   // honey
        case .critical: return "#E0396B"   // raspberry
        }
    }
}

/// One speaker's sentiment on one segment. `analyze` returns one of these
/// per input segment, so the caller can attach the indicator to the
/// matching turn card without re-aggregating.
struct SpeakerSentiment: Identifiable, Equatable, Sendable {
    let speakerID: String
    let speakerName: String
    let sentiment: Sentiment
    /// `sentimentKeywordCount / totalWordCount` — 0 for segments with no
    /// words, 1.0 only when every word is a keyword (rare in practice).
    let score: Double
    let segmentIndex: Int

    var id: String { "\(speakerID)-\(segmentIndex)" }
}

/// Detects per-speaker, per-segment sentiment from a transcript using a
/// small keyword lexicon. No network, no model — fast enough to run on
/// every meeting and deterministic so tests pin its behavior.
///
/// Keyword categories are evaluated **in precedence order**: critical →
/// negative → positive. The first category with a non-zero keyword count
/// wins; ties fall back to that same order (critical beats negative
/// beats positive), so a segment that mentions both "risk" and "great"
/// reads as critical. With no keyword in any category the segment is
/// `neutral` and `score` is `0`.
enum SentimentAnalyzer {
    /// Lowercased keywords for each non-neutral sentiment. `neutral` has
    /// no list — it is the default when nothing else matches.
    private static let positiveKeywords: Set<String> = [
        "great", "excellent", "love", "agree", "perfect", "awesome",
    ]
    private static let negativeKeywords: Set<String> = [
        "concern", "issue", "problem", "disagree", "bad", "wrong",
    ]
    private static let criticalKeywords: Set<String> = [
        "urgent", "blocker", "risk", "critical", "failing",
    ]

    /// Classify every segment. Returns one `SpeakerSentiment` per segment,
    /// in input order, so callers can index by `segmentIndex`.
    static func analyze(
        segments: [TranscriptSegment],
        speakers: [Speaker]
    ) -> [SpeakerSentiment] {
        guard !segments.isEmpty else { return [] }
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })

        return segments.enumerated().map { index, segment in
            let words = Self.words(in: segment.text)
            let total = words.count
            let positive = Self.countKeywords(from: words, in: positiveKeywords)
            let negative = Self.countKeywords(from: words, in: negativeKeywords)
            let critical = Self.countKeywords(from: words, in: criticalKeywords)
            let keywordHits = positive + negative + critical

            // Precedence: critical > negative > positive. A segment with
            // no sentiment words is neutral by default.
            let sentiment: Sentiment
            if critical > 0 {
                sentiment = .critical
            } else if negative > 0 {
                sentiment = .negative
            } else if positive > 0 {
                sentiment = .positive
            } else {
                sentiment = .neutral
            }

            let score = total > 0 ? Double(keywordHits) / Double(total) : 0

            return SpeakerSentiment(
                speakerID: segment.speakerID,
                speakerName: names[segment.speakerID] ?? segment.speakerID,
                sentiment: sentiment,
                score: score,
                segmentIndex: index)
        }
    }

    /// Whitespace-tokenized, lowercased words. Matches `TalkTimeStats`
    /// splitting semantics so word counts are consistent across the app.
    private static func words(in text: String) -> [String] {
        text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
    }

    /// Count how many of `words` appear in `set`. Strips common trailing
    /// punctuation so "great," and "great." still register as "great".
    private static func countKeywords(from words: [String], in set: Set<String>) -> Int {
        var count = 0
        for word in words {
            let trimmed = word.trimmingCharacters(
                in: CharacterSet(charactersIn: ".,!?;:\"'()[]"))
            if set.contains(trimmed) { count += 1 }
        }
        return count
    }
}
