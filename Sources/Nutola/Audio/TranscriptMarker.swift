/// Voice Commands During Recording — bookmarks dropped while recording.
///
/// A `TranscriptMarker` captures a point in a recording the user flagged via
/// the ⌃⌥B hotkey (or the "Hey Nutola, mark this" voice trigger). Markers are
/// persisted per meeting in UserDefaults by `TranscriptMarkerStore` and
/// surface in the transcript reader as `bookmark.fill` badges next to the
/// nearest turn; clicking a badge while viewing scrolls back to that turn.
import Foundation
import SwiftUI

/// A bookmark dropped into a meeting's transcript while recording (or after),
/// persisted per meeting in UserDefaults. Carries the recording timestamp at
/// the moment the marker was added plus an optional index into the transcript
/// turns so the reader can jump back to the exact turn later.
struct TranscriptMarker: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    let meetingID: UUID
    let timestamp: TimeInterval
    let label: String
    let createdAt: Date
    let transcriptTurnIndex: Int?
}

/// Per-meeting marker storage backed by UserDefaults JSON.
///
/// Each meeting owns a single key, `"transcript-markers-{uuid}"`, holding the
/// encoded `[TranscriptMarker]` array. The store is the UI's single source of
/// truth for marker state: it publishes on every mutation so bookmark icons and
/// the reader's marker list stay in sync without a manual refresh.
///
/// UserDefaults is documented thread-safe; mutations are short and
/// non-reentrant, so the store is `@unchecked Sendable` (matching
/// `PinnedSegmentsStore`) rather than `@MainActor`-isolated — the recording
/// session (which is `@MainActor`) and the reader both call it directly.
final class TranscriptMarkerStore: ObservableObject, @unchecked Sendable {
    static let shared = TranscriptMarkerStore()

    private let defaults: UserDefaults
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Reads

    /// All markers for a meeting, sorted by timestamp (oldest first).
    func markers(for meetingID: UUID) -> [TranscriptMarker] {
        guard let data = defaults.data(forKey: Self.key(for: meetingID)) else { return [] }
        guard let markers = try? decoder.decode([TranscriptMarker].self, from: data) else { return [] }
        return markers.sorted { $0.timestamp < $1.timestamp }
    }

    /// True if a marker exists for this meeting within `tolerance` seconds of
    /// `timestamp`. Used by the reader to badge turns that carry a bookmark.
    func isMarked(meetingID: UUID, timestamp: TimeInterval, tolerance: TimeInterval = 1.0) -> Bool {
        markers(for: meetingID).contains { abs($0.timestamp - timestamp) <= tolerance }
    }

    // MARK: - Writes

    /// Add a marker at `timestamp` with a `label`. `turnIndex` optionally links
    /// the marker to a specific transcript turn for later scrolling.
    func add(
        meetingID: UUID,
        timestamp: TimeInterval,
        label: String,
        turnIndex: Int? = nil
    ) {
        var current = markers(for: meetingID)
        current.append(
            TranscriptMarker(
                meetingID: meetingID,
                timestamp: timestamp,
                label: label,
                createdAt: Date(),
                transcriptTurnIndex: turnIndex))
        persist(current, for: meetingID)
    }

    /// Remove a marker by id. No-op if not present for this meeting.
    func remove(id: UUID, meetingID: UUID) {
        var current = markers(for: meetingID)
        guard let i = current.firstIndex(where: { $0.id == id }) else { return }
        current.remove(at: i)
        persist(current, for: meetingID)
    }

    /// Remove every marker for a meeting.
    func clear(meetingID: UUID) {
        guard !markers(for: meetingID).isEmpty else { return }
        persist([], for: meetingID)
    }

    // MARK: - Private

    private func persist(_ markers: [TranscriptMarker], for meetingID: UUID) {
        guard let data = try? encoder.encode(markers) else { return }
        defaults.set(data, forKey: Self.key(for: meetingID))
        objectWillChange.send()
    }

    static func key(for meetingID: UUID) -> String {
        "transcript-markers-\(meetingID.uuidString)"
    }
}
