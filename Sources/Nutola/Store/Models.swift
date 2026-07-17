import Foundation

/// One utterance in a meeting transcript. Times are seconds from recording start.
struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var speakerID: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct Speaker: Codable, Identifiable, Equatable, Sendable {
    /// Stable key referenced by TranscriptSegment.speakerID ("me", "s1", "s2", …).
    var id: String
    /// Display name, user-editable ("Me", "Speaker 1", "Alice").
    var name: String
    var isMe: Bool = false
}

enum MeetingState: String, Codable, Sendable {
    /// Created from an upcoming calendar event — notes can be prepped before recording.
    case prep
    case recording
    case processing
    case ready
    case failed
}

struct Meeting: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var duration: TimeInterval = 0
    /// App that triggered detection (e.g. "zoom.us"), if auto-detected.
    var sourceApp: String?
    var calendarEventTitle: String?
    var calendarEventID: String?
    var calendarEventStart: Date?
    var calendarEventEnd: Date?
    /// Attendee names from the matched calendar event.
    var attendees: [String] = []
    var speakers: [Speaker] = []
    var state: MeetingState = .recording
    var templateName: String?
    /// Human-readable reason when state == .failed, or a non-fatal warning otherwise.
    var notice: String?
    var publishedURL: String?
    /// Which engine produced the summary: "apple", "claude", or "codex".
    var summaryProvider: String?
    /// User-assigned folder; nil = unfiled (flat Meetings list).
    var folderID: UUID?
    /// Transcript remote speakers were labeled from Zoom active-speaker events.
    var platformSpeakerAttribution: Bool = false
}

struct MeetingFolder: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var description: String?
    var createdAt: Date
    var sortOrder: Int = 0
    var iconKind: FolderIconKind = .symbol
    /// SF Symbol name when `iconKind == .symbol`, emoji character when `.emoji`.
    var iconValue: String = "folder.fill"
    var iconColorHex: String = "#3FB27F"
}

enum FolderIconKind: String, Codable, Sendable {
    case symbol
    case emoji
}

/// Persisted mapping for auto-filing. Key is normalized calendar title.
struct FolderTitleRule: Codable, Equatable, Sendable {
    var normalizedTitle: String
    var folderID: UUID
    var updatedAt: Date
}

extension Meeting {
    static func placeholderTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE h:mm a"
        return "Meeting · \(f.string(from: date))"
    }

    /// Whether the user can pick up recording on this meeting again — after a failed
    /// capture, an empty finish, or to append more audio to an existing meeting.
    func canStartFromPrep(isRecording: Bool) -> Bool {
        guard !isRecording else { return false }
        return state == .prep
    }

    func canContinueRecording(isRecording: Bool) -> Bool {
        guard !isRecording else { return false }
        guard state != .recording, state != .processing, state != .prep else { return false }
        return state == .failed || state == .ready
    }

    /// Whether auto-detection should append to this meeting instead of creating a new one.
    func canResumeRecording(isRecording: Bool) -> Bool {
        canStartFromPrep(isRecording: isRecording) || canContinueRecording(isRecording: isRecording)
    }

    /// Human-readable source for list subtitles (bundle IDs → app names).
    var displaySourceApp: String? {
        guard let raw = sourceApp?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains("granola") { return "Granola" }
        if raw.contains("zoom") { return "Zoom" }
        if raw.contains("teams") { return "Microsoft Teams" }
        if raw.contains("meet") || raw.contains("google") { return "Google Meet" }
        if raw.contains("webex") { return "Webex" }
        if raw.contains("slack") { return "Slack" }
        if raw.contains("facetime") { return "FaceTime" }
        return sourceApp
    }
}
