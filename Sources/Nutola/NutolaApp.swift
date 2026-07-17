import AppKit
import CoreServices
import SwiftUI

struct NutolaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var app = AppState.shared
    // Captured once at launch (not re-read live) so .defaultLaunchBehavior below
    // is a stable, one-time decision — see Window("onboarding") for why.
    private let showOnboardingAtLaunch = !AppSettings.didCompleteOnboarding
    private let openMainAtLaunch = AppSettings.didCompleteOnboarding && AppSettings.openMainWindowAtLaunch

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
                .nutolaAppearance()
        } label: {
            MenuBarLabel(
                detecting: app.detectedAppName != nil,
                nextEvent: menuBarNextEvent)
        }
        .menuBarExtraStyle(.window)

        Window("Nutola", id: "main") {
            MainWindowView()
                .environmentObject(app)
                .nutolaAppearance()
        }
        .defaultSize(width: 980, height: 640)
        .defaultLaunchBehavior(openMainAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Nutola") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "On-device meeting notes.\ngithub.com/conrad-vanl/nutola",
                            attributes: [.font: NSFont.systemFont(ofSize: 11)])
                    ])
                }
            }
        }

        Window("Welcome to Nutola", id: "onboarding") {
            OnboardingView()
                .environmentObject(app)
                .nutolaAppearance()
        }
        .defaultSize(width: 520, height: 640)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(showOnboardingAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environmentObject(app)
                .nutolaAppearance()
        }
    }

    private var menuBarNextEvent: MenuBarUpcomingEvent? {
        guard !app.isRecording, app.detectedAppName == nil,
              AppSettings.useCalendar, AppSettings.showUpcomingInMenuBar, CalendarAuthorization.isAuthorized,
              let event = app.calendar.nextUpcomingEvent,
              let countdown = app.calendar.countdownText(for: event) else { return nil }
        return MenuBarUpcomingEvent(title: event.title, countdown: countdown)
    }
}

struct MenuBarUpcomingEvent: Equatable {
    var title: String
    var countdown: String
}

enum MenuBarTitleTruncator {
    private static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 11, weight: .semibold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: 11) ?? base
    }()
    private static let separator = "•"
    private static let ellipsis = ".."
    private static let spacing: CGFloat = 4
    /// Total width budget for title + separator + countdown in the menu-bar slot.
    private static let textBudget: CGFloat = 148

    static func label(for event: MenuBarUpcomingEvent) -> String {
        let suffix = separator + event.countdown
        let titleBudget = max(textBudget - width(of: suffix) - spacing, 36)
        let title = truncate(event.title, maxWidth: titleBudget)
        return title + suffix
    }

    private static func truncate(_ title: String, maxWidth: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let full = title as NSString
        guard full.size(withAttributes: attrs).width > maxWidth else { return title }

        let ellipsisWidth = (ellipsis as NSString).size(withAttributes: attrs).width
        let budget = max(maxWidth - ellipsisWidth, 0)

        var lo = 0
        var hi = title.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let probe = full.substring(to: mid)
            if (probe as NSString).size(withAttributes: attrs).width <= budget {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return full.substring(to: lo) + ellipsis
    }

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []
    private var detectionPrompt: DetectionPromptController?
    private var recordingCard: RecordingCardController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerApplicationIconWithLaunchServices()
        Task { @MainActor in AppState.shared.bootstrap() }
        observeWindowsForMenuBar()
        // The floating "Record this meeting?" card on detection, and the live
        // recording card (transcript + Ask Claude live) while recording.
        MainActor.assumeIsolated {
            detectionPrompt = DetectionPromptController()
            recordingCard = RecordingCardController()
        }
    }

    /// Re-register the bundle so Notification Center picks up AppIcon.icns changes
    /// after rebuilds (LSUIElement apps cache the old glyph aggressively).
    private func registerApplicationIconWithLaunchServices() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
    }

    /// .accessory apps (LSUIElement) have no Dock icon *and no menu bar at all* —
    /// promote to .regular only while a real Nutola window (main/Settings, not the
    /// MenuBarExtra popover panel) is open, so "Nutola" shows top-left like a normal
    /// app; drop back to accessory the moment the last real window closes.
    private func observeWindowsForMenuBar() {
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, Self.isRealAppWindow(window) else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        })
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, Self.isRealAppWindow(closing) else { return }
            // isMiniaturized too: a minimized real window is still open, just not visible.
            let stillOpen = NSApp.windows.contains {
                $0 !== closing && ($0.isVisible || $0.isMiniaturized) && Self.isRealAppWindow($0)
            }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        })
    }

    /// Excludes the MenuBarExtra(.window)'s own backing window (an untitled,
    /// nonactivating NSPanel) — only "real" titled windows (main/Settings/onboarding) qualify.
    private static func isRealAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
    }

    /// Finalize in-flight audio files before quitting — an unclosed AAC file has
    /// no moov atom and would be unreadable on the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            AppState.shared.prepareForTermination()
        }
        return .terminateNow
    }
}

struct MenuBarLabel: View {
    /// A meeting-ish app grabbed the mic and we're waiting on the user to hit Record.
    /// Swap in an attention glyph so the prompt is visible in the menu bar even if the
    /// notification was missed, quieted, or denied outright.
    var detecting: Bool = false
    var nextEvent: MenuBarUpcomingEvent?

    var body: some View {
        if detecting {
            Image(systemName: "waveform.badge.exclamationmark")
        } else if let nextEvent {
            upcomingEventLabel(nextEvent)
        } else if let icon = Self.templateIcon {
            Image(nsImage: icon)
        } else {
            Image(systemName: "cup.and.saucer.fill")
        }
    }

    private func upcomingEventLabel(_ event: MenuBarUpcomingEvent) -> some View {
        HStack(spacing: 4) {
            if let icon = Self.templateIcon {
                Image(nsImage: icon)
            }
            Text(MenuBarTitleTruncator.label(for: event))
                .font(.nutola(11, .semibold))
                .lineLimit(1)
        }
        .fixedSize()
        .help(event.title)
    }

    static let templateIcon: NSImage? = {
        // Resolve the SPM resource bundle defensively. The generated `Bundle.module`
        // accessor only checks `Bundle.main.bundleURL` (the .app root) and a stale
        // build-time path, but `make app` ships the bundle under `Contents/Resources/`
        // (the canonical macOS location, exposed as `Bundle.main.resourceURL`). If
        // neither of the accessor's paths resolves — e.g. after a project rename or a
        // hand-assembled .app — it `fatalError`s at first menu-bar render and the app
        // can never relaunch. Look there ourselves before touching `Bundle.module`.
        let bundle: Bundle = {
            let name = "Nutola_Nutola"
            if let resourceURL = Bundle.main.resourceURL,
               let b = Bundle(url: resourceURL.appendingPathComponent("\(name).bundle"))
            { return b }
            return Bundle.module
        }()
        // Bundle image lookup pairs the @2x representation; NSImage(contentsOf:)
        // would load only the 1x bitmap and render blurry on Retina.
        guard let image = bundle.image(forResource: "NavIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
