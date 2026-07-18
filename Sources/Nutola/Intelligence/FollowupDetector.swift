import Foundation

/// A follow-up reminder derived from an action item plus a due-date phrase found
/// in the transcript near the item's text. `dueDate` is nil when no due phrase is
/// found within the scan window; `isOverdue` is true when the resolved date is in
/// the past relative to `now`.
struct FollowupItem: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    let text: String
    let owner: String?
    let dueDate: Date?
    let isOverdue: Bool
    /// The transcript snippet that carried the due-date phrase, for provenance.
    let sourceQuote: String

    static func == (lhs: FollowupItem, rhs: FollowupItem) -> Bool {
        lhs.text == rhs.text
            && lhs.owner == rhs.owner
            && lhs.dueDate == rhs.dueDate
            && lhs.isOverdue == rhs.isOverdue
            && lhs.sourceQuote == rhs.sourceQuote
    }
}

/// Detects follow-up due dates mentioned in the transcript and attaches them to
/// action items parsed from the summary. For each action item, the detector scans
/// the transcript for due-date phrases within 200 characters of the item text and
/// resolves the first match to a concrete `Date`.
enum FollowupDetector {
    /// Half-window (in characters) around an action item's text in which we look
    /// for a due-date phrase.
    static let scanWindow = 200

    /// Detect follow-ups for a set of action items given a plain-text transcript.
    /// - Parameters:
    ///   - transcript: Plain-text transcript (e.g. from `TranscriptFormatter.plainText`).
    ///   - actionItems: Action items parsed from the meeting summary.
    ///   - now: Reference time used to resolve relative phrases and compute
    ///     `isOverdue`. Injected so tests are deterministic.
    /// - Returns: One `FollowupItem` per action item (in input order). Items with
    ///   no nearby due phrase have `dueDate == nil` and `isOverdue == false`.
    static func detect(
        from transcript: String,
        actionItems: [ActionItem],
        now: Date = .now
    ) -> [FollowupItem] {
        let calendar = Self.calendar()
        return actionItems.map { item in
            let (dueDate, sourceQuote) = resolveDueDate(
                for: item.text,
                in: transcript,
                now: now,
                calendar: calendar)
            let isOverdue = dueDate.map { $0 < now } ?? false
            return FollowupItem(
                text: item.text,
                owner: item.owner,
                dueDate: dueDate,
                isOverdue: isOverdue,
                sourceQuote: sourceQuote)
        }
    }

    // MARK: - Scanning

    /// Find the first due-date phrase near an occurrence of `itemText` in the
    /// transcript and resolve it. Returns `(.none, "")` when nothing matches.
    private static func resolveDueDate(
        for itemText: String,
        in transcript: String,
        now: Date,
        calendar: Calendar
    ) -> (dueDate: Date?, sourceQuote: String) {
        let needle = itemText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return (nil, "") }

        // Anchor the scan window at the best transcript location for this item.
        // Try a verbatim (case-insensitive) match first; fall back to a fuzzy
        // anchor at the densest cluster of the item's significant words, since the
        // summary often paraphrases the transcript ("Circle back on the roadmap"
        // vs "circle back next week on the roadmap").
        let lower = transcript.lowercased()
        let anchor: String.Index?
        if let firstRange = lower.range(of: needle.lowercased()) {
            anchor = firstRange.lowerBound
        } else {
            anchor = fuzzyAnchor(for: needle, in: lower)
        }
        guard let anchor else { return (nil, "") }

        let windowStart = lower.index(anchor, offsetBy: -scanWindow, limitedBy: lower.startIndex) ?? lower.startIndex
        let windowEnd = lower.index(anchor, offsetBy: scanWindow, limitedBy: lower.endIndex) ?? lower.endIndex
        let window = String(transcript[windowStart..<windowEnd])
        return resolveFirstDuePhrase(in: window, now: now, calendar: calendar)
    }

    /// Find the transcript index with the densest cluster of the item's
    /// significant words (length ≥ 4, lowercased). Returns the midpoint of the
    /// best-scoring window so the due-phrase scan centers on the most relevant
    /// passage. Returns nil when too few significant words overlap.
    private static func fuzzyAnchor(for itemText: String, in lowerTranscript: String) -> String.Index? {
        let stopWords: Set<String> = ["the", "and", "for", "with", "that", "this", "will", "need",
                                      "should", "have", "from", "your", "about", "into", "just"]
        let words = itemText.lowercased()
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 4 && !stopWords.contains($0) }
        guard words.count >= 2 else { return nil }

        // Score each index by how many item words appear within scanWindow chars
        // ahead of it. The best index becomes the anchor.
        var bestIndex: String.Index? = nil
        var bestScore = 0
        var pos = lowerTranscript.startIndex
        while pos < lowerTranscript.endIndex {
            let windowEnd = lowerTranscript.index(pos, offsetBy: scanWindow, limitedBy: lowerTranscript.endIndex) ?? lowerTranscript.endIndex
            let window = String(lowerTranscript[pos..<windowEnd])
            let score = words.reduce(0) { $0 + (window.contains($1) ? 1 : 0) }
            if score > bestScore {
                bestScore = score
                bestIndex = pos
            }
            pos = lowerTranscript.index(after: pos)
        }
        // Require at least half the significant words to overlap.
        guard bestScore >= max(2, (words.count + 1) / 2) else { return nil }
        return bestIndex
    }

    /// Resolve the first due-date phrase found in `text`, scanning phrases in
    /// priority order (most specific first).
    private static func resolveFirstDuePhrase(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (dueDate: Date?, sourceQuote: String) {
        // 1. Explicit "by <date>" / "before <date>" / "due <date>" with a parseable
        //    date string. Handled first because the captured group matters.
        if let explicit = resolveExplicitDate(in: text, now: now, calendar: calendar) {
            return explicit
        }

        // 2. Fixed relative/weekday phrases, most-specific first so "by end of week"
        //    beats a bare weekday and longer phrases beat their substrings.
        for phrase in fixedPhrases(now: now, calendar: calendar) {
            if let range = text.range(of: phrase.keyword, options: [.caseInsensitive, .regularExpression]) {
                let quote = snippet(around: range, in: text, radius: 32)
                if let date = phrase.resolve() {
                    return (date, quote)
                }
            }
        }
        return (nil, "")
    }

    // MARK: - Fixed phrase table

    /// A keyword (regex) plus a closure that resolves it to a `Date`.
    private struct DuePhrase {
        let keyword: String
        let resolve: () -> Date?
    }

    /// Ordered most-specific → least-specific. The first regex that matches a
    /// substring wins. "by end of week" is tested before bare weekdays so it wins.
    private static func fixedPhrases(now: Date, calendar: Calendar) -> [DuePhrase] {
        let weekdaySymbols = calendar.weekdaySymbols // index 0 = Sunday … 6 = Saturday
        let todayWeekday = calendar.component(.weekday, from: now) // 1=Sunday … 7=Saturday
        let endOfWeek = endOfWeekDate(now: now, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: now)

        var matchers: [DuePhrase] = []

        // "by end of week" / "by EOW" → end of the current week (Saturday 23:59).
        matchers.append(DuePhrase(keyword: #"\bby\s+end\s+of\s+week\b"#) { endOfWeek })
        matchers.append(DuePhrase(keyword: #"\bby\s+EOW\b"#) { endOfWeek })

        // "by Friday", "by Monday", … → next occurrence of that weekday on/after today.
        for (index, symbol) in weekdaySymbols.enumerated() {
            let targetWeekday = index + 1
            let date = nextWeekdayDate(target: targetWeekday, from: todayWeekday, now: now, calendar: calendar)
            let escaped = NSRegularExpression.escapedPattern(for: symbol)
            matchers.append(DuePhrase(keyword: #"\bby\s+\#(escaped)\b"#) { date })
        }

        // "end of week" / "EOW" without the "by" prefix.
        matchers.append(DuePhrase(keyword: #"\bend\s+of\s+week\b"#) { endOfWeek })
        matchers.append(DuePhrase(keyword: #"\bEOW\b"#) { endOfWeek })

        // Relative single-word phrases.
        matchers.append(DuePhrase(keyword: #"\btomorrow\b"#) { tomorrow })
        matchers.append(DuePhrase(keyword: #"\bnext\s+week\b"#) { nextWeek })
        matchers.append(DuePhrase(keyword: #"\btoday\b"#) { now })

        return matchers
    }

    // MARK: - Explicit "by/before/due <date>"

    /// Resolve explicit "by <date>" / "before <date>" / "due <date>" phrases by
    /// parsing the captured date string with a few common formats. Returns nil
    /// when no explicit phrase is present or the date text can't be parsed.
    private static func resolveExplicitDate(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (dueDate: Date?, sourceQuote: String)? {
        let pattern = #"\b(?:by|before|due)\s+([A-Za-z0-9 /,\-]+?)(?=[.,;!\n]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)),
            match.numberOfRanges >= 2 else { return nil }
        let dateTextRange = match.range(at: 1)
        guard dateTextRange.location != NSNotFound else { return nil }
        let dateText = nsText.substring(with: dateTextRange).trimmingCharacters(in: .whitespaces)

        // Quote the whole matched phrase (keyword + date) for provenance.
        let phraseRange = match.range
        let quote: String
        if let swiftRange = Range(phraseRange, in: text) {
            quote = snippet(around: swiftRange, in: text, radius: 32)
        } else {
            quote = ""
        }

        // Try a handful of common formats. Yearless dates roll to next year if
        // they'd fall in the past relative to today.
        let formats = ["MMM d yyyy", "MMMM d yyyy", "MMM d", "MMMM d", "M/d/yyyy", "yyyy-MM-dd"]
        for format in formats {
            guard let parsed = parseDate(dateText, format: format, calendar: calendar) else { continue }
            let hasYear = format.contains("yyyy")
            let resolved = hasYear ? parsed : adjustYearless(parsed, now: now, calendar: calendar)
            return (resolved, quote)
        }
        // Unparseable captured text (e.g. "by Friday" → "Friday") means this
        // isn't an explicit-date phrase — return nil so the fixed-phrase table
        // (weekday/relative) gets a chance to resolve it.
        return nil
    }

    private static func parseDate(_ string: String, format: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.date(from: string)
    }

    /// If a yearless date already passed this year, roll it to next year so "Dec 25"
    /// said in January resolves to the upcoming, not the previous, December.
    private static func adjustYearless(_ date: Date, now: Date, calendar: Calendar) -> Date {
        if date < calendar.startOfDay(for: now) {
            return calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
        return date
    }

    // MARK: - Weekday math

    /// Next occurrence of `target` weekday on or after today.
    /// `target` and `from` use Calendar weekday codes (1=Sunday … 7=Saturday).
    private static func nextWeekdayDate(
        target: Int,
        from todayWeekday: Int,
        now: Date,
        calendar: Calendar
    ) -> Date {
        let delta = (target - todayWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: now)) ?? now
    }

    /// End of the current week (Saturday 23:59:59) for "by end of week" / "EOW".
    private static func endOfWeekDate(now: Date, calendar: Calendar) -> Date {
        let todayWeekday = calendar.component(.weekday, from: now)
        // Saturday is weekday 7. Days until Saturday from today.
        let delta = (7 - todayWeekday + 7) % 7
        guard let saturday = calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: now)) else {
            return now
        }
        return calendar.date(bySettingHour: 23, minute: 59, second: 59, of: saturday) ?? saturday
    }

    /// Calendar anchored with Gregorian/en_US_POSIX for stable weekday math and
    /// date formatting, using the system timezone.
    private static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone.current
        return cal
    }

    // MARK: - Snippet

    /// A short quote around `range` for provenance.
    private static func snippet(around range: Range<String.Index>, in text: String, radius: Int) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lower..<upper])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
