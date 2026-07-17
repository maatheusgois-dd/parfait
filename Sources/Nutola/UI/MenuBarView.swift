import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor
    @State private var showQuitConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let session = app.session {
                RecordingCard(session: session, meeting: app.recordingMeeting)
            } else if let detected = app.detectedAppName {
                detectionBanner(detected)
            } else {
                Button {
                    dismissMenu()
                    Task { await app.startRecording() }
                } label: {
                    Label("Start recording", systemImage: "record.circle")
                        .font(.nutola(14, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(actionColor)
            }
            if let error = app.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.nutola(11))
                    .foregroundStyle(.orange)
            }
            upcoming
            recent
            Divider()
            if showQuitConfirm {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quit Nutola?")
                        .font(.nutola(12, .semibold))
                        .foregroundStyle(Theme.heading(scheme))
                    Text(app.isRecording
                         ? "A recording is in progress."
                         : "Nutola will stop running in the background.")
                        .font(.nutola(10))
                        .foregroundStyle(Theme.secondary(scheme))
                    HStack {
                        Spacer()
                        Button("Cancel") { showQuitConfirm = false }
                            .controlSize(.small)
                        Button("Quit", role: .destructive) { NSApp.terminate(nil) }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            } else {
                HStack {
                    Button("Open Nutola") { openMain() }
                        .buttonStyle(.plain)
                        .font(.nutola(12, .medium))
                        .foregroundStyle(Theme.blueberry)
                    Spacer()
                    Button {
                        showQuitConfirm = true
                    } label: {
                        Image(systemName: "power")
                            .font(.nutola(13, .medium))
                            .foregroundStyle(.red)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Quit Nutola")
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(MenuBarExtraWindowHook())
        .task {
            app.reconcileRecordingState()
            await app.calendar.refreshAgenda()
        }
    }

    private var upcomingDays: [UpcomingMeetingsDay] {
        app.calendar.upcomingDays(limit: UpcomingMeetings.defaultLimit)
    }

    private var upcoming: some View {
        Group {
            if AppSettings.useCalendar, CalendarAuthorization.isAuthorized, !upcomingDays.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Coming up")
                        .font(.nutola(11, .semibold))
                        .foregroundStyle(.secondary)

                    if let first = upcomingDays.first?.events.first {
                        if first.isInProgress, let endsIn = app.calendar.endsInText(for: first) {
                            Text("Ends \(endsIn)")
                                .font(.nutola(11, .semibold))
                                .foregroundStyle(.secondary)
                        } else if let startsIn = app.calendar.startsInText(for: first) {
                            Text("Starts \(startsIn)")
                                .font(.nutola(11, .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Plain VStack — ScrollView collapses to zero height inside MenuBarExtra panels.
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(upcomingDays) { day in
                            VStack(alignment: .leading, spacing: 2) {
                                if day.label != "Today" {
                                    Text(day.label)
                                        .font(.nutola(11, .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, day.id == upcomingDays.first?.id ? 0 : 4)
                                }
                                ForEach(day.events, id: \.rowID) { event in
                                    upcomingRow(event, peers: day.events)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func upcomingRow(_ event: CalendarEventSummary, peers: [CalendarEventSummary]) -> some View {
        let showJoin = event.shouldShowJoinButton(among: peers)
        return HStack(alignment: .top, spacing: 6) {
            Button {
                dismissMenu()
                app.openCalendarEvent(event)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.nutola(12, .medium))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let countdown = app.calendar.countdownText(for: event) {
                                Text(countdown)
                                    .font(.nutola(10, .semibold))
                                    .foregroundStyle(event.isInProgress ? Theme.mint(scheme) : Theme.honey(scheme))
                            }
                            Text(CalendarTimeFormatter.timeRange(start: event.start, end: event.end))
                                .font(.nutola(10))
                                .foregroundStyle(Theme.secondary(scheme))
                        }
                        if let location = event.location {
                            Text(location)
                                .font(.nutola(9))
                                .foregroundStyle(Theme.tertiary(scheme))
                                .lineLimit(1)
                        }
                    }
                    .calendarEventIndicator(event.calendarColor.swiftUIColor)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .disabled(app.isRecording || event.isPast())

            if showJoin, let url = event.conferenceURL {
                ConferenceJoinButton(label: event.joinLabel, url: url)
            } else if event.conferenceURL != nil {
                ConferenceVideoIcon()
                    .padding(.top, 1)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            NutolaStripes().scaleEffect(0.45).frame(width: 20, height: 26)
            Text("Nutola")
                .font(.nutola(16, .bold))
                .foregroundStyle(Theme.heading(scheme))
            Spacer()
            Button {
                dismissMenu()
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func detectionBanner(_ appName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(appName) is using the microphone", systemImage: "waveform.badge.mic")
                .font(.nutola(12, .semibold))
            HStack {
                Button {
                    dismissMenu()
                    Task { await app.acceptDetection() }
                } label: {
                    Text("Record meeting").font(.nutola(12, .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(actionColor)
                Button("Dismiss") { app.dismissDetection() }
                    .buttonStyle(.bordered)
                    .font(.nutola(12))
            }
        }
        .cardStyle()
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !app.store.meetings.isEmpty {
                Text("Recent")
                    .font(.nutola(11, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            ForEach(app.store.meetings.prefix(4)) { meeting in
                Button {
                    app.openMeetingID = meeting.id
                    openMain()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.title)
                                .font(.nutola(12, .medium))
                                .lineLimit(1)
                            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.nutola(10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StateBadge(meeting: meeting, stage: app.processingStage[meeting.id])
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }

    private func dismissMenu() {
        MenuBarExtraPanel.dismiss()
    }

    private func openMain() {
        dismissMenu()
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// SwiftUI's MenuBarExtra(.window) has no dismiss API — capture the panel and order it out.
private enum MenuBarExtraPanel {
    private static weak var window: NSWindow?

    static func dismiss() {
        window?.orderOut(nil)
    }

    static func bind(_ window: NSWindow?) {
        Self.window = window
    }
}

private struct MenuBarExtraWindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> HookView { HookView() }
    func updateNSView(_ nsView: HookView, context: Context) {}

    final class HookView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MenuBarExtraPanel.bind(window)
        }
    }
}

private struct RecordingCard: View {
    @ObservedObject var session: RecordingSession
    let meeting: Meeting?
    @EnvironmentObject private var app: AppState
    @Environment(\.nutolaActionColor) private var actionColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RecordDot()
                Text(meeting?.title ?? "Recording")
                    .font(.nutola(13, .semibold))
                    .lineLimit(1)
                Spacer()
                Text(timeString(session.elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(actionColor)
            }
            HStack(alignment: .bottom) {
                LevelMeter(levels: session.micBarLevels)
                Spacer()
                if !session.systemStarted {
                    Text("mic only")
                        .font(.nutola(10))
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Button {
                    Task { await app.stopRecording() }
                } label: {
                    Label("Stop & summarize", systemImage: "stop.fill")
                        .font(.nutola(12, .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(actionColor)
                Button {
                    app.discardRecording()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Discard this recording")
            }
            if app.showLiveRecordingCard, app.recordingCardDismissed {
                Button {
                    app.recordingCardDismissed = false
                } label: {
                    Label("Show live transcript card", systemImage: "rectangle.on.rectangle")
                        .font(.nutola(11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.blueberry)
            } else if app.showLiveRecordingCard, app.recordingCardMinimized {
                Button {
                    app.recordingCardMinimized = false
                } label: {
                    Label("Expand live transcript card", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.nutola(11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.blueberry)
            }
        }
        .cardStyle()
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
