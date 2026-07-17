import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so Nutola can register itself as a login item —
/// it launches straight into the menu bar (LSUIElement) at login. macOS persists
/// the registration itself, so there's no UserDefaults key; the toggle reflects
/// the live service status.
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// True once macOS has fully enabled the login item.
    static var isEnabled: Bool { status == .enabled }

    /// The user previously disabled Nutola in System Settings → Login Items, so a
    /// fresh register lands here until they re-approve it there.
    static var requiresApproval: Bool { status == .requiresApproval }

    /// Reflects the user's intent (enabled, or enabled-pending-approval).
    static var isOn: Bool { status == .enabled || status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if status == .enabled { try SMAppService.mainApp.unregister() }
        }
    }
}
