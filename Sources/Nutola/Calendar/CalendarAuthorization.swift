import EventKit
import Foundation

enum CalendarAuthorization {
    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var isDenied: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied, .restricted, .writeOnly: return true
        default: return false
        }
    }

    static func requestAccess() async -> Bool {
        do {
            return try await EKEventStore().requestFullAccessToEvents()
        } catch {
            // Surface the underlying error instead of silently returning false, so
            // a denied-but-not-user-denied state (corrupted store, etc.) is debuggable.
            NutolaConsoleLog.calendar("calendar access request failed — \(error.localizedDescription)")
            return false
        }
    }
}
