import EventKit
import Foundation

enum AttendeeExtractor {
    static func names(from event: EKEvent) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for participant in event.attendees ?? [] where !participant.isCurrentUser {
            let name = displayName(for: participant)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
    }

    private static func displayName(for participant: EKParticipant) -> String {
        if let name = participant.name, !name.isEmpty { return name }
        let s = participant.url.absoluteString
        if s.hasPrefix("mailto:") { return String(s.dropFirst(7)) }
        return s
    }
}

enum ConferenceURLParser {
    private static let patterns = [
        #"https?://[\w.-]*zoom\.us/[^\s<>"]+"#,
        #"https?://meet\.google\.com/[^\s<>"]+"#,
        #"https?://teams\.microsoft\.com/[^\s<>"]+"#,
        #"https?://[\w.-]*webex\.com/[^\s<>"]+"#,
    ]

    static func parse(in event: EKEvent) -> URL? {
        let haystack = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }
            .joined(separator: " ")
        for pattern in patterns {
            if let match = firstMatch(pattern: pattern, in: haystack),
               let url = URL(string: match) {
                return url
            }
        }
        return event.url
    }

    static func hostMatchesApp(_ url: URL?, sourceApp: String?) -> Bool {
        guard let url, let host = url.host?.lowercased(),
              let sourceApp = sourceApp?.lowercased(), !sourceApp.isEmpty else { return false }
        if sourceApp.contains("zoom") { return host.contains("zoom") }
        if sourceApp.contains("meet") || sourceApp.contains("google") { return host.contains("meet.google") }
        if sourceApp.contains("teams") || sourceApp.contains("microsoft") { return host.contains("teams") }
        if sourceApp.contains("webex") { return host.contains("webex") }
        return host.contains(sourceApp) || sourceApp.contains(host)
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
