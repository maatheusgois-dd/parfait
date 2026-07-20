import Foundation

/// A chapter is a run of consecutive transcript turns that share a topic.
/// Produced by `TranscriptChapterizer` from a flat list of turns.
struct Chapter: Identifiable, Equatable {
    let id: UUID = UUID()
    /// Short label for the chapter — either the topic-shift keyword that
    /// opened it, or the first few words of the chapter's opening turn.
    let title: String
    /// Seconds from recording start to the first turn's start.
    let startTime: TimeInterval
    /// Seconds from recording start to the last turn's end.
    let endTime: TimeInterval
    /// Index range into the original `turns` array (half-open: `lowerBound`
    /// inclusive, `upperBound` exclusive).
    let turnIndices: Range<Int>
}

/// Breaks a flat transcript turn list into chapters by detecting topic shifts.
///
/// Three split heuristics, in priority order:
/// 1. **Long pauses** — a gap of more than 30s between the end of one turn and
///    the start of the next opens a new chapter.
/// 2. **Topic-shift keywords** — phrases like "next topic", "moving on",
///    "let's talk about", or an explicit agenda item at the start of a turn
///    open a new chapter.
/// 3. **Speaker change after a long monologue** — a new speaker after 5 or
///    more consecutive turns by the same speaker opens a new chapter.
///
/// Chapters shorter than `minChapterDuration` are merged into the previous
/// chapter so the outline stays useful rather than noisy. At least one chapter
/// is returned whenever there are any turns.
enum TranscriptChapterizer {
    /// A gap longer than this (seconds) between turns forces a chapter break.
    static let pauseThreshold: TimeInterval = 30
    /// A run of this many turns by one speaker counts as a monologue; a new
    /// speaker afterwards opens a chapter.
    static let monologueTurnCount = 5
    /// How many words of the opening turn to fold into a generated title.
    private static let titleWordCount = 6
    /// Whitespace + punctuation, used to clean matched keywords and titles.
    /// `CharacterSet` has no `.whitespacesAndPunctuation`, so we union the two.
    private static let trimSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)

    /// Phrases that signal an intentional topic change. Matched
    /// case-insensitively anywhere in a turn's text.
    private static let topicShiftPhrases: [String] = [
        "next topic",
        "moving on",
        "let's move on",
        "let's talk about",
        "let's discuss",
        "let's switch to",
        "on to the next",
        "turning to",
        "shifting to",
        "now let's",
        " agenda item",
        "next item",
        "next on the agenda",
        "switching gears",
        "that covers it",
        "any other business",
        "let's wrap up",
        "moving onto",
    ]

    /// Split `turns` into chapters using the heuristics above.
    /// - Parameters:
    ///   - turns: The transcript turns, in playback order.
    ///   - minChapterDuration: Chapters shorter than this (seconds) are merged
    ///     into the previous chapter. Defaults to 60.
    /// - Returns: One or more chapters covering all turns, or an empty array
    ///   when `turns` is empty.
    static func chapterize(
        turns: [TranscriptTurn],
        minChapterDuration: TimeInterval = 60
    ) -> [Chapter] {
        guard !turns.isEmpty else { return [] }

        // First pass: collect candidate chapter boundaries as index ranges.
        var ranges: [Range<Int>] = []
        var chapterStart = 0
        var currentSpeaker = turns[0].speakerID
        var consecutiveSameSpeaker = 1

        for i in 1..<turns.count {
            let prev = turns[i - 1]
            let curr = turns[i]

            // Pause: a long gap between the previous turn's end and this turn's
            // start always opens a new chapter.
            let gap = max(0, curr.start - prev.end)
            let paused = gap > pauseThreshold

            // Topic-shift keyword anywhere in the current turn's text.
            let shifted = topicShift(in: curr.text)

            // Speaker change after a monologue (5+ consecutive same-speaker
            // turns). We track the run as we walk so the count is exact.
            if curr.speakerID == currentSpeaker {
                consecutiveSameSpeaker += 1
            } else {
                let speakerChangedAfterMonologue = consecutiveSameSpeaker >= monologueTurnCount
                currentSpeaker = curr.speakerID
                consecutiveSameSpeaker = 1
                if speakerChangedAfterMonologue, !paused, !shifted {
                    ranges.append(chapterStart..<i)
                    chapterStart = i
                    continue
                }
            }

            if paused || shifted {
                ranges.append(chapterStart..<i)
                chapterStart = i
            }
        }
        // Close the final chapter.
        if chapterStart < turns.count {
            ranges.append(chapterStart..<turns.count)
        }

        // Build chapter records from the ranges.
        var chapters = ranges.map { range -> Chapter in
            let first = turns[range.lowerBound]
            let last = turns[range.upperBound - 1]
            return Chapter(
                title: title(for: turns, range: range),
                startTime: first.start,
                endTime: last.end,
                turnIndices: range
            )
        }

        // Merge chapters shorter than the minimum duration into the previous
        // chapter. We never drop the first chapter — if it's short, it simply
        // absorbs the next one instead.
        mergeShortChapters(&chapters, turns: turns, minDuration: minChapterDuration)

        return chapters
    }

    // MARK: - Internals

    /// True if `text` contains a topic-shift phrase (case-insensitive).
    private static func topicShift(in text: String) -> Bool {
        let lower = text.lowercased()
        return topicShiftPhrases.contains { lower.contains($0) }
    }

    /// Title for a chapter: prefer the topic-shift keyword that opened it (when
    /// the opening turn contains one), otherwise the first few words of the
    /// opening turn, capitalized. Always non-empty for a non-empty chapter.
    private static func title(for turns: [TranscriptTurn], range: Range<Int>) -> String {
        let opening = turns[range.lowerBound]
        if let keyword = detectedKeyword(in: opening.text) {
            return keyword
        }
        return leadingWordsTitle(from: opening.text)
    }

    /// Returns the first matched topic-shift phrase, title-cased, if any.
    private static func detectedKeyword(in text: String) -> String? {
        let lower = text.lowercased()
        for phrase in topicShiftPhrases {
            if let range = lower.range(of: phrase) {
                // Pull the matched substring from the original text so we keep
                // the speaker's own capitalization, then trim surrounding
                // whitespace and punctuation.
                let raw = String(text[range])
                    .trimmingCharacters(in: trimSet)
                return raw.isEmpty ? nil : raw
            }
        }
        return nil
    }

    /// Build a title from the first `titleWordCount` words of `text`,
    /// capitalized as a sentence. Falls back to a trimmed slice of the text
    /// when there are no word boundaries.
    private static func leadingWordsTitle(from text: String) -> String {
        let cleaned = text.trimmingCharacters(in: trimSet)
        guard !cleaned.isEmpty else { return "Chapter" }
        let words = cleaned.split { $0.isWhitespace || $0.isNewline }
        if words.isEmpty { return "Chapter" }
        let prefix = words.prefix(titleWordCount).joined(separator: " ")
        return capitalizeFirstLetter(prefix)
    }

    /// Capitalize only the first character, leaving the rest intact.
    private static func capitalizeFirstLetter(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// Merge any chapter whose duration is under `minDuration` into the
    /// preceding chapter. The first chapter is never dropped on its own; if
    /// it's short, it absorbs the next chapter instead so the outline always
    /// starts at turn 0.
    private static func mergeShortChapters(
        _ chapters: inout [Chapter],
        turns: [TranscriptTurn],
        minDuration: TimeInterval
    ) {
        guard chapters.count > 1 else { return }
        var merged: [Chapter] = [chapters[0]]

        for next in chapters.dropFirst() {
            let prev = merged[merged.count - 1]
            let nextDuration = max(0, next.endTime - next.startTime)

            if nextDuration < minDuration {
                // Absorb `next` into `prev`: extend the range and end time,
                // keep `prev`'s title (the opening topic) intact.
                let combined = Chapter(
                    title: prev.title,
                    startTime: prev.startTime,
                    endTime: next.endTime,
                    turnIndices: prev.turnIndices.lowerBound..<next.turnIndices.upperBound
                )
                merged[merged.count - 1] = combined
            } else {
                merged.append(next)
            }
        }

        // If the first chapter ended up too short, fold the second chapter
        // into it so the outline still starts at turn 0.
        if merged.count >= 2 {
            let firstDuration = max(0, merged[0].endTime - merged[0].startTime)
            if firstDuration < minDuration {
                let first = merged[0]
                let second = merged[1]
                merged[0] = Chapter(
                    title: first.title,
                    startTime: first.startTime,
                    endTime: second.endTime,
                    turnIndices: first.turnIndices.lowerBound..<second.turnIndices.upperBound
                )
                merged.remove(at: 1)
            }
        }

        chapters = merged
    }
}
