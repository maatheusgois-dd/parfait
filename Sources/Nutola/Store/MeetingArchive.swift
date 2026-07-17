import Foundation

/// File-backed meeting storage. One folder per meeting:
///
///     <root>/Meetings/<uuid>/
///         meeting.json      Meeting
///         transcript.json   [TranscriptSegment]
///         summary.md        markdown
///         notes.md          user scratch notes (during recording)
///         mic.m4a           the user's microphone
///         system.m4a        everyone else (process tap)
///         speaker_events.json  Zoom active-speaker timeline (optional)
///         Edits/             snapshots of summary.md before each overwrite (last N)
///
/// Thread-safe for the app's usage pattern: the UI goes through the
/// @MainActor MeetingStore wrapper; the MCP server process is read-only.
final class MeetingArchive: @unchecked Sendable {
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nutola", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "io.github.matheusgois-dd.Nutola.archive")
    // ISO8601 with fractional seconds so Dates round-trip losslessly enough for Equatable.
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(MeetingArchive.dateFormatter.string(from: date))
        }
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = MeetingArchive.dateFormatter.date(from: s)
                ?? ISO8601DateFormatter().date(from: s)
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: dec.codingPath, debugDescription: "Bad date: \(s)"))
            }
            return date
        }
        return d
    }()

    init(root: URL = MeetingArchive.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
    }

    var meetingsDir: URL { root.appendingPathComponent("Meetings", isDirectory: true) }

    func folder(for id: UUID) -> URL {
        meetingsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    func micURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("mic.m4a") }
    func systemURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("system.m4a") }

    // MARK: - Meetings

    func allMeetings() -> [Meeting] {
        queue.sync {
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: meetingsDir, includingPropertiesForKeys: nil)) ?? []
            return dirs.compactMap { dir in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json"))
                else { return nil }
                return try? decoder.decode(Meeting.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
        }
    }

    func meeting(id: UUID) -> Meeting? {
        queue.sync {
            guard let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("meeting.json"))
            else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
    }

    enum ArchiveError: Error {
        case meetingDeleted
    }

    /// The meeting folder is created once, at recording start. Refusing to
    /// recreate it here means an in-flight pipeline writing back to a meeting
    /// the user deleted mid-run fails instead of resurrecting it.
    func save(_ meeting: Meeting) throws {
        try queue.sync {
            let dir = folder(for: meeting.id)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                throw ArchiveError.meetingDeleted
            }
            let data = try encoder.encode(meeting)
            try data.write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
        }
    }

    func createFolder(for id: UUID) throws {
        try FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
    }

    func delete(id: UUID) throws {
        try queue.sync {
            try FileManager.default.removeItem(at: folder(for: id))
        }
    }

    // MARK: - Transcript

    func transcript(for id: UUID) -> [TranscriptSegment] {
        queue.sync {
            guard let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("transcript.json"))
            else { return [] }
            return (try? decoder.decode([TranscriptSegment].self, from: data)) ?? []
        }
    }

    func saveTranscript(_ segments: [TranscriptSegment], for id: UUID) throws {
        try queue.sync {
            let data = try encoder.encode(segments)
            try data.write(to: folder(for: id).appendingPathComponent("transcript.json"), options: .atomic)
        }
    }

    // MARK: - Live transcript (present only while a meeting is recording)

    func liveTranscriptURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("live.json")
    }

    /// Best-effort atomic write of the rolling transcript. Silently no-ops if the
    /// meeting folder is gone (discarded mid-recording).
    func saveLiveTranscript(_ segments: [TranscriptSegment], for id: UUID) {
        queue.sync {
            guard let data = try? encoder.encode(segments) else { return }
            try? data.write(to: liveTranscriptURL(for: id), options: .atomic)
        }
    }

    func liveTranscript(for id: UUID) -> [TranscriptSegment] {
        queue.sync {
            guard let data = try? Data(contentsOf: liveTranscriptURL(for: id)) else { return [] }
            return (try? decoder.decode([TranscriptSegment].self, from: data)) ?? []
        }
    }

    /// Last-modified time of the live transcript, for the MCP freshness guard.
    func liveTranscriptModified(for id: UUID) -> Date? {
        queue.sync {
            try? FileManager.default
                .attributesOfItem(atPath: liveTranscriptURL(for: id).path)[.modificationDate] as? Date
        }
    }

    func removeLiveTranscript(for id: UUID) {
        queue.sync { try? FileManager.default.removeItem(at: liveTranscriptURL(for: id)) }
    }

    // MARK: - Platform speaker events (Zoom active-speaker timeline)

    func platformSpeakerEventsURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("speaker_events.json")
    }

    func platformSpeakerEvents(for id: UUID) -> [PlatformSpeakerEvent] {
        queue.sync {
            guard let data = try? Data(contentsOf: platformSpeakerEventsURL(for: id)) else { return [] }
            return (try? decoder.decode([PlatformSpeakerEvent].self, from: data)) ?? []
        }
    }

    func savePlatformSpeakerEvents(_ events: [PlatformSpeakerEvent], for id: UUID) {
        queue.sync {
            guard let data = try? encoder.encode(events) else { return }
            try? data.write(to: platformSpeakerEventsURL(for: id), options: .atomic)
        }
    }

    func removePlatformSpeakerEvents(for id: UUID) {
        queue.sync { try? FileManager.default.removeItem(at: platformSpeakerEventsURL(for: id)) }
    }

    // MARK: - Zoom roster snapshot (participants panel / video tiles)

    func zoomRosterURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("zoom_roster.json")
    }

    func zoomRoster(for id: UUID) -> [String] {
        queue.sync {
            guard let data = try? Data(contentsOf: zoomRosterURL(for: id)) else { return [] }
            return (try? decoder.decode([String].self, from: data)) ?? []
        }
    }

    func saveZoomRoster(_ names: [String], for id: UUID) {
        queue.sync {
            guard let data = try? encoder.encode(names) else { return }
            try? data.write(to: zoomRosterURL(for: id), options: .atomic)
        }
    }

    func removeZoomRoster(for id: UUID) {
        queue.sync { try? FileManager.default.removeItem(at: zoomRosterURL(for: id)) }
    }

    // MARK: - Summary

    func summary(for id: UUID) -> String {
        queue.sync {
            (try? String(contentsOf: folder(for: id).appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
        }
    }

    func saveSummary(_ markdown: String, for id: UUID) throws {
        try queue.sync {
            let summaryURL = folder(for: id).appendingPathComponent("summary.md")
            // Snapshot the outgoing summary so edits are recoverable. Only when a
            // non-empty summary already exists — the first write (empty → content)
            // isn't an edit, and snapshotting it would store an empty file forever.
            if let existing = try? String(contentsOf: summaryURL, encoding: .utf8),
               !existing.isEmpty, existing != markdown {
                snapshotSummary(existing, for: id)
            }
            try markdown.data(using: .utf8)!
                .write(to: summaryURL, options: .atomic)
        }
    }

    // MARK: - Summary edit history

    /// Maximum number of summary snapshots kept per meeting. Oldest drop first.
    static let maxSummaryHistory = 20

    private func editsDir(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("Edits", isDirectory: true)
    }

    /// Writes a snapshot of the outgoing summary into `Edits/`, named with a
    /// millisecond-epoch timestamp + a short nonce so multiple edits in the same
    /// millisecond don't collide. Lexicographic filename order == chronological
    /// order, so pruning the oldest is just dropping the first N. Prunes to
    /// `maxSummaryHistory`, oldest first.
    private func snapshotSummary(_ markdown: String, for id: UUID) {
        let dir = editsDir(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let epochMS = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = String(UUID().uuidString.prefix(4))
        let name = "summary-\(epochMS)-\(nonce).md"
        let dest = dir.appendingPathComponent(name)
        try? markdown.data(using: .utf8)!.write(to: dest, options: .atomic)
        pruneSummaryHistory(for: id)
    }

    private func pruneSummaryHistory(for id: UUID) {
        let dir = editsDir(for: id)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("summary-") && $0.pathExtension == "md" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        else { return }
        guard files.count > Self.maxSummaryHistory else { return }
        for file in files.prefix(files.count - Self.maxSummaryHistory) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// One saved summary snapshot: the timestamp is the write time (from the
    /// filename), `markdown` is the full content of that version.
    struct SummarySnapshot: Equatable, Sendable {
        let timestamp: Date
        let markdown: String
    }
    /// List saved summary snapshots for a meeting, newest first. Empty if the
    /// summary has never been overwritten since first write.
    func summaryHistory(for id: UUID) -> [SummarySnapshot] {
        queue.sync {
            let dir = editsDir(for: id)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter({ $0.lastPathComponent.hasPrefix("summary-") && $0.pathExtension == "md" })
            else { return [] }
            return files.compactMap { file -> SummarySnapshot? in
                let name = file.deletingPathExtension().lastPathComponent
                // summary-<epochMS>-<nonce> → drop prefix, split off nonce, parse epoch.
                let withoutPrefix = String(name.dropFirst("summary-".count))
                let parts = withoutPrefix.split(separator: "-")
                guard parts.count >= 2, let epochMS = Int64(parts[0]) else { return nil }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return SummarySnapshot(timestamp: Date(timeIntervalSince1970: TimeInterval(epochMS) / 1000),
                                        markdown: text)
            }
            .sorted { $0.timestamp > $1.timestamp }
        }
    }

    /// Restore a prior summary snapshot: the current summary becomes a snapshot
    /// itself (so restore is reversible), then the named version is written as
    /// summary.md. Returns true on success.
    @discardableResult
    func restoreSummary(at timestamp: Date, for id: UUID) -> Bool {
        // NOTE: runs entirely inside queue.sync. Do NOT call summaryHistory(for:)
        // here — it also queue.syncs on this serial queue → deadlock. We inline
        // the lookup via the private snapshot reader below.
        queue.sync {
            let dir = editsDir(for: id)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter({ $0.lastPathComponent.hasPrefix("summary-") && $0.pathExtension == "md" })
            else { return false }
            let target = files.compactMap { file -> SummarySnapshot? in
                let name = file.deletingPathExtension().lastPathComponent
                let withoutPrefix = String(name.dropFirst("summary-".count))
                let parts = withoutPrefix.split(separator: "-")
                guard parts.count >= 2, let epochMS = Int64(parts[0]) else { return nil }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return SummarySnapshot(timestamp: Date(timeIntervalSince1970: TimeInterval(epochMS) / 1000),
                                        markdown: text)
            }
            .first(where: { $0.timestamp == timestamp })
            guard let target else { return false }
            let summaryURL = folder(for: id).appendingPathComponent("summary.md")
            if let current = try? String(contentsOf: summaryURL, encoding: .utf8),
               !current.isEmpty, current != target.markdown {
                snapshotSummary(current, for: id)
            }
            do {
                try target.markdown.data(using: .utf8)!
                    .write(to: summaryURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - Side notes (user scratch pad during recording)

    func sideNotes(for id: UUID) -> String {
        queue.sync {
            (try? String(contentsOf: folder(for: id).appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
        }
    }

    func saveSideNotes(_ text: String, for id: UUID) throws {
        try queue.sync {
            try text.data(using: .utf8)!
                .write(to: folder(for: id).appendingPathComponent("notes.md"), options: .atomic)
        }
    }

    // MARK: - Search

    struct SearchHit: Sendable {
        var meeting: Meeting
        /// Segments (or summary lines) containing the query, capped per meeting.
        var excerpts: [String]
        var score: Int
    }

    /// Case-insensitive multi-word search over titles, summaries, transcripts, attendees.
    ///
    /// Skips the expensive transcript JSON decode when the raw file bytes can't
    /// contain any query word — a cheap `String.contains` pre-filter instead of
    /// decoding thousands of `TranscriptSegment`s for every meeting.
    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let lowerWords = words.map { $0.lowercased() }
        var hits: [SearchHit] = []
        for meeting in allMeetings() {
            var score = 0
            var excerpts: [String] = []
            let title = meeting.title.lowercased()
            for w in lowerWords where title.contains(w) { score += 10 }
            for name in meeting.attendees where lowerWords.contains(where: { name.lowercased().contains($0) }) {
                score += 6
                excerpts.append("Attendee: \(name)")
            }
            let summary = summary(for: meeting.id)
            for line in summary.split(separator: "\n") {
                let lower = line.lowercased()
                if lowerWords.contains(where: { lower.contains($0) }) {
                    score += 3
                    if excerpts.count < 6 { excerpts.append(String(line).trimmingCharacters(in: .whitespaces)) }
                }
            }
            let notes = sideNotes(for: meeting.id)
            for line in notes.split(separator: "\n") {
                let lower = line.lowercased()
                if lowerWords.contains(where: { lower.contains($0) }) {
                    score += 4
                    if excerpts.count < 6 { excerpts.append("Note: \(String(line).trimmingCharacters(in: .whitespaces))") }
                }
            }
            // Pre-filter: skip the transcript JSON decode entirely when the
            // raw file bytes don't contain any query word. Reading the file as
            // a String + lowercasing is far cheaper than decoding thousands of
            // TranscriptSegment objects that would match nothing.
            let transcriptURL = folder(for: meeting.id).appendingPathComponent("transcript.json")
            if let rawData = try? Data(contentsOf: transcriptURL),
               let rawString = String(data: rawData, encoding: .utf8) {
                let lowerRaw = rawString.lowercased()
                if lowerWords.contains(where: { lowerRaw.contains($0) }) {
                    let speakerNames = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0.name) })
                    for seg in (try? decoder.decode([TranscriptSegment].self, from: rawData)) ?? [] {
                        let lower = seg.text.lowercased()
                        if lowerWords.contains(where: { lower.contains($0) }) {
                            score += 1
                            if excerpts.count < 6 {
                                let who = speakerNames[seg.speakerID] ?? seg.speakerID
                                excerpts.append("\(who) @ \(Self.timestamp(seg.start)): \(seg.text)")
                            }
                        }
                    }
                }
            }
            if score > 0 { hits.append(SearchHit(meeting: meeting, excerpts: excerpts, score: score)) }
        }
        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    static func timestamp(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
