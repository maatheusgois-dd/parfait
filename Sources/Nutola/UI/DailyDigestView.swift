import SwiftUI

/// A beautiful, useful Daily Digest page accessible from the sidebar.
/// Shows a "Start Digest" button that generates a briefing of today's
/// meetings so far, action items, and upcoming agenda items.
struct DailyDigestView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var digest: DailyDigest?
    @State private var isGenerating = false
    @State private var digestMode: DigestMode = .today

    private let generator = DailyDigestGenerator()

    enum DigestMode: String, CaseIterable, Identifiable {
        case today = "Today so far"
        case yesterday = "Yesterday"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                modePicker
                if let digest {
                    digestContent(digest)
                } else {
                    emptyState
                }
            }
            .padding(24)
            .contentColumn()
        }
        .background(Theme.surface(scheme))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Daily Digest")
                .font(.nutola(22, .bold))
                .foregroundStyle(Theme.heading(scheme))
            Text("Get a quick briefing of your meetings and action items.")
                .font(.nutola(13))
                .foregroundStyle(Theme.secondary(scheme))
        }
    }

    // MARK: - Mode picker + Start button

    private var modePicker: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $digestMode) {
                ForEach(DigestMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Spacer()

            Button {
                generateDigest()
            } label: {
                Label(isGenerating ? "Generating…" : "Start Digest",
                      systemImage: isGenerating ? "arrow.clockwise" : "play.fill")
                    .font(.nutola(13, .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.mint(scheme))
            .clipShape(Capsule())
            .disabled(isGenerating)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.tertiary(scheme))
            Text("No digest generated yet")
                .font(.nutola(14, .semibold))
                .foregroundStyle(Theme.secondary(scheme))
            Text("Click **Start Digest** to get a summary of your \(digestMode == .today ? "day so far" : "yesterday").")
                .font(.nutola(12))
                .foregroundStyle(Theme.tertiary(scheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Digest content

    private func digestContent(_ digest: DailyDigest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Meetings summary card
            if digest.yesterdayMeetings.isEmpty {
                noMeetingsCard
            } else {
                meetingsCard(digest)
            }

            // Action items card
            if !digest.actionItems.isEmpty {
                actionItemsCard(digest)
            }

            // Today's agenda card
            if !digest.todayAgenda.isEmpty {
                agendaCard(digest)
            }

            // Copy button
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(generator.formatDigest(digest), forType: .string)
                } label: {
                    Label("Copy Digest", systemImage: "doc.on.doc")
                        .font(.nutola(12, .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var noMeetingsCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.tertiary(scheme))
            Text("No meetings \(digestMode == .today ? "today" : "yesterday")")
                .font(.nutola(13, .semibold))
                .foregroundStyle(Theme.secondary(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func meetingsCard(_ digest: DailyDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.2.fill")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(Theme.blueberry(scheme))
                Text("\(digest.yesterdayMeetings.count) meetings \(digestMode == .today ? "today" : "yesterday")")
                    .font(.nutola(14, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
            }
            ForEach(digest.yesterdayMeetings, id: \.id) { meeting in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Theme.mint(scheme))
                    Text(meeting.title)
                        .font(.nutola(12, .medium))
                        .foregroundStyle(Theme.heading(scheme))
                        .lineLimit(1)
                    Spacer()
                    Text(RelativeTimeFormatter.naturalRelative(to: meeting.createdAt))
                        .font(.nutola(10))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func actionItemsCard(_ digest: DailyDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checklist")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(Theme.honey(scheme))
                Text("\(digest.actionItems.count) action items")
                    .font(.nutola(14, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
            }
            ForEach(digest.actionItems, id: \.id) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                        .font(.nutola(12))
                        .foregroundStyle(item.isChecked ? Theme.mint(scheme) : Theme.tertiary(scheme))
                    Text(item.text)
                        .font(.nutola(12))
                        .foregroundStyle(Theme.heading(scheme))
                        .lineLimit(2)
                    if let owner = item.owner {
                        Text(owner)
                            .font(.nutola(10, .semibold))
                            .foregroundStyle(Theme.blueberry(scheme))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.blueberry(scheme).opacity(0.12), in: Capsule())
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func agendaCard(_ digest: DailyDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "calendar")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(Theme.mint(scheme))
                Text(digestMode == .today ? "Upcoming" : "Today's Agenda")
                    .font(.nutola(14, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
            }
            ForEach(digest.todayAgenda.filter { $0.start >= Date() }, id: \.rowID) { event in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(event.calendarColor.swiftUIColor)
                    Text(event.title)
                        .font(.nutola(12, .medium))
                        .foregroundStyle(Theme.heading(scheme))
                        .lineLimit(1)
                    Spacer()
                    Text(CalendarTimeFormatter.timeRange(start: event.start, end: event.end))
                        .font(.nutola(10))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Generation

    private func generateDigest() {
        isGenerating = true
        let meetings = app.store.meetings
        let agenda = app.calendar.upcomingDays(limit: 10).flatMap(\.events)
        let summaries = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, app.store.summary(for: $0.id)) })

        let result: DailyDigest
        switch digestMode {
        case .today:
            result = generator.generateToday(for: Date(), meetings: meetings, agenda: agenda, summaries: summaries)
        case .yesterday:
            result = generator.generate(for: Date(), meetings: meetings, agenda: agenda, summaries: summaries)
        }
        digest = result
        isGenerating = false
    }
}
