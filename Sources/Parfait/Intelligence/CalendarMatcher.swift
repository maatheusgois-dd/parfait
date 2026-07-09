import EventKit
import Foundation

/// Matches the in-progress calendar event so meetings can inherit its title and attendees.
enum CalendarMatcher {
    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var isDenied: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        // .writeOnly counts as denied: read APIs return zero events under it,
        // and re-requesting full access won't re-prompt.
        case .denied, .restricted, .writeOnly: return true
        default: return false
        }
    }

    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    static func currentEvent() async -> (title: String, attendees: [String])? {
        guard isAuthorized else { return nil }
        // events(matching:) is synchronous/blocking — keep it off the main actor.
        // Fresh store per call: stores created before access was granted keep returning nothing.
        return await Task.detached { () -> (title: String, attendees: [String])? in
            let store = EKEventStore()
            let now = Date()
            // Predicate matches events OVERLAPPING the window; the wide start catches
            // long-running meetings, then we filter to truly in-progress ones.
            let predicate = store.predicateForEvents(
                withStart: now.addingTimeInterval(-4 * 3600),
                end: now.addingTimeInterval(60),
                calendars: nil)

            let event = store.events(matching: predicate)
                .filter { !$0.isAllDay && $0.startDate <= now && now < $0.endDate }
                .max { $0.startDate < $1.startDate }
            guard let event else { return nil }

            let attendees = (event.attendees ?? [])
                .filter { !$0.isCurrentUser }
                .compactMap { participant -> String? in
                    if let name = participant.name, !name.isEmpty { return name }
                    // EKParticipant has no email property; it lives in the mailto: url.
                    let s = participant.url.absoluteString
                    return s.hasPrefix("mailto:") ? String(s.dropFirst(7)) : s
                }
            return (event.title ?? "Untitled event", attendees)
        }.value
    }
}
