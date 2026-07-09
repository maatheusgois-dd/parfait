import AppKit
import SwiftUI

struct ParfaitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var app = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
        } label: {
            MenuBarLabel(isRecording: app.isRecording)
        }
        .menuBarExtraStyle(.window)

        Window("Parfait", id: "main") {
            MainWindowView()
                .environmentObject(app)
        }
        .defaultSize(width: 980, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppState.shared.bootstrap() }
    }
}

struct MenuBarLabel: View {
    let isRecording: Bool

    var body: some View {
        if isRecording {
            Image(systemName: "record.circle.fill")
        } else if let icon = Self.templateIcon {
            Image(nsImage: icon)
        } else {
            Image(systemName: "cup.and.saucer.fill")
        }
    }

    static let templateIcon: NSImage? = {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
