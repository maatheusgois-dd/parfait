import Foundation
import SwiftUI

/// UserDefaults-backed settings. Keys are shared with @AppStorage in Settings UI.
enum SettingsKey {
    static let autoRecord = "autoRecord"                    // start recording on detection (vs. just show the prompt card)
    static let detectMeetings = "detectMeetings"            // watch for mic activity at all
    static let identifySpeakers = "identifySpeakers"        // run on-device diarization
    static let useCalendar = "useCalendar"                  // match calendar events for titles/attendees
    static let upcomingCountdownHours = "upcomingCountdownHours" // show "in 52m" when next event is within this window
    static let showUpcomingInMenuBar = "showUpcomingInMenuBar"   // menu-bar countdown + coming-up strip
    static let showEventsWithoutParticipants = "showEventsWithoutParticipants"
    static let disabledCalendarIDs = "disabledCalendarIDs"       // empty = all calendars visible
    static let defaultTemplate = "defaultTemplate"
    static let ignoredBundleIDs = "ignoredBundleIDs"        // apps that never count as meetings
    static let autoStopRecording = "autoStopRecording"      // stop ~8s after the meeting app releases the mic
    static let didCompleteOnboarding = "didCompleteOnboarding" // first-run walkthrough finished
    static let systemAudioConfirmed = "systemAudioConfirmed"   // tap has captured real (non-silent) audio at least once
    static let preferClaudeSummaries = "preferClaudeSummaries" // prefer cloud AI for summaries first (vs. Apple-first)
    static let preferredAIProvider = "preferredAIProvider"     // apple | claude | codex
    static let askDeliveryMode = "askDeliveryMode"             // cli | app
    static let askMaxTurns = "askMaxTurns"                     // MCP tool rounds for CLI ask
    static let appearanceMode = "appearanceMode"               // system | light | dark
    static let actionColorHex = "actionColorHex"               // prominent buttons (Record, Save, …)
    static let recordingCardOriginX = "recordingCardOriginX"   // last user-placed floating card origin
    static let recordingCardOriginY = "recordingCardOriginY"
    static let showLiveRecordingCard = "showLiveRecordingCard" // floating live transcript widget
    static let openMainWindowAtLaunch = "openMainWindowAtLaunch" // show main window on launch (vs. menu bar only)
    static let sideNotesPanelWidth = "sideNotesPanelWidth"
    static let transcriptionModel = "transcriptionModel" // apple | parakeetStreaming | parakeetBatch | nemotron
    static let developerMode = "developerMode"                 // show Debug settings tab
    static let crashDiagnostics = "crashDiagnostics"           // write a scrubbed diagnostic on crash (opt-in)
}

enum AppearanceMode: String, CaseIterable, Identifiable, Hashable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AIProvider: String, CaseIterable, Identifiable, Hashable {
    case apple
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var isCloud: Bool { self != .apple }

    /// Assistants that can answer questions about meetings in-app.
    static let askChoices: [AIProvider] = [.apple, .claude, .codex]

    var isAvailableForSummary: Bool {
        switch self {
        case .apple: AppleSummarizer.isAvailable
        case .claude: ClaudeCLI.isInstalled && ClaudeCLI.isLoggedIn()
        case .codex: CodexCLI.isReady
        }
    }
}

enum AskDeliveryMode: String, CaseIterable, Identifiable, Hashable {
    case cli
    case app

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cli: "Answer here"
        case .app: "Open in app"
        }
    }

    var detail: String {
        switch self {
        case .cli: "Runs the CLI in the background and shows the answer in Nutola."
        case .app: "Opens Claude Desktop or Codex with a pre-filled prompt."
        }
    }
}

enum AppSettings {
    static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.autoRecord: false,
            SettingsKey.detectMeetings: true,
            SettingsKey.identifySpeakers: true,
            SettingsKey.useCalendar: true,
            SettingsKey.upcomingCountdownHours: 3.0,
            SettingsKey.showUpcomingInMenuBar: true,
            SettingsKey.showEventsWithoutParticipants: true,
            SettingsKey.defaultTemplate: "Meeting Notes",
            SettingsKey.ignoredBundleIDs: defaultIgnoredBundleIDs,
            SettingsKey.autoStopRecording: true,
            SettingsKey.didCompleteOnboarding: false,
            SettingsKey.systemAudioConfirmed: false,
            SettingsKey.preferClaudeSummaries: false,
            SettingsKey.preferredAIProvider: AIProvider.apple.rawValue,
            SettingsKey.askDeliveryMode: AskDeliveryMode.cli.rawValue,
            SettingsKey.askMaxTurns: 5,
            SettingsKey.transcriptionModel: TranscriptionModel.apple.rawValue,
            SettingsKey.actionColorHex: Theme.defaultActionColorHex,
            SettingsKey.showLiveRecordingCard: true,
            SettingsKey.openMainWindowAtLaunch: true,
            SettingsKey.sideNotesPanelWidth: 280.0,
            SettingsKey.developerMode: false,
            SettingsKey.crashDiagnostics: false,
        ])
    }

    /// Apps whose mic use is never a meeting: voice assistants, dictation-ish utilities, ourselves.
    static let defaultIgnoredBundleIDs: [String] = [
        "com.apple.Siri",
        "com.apple.SiriNCService",
        "com.apple.VoiceMemos",
        "com.apple.controlcenter",
    ]

    static var autoRecord: Bool { defaults.bool(forKey: SettingsKey.autoRecord) }
    static var detectMeetings: Bool { defaults.bool(forKey: SettingsKey.detectMeetings) }
    static var identifySpeakers: Bool { defaults.bool(forKey: SettingsKey.identifySpeakers) }
    static var useCalendar: Bool { defaults.bool(forKey: SettingsKey.useCalendar) }
    static var upcomingCountdownHours: Double {
        let value = defaults.double(forKey: SettingsKey.upcomingCountdownHours)
        return value > 0 ? value : 3.0
    }
    static var showUpcomingInMenuBar: Bool { defaults.bool(forKey: SettingsKey.showUpcomingInMenuBar) }
    static var showEventsWithoutParticipants: Bool {
        defaults.bool(forKey: SettingsKey.showEventsWithoutParticipants)
    }
    static var disabledCalendarIDs: Set<String> {
        Set(defaults.stringArray(forKey: SettingsKey.disabledCalendarIDs) ?? [])
    }
    static func setCalendarEnabled(id: String, enabled: Bool) {
        var disabled = disabledCalendarIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(Array(disabled).sorted(), forKey: SettingsKey.disabledCalendarIDs)
    }
    static func resetCalendarSelection() {
        defaults.removeObject(forKey: SettingsKey.disabledCalendarIDs)
    }
    static func isCalendarEnabled(id: String) -> Bool {
        !disabledCalendarIDs.contains(id)
    }
    static var defaultTemplate: String {
        defaults.string(forKey: SettingsKey.defaultTemplate) ?? "Meeting Notes"
    }
    static var ignoredBundleIDs: [String] {
        defaults.stringArray(forKey: SettingsKey.ignoredBundleIDs) ?? defaultIgnoredBundleIDs
    }
    static var autoStopRecording: Bool { defaults.bool(forKey: SettingsKey.autoStopRecording) }
    static var didCompleteOnboarding: Bool { defaults.bool(forKey: SettingsKey.didCompleteOnboarding) }
    static var systemAudioConfirmed: Bool { defaults.bool(forKey: SettingsKey.systemAudioConfirmed) }
    static func markSystemAudioConfirmed() { defaults.set(true, forKey: SettingsKey.systemAudioConfirmed) }
    static var preferClaudeSummaries: Bool { defaults.bool(forKey: SettingsKey.preferClaudeSummaries) }
    static var preferredAIProvider: AIProvider {
        AIProvider(rawValue: defaults.string(forKey: SettingsKey.preferredAIProvider) ?? "") ?? .apple
    }
    static var askDeliveryMode: AskDeliveryMode {
        AskDeliveryMode(rawValue: defaults.string(forKey: SettingsKey.askDeliveryMode) ?? "") ?? .cli
    }
    static var askMaxTurns: Int {
        let value = defaults.integer(forKey: SettingsKey.askMaxTurns)
        return (3...15).contains(value) ? value : 5
    }
    static var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: defaults.string(forKey: SettingsKey.appearanceMode) ?? "") ?? .system
    }
    static var actionColorHex: String {
        defaults.string(forKey: SettingsKey.actionColorHex) ?? Theme.defaultActionColorHex
    }
    static var showLiveRecordingCard: Bool {
        defaults.bool(forKey: SettingsKey.showLiveRecordingCard)
    }
    static var openMainWindowAtLaunch: Bool {
        defaults.bool(forKey: SettingsKey.openMainWindowAtLaunch)
    }
    static var developerMode: Bool {
        defaults.bool(forKey: SettingsKey.developerMode)
    }
    static var crashDiagnostics: Bool {
        defaults.bool(forKey: SettingsKey.crashDiagnostics)
    }
    static var transcriptionModel: TranscriptionModel {
        TranscriptionModel(rawValue: defaults.string(forKey: SettingsKey.transcriptionModel) ?? "")
            ?? .apple
    }
}
