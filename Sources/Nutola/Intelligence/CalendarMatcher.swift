import Foundation

/// Backward-compatible shim — prefer `CalendarStore` for new code.
enum CalendarMatcher {
    static var isAuthorized: Bool { CalendarAuthorization.isAuthorized }
    static var isDenied: Bool { CalendarAuthorization.isDenied }
    static func requestAccess() async -> Bool { await CalendarAuthorization.requestAccess() }

    static func currentEvent() async -> (title: String, attendees: [String])? {
        await CalendarStore().currentEvent(at: .now, sourceApp: nil).map { ($0.title, $0.attendees) }
    }
}
