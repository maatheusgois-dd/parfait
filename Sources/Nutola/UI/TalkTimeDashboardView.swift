import SwiftUI

/// Cross-meeting talk-time dashboard: a ranked list of who talks the most across
/// all meetings in a period, with a compact bar chart and per-speaker totals.
///
/// Designed to embed as a section inside `MeetingInsightsView` (or any insights
/// surface) and to stand on its own. It is fed by `TalkTimeAggregator`; the
/// transcript/speaker data is resolved from a `MeetingStore` so the view stays
/// free of store-coupling details and easy to preview/test.
struct TalkTimeDashboardView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme

    /// Meetings to aggregate across. Typically a filtered window (a week), but
    /// any slice works — empty input renders an empty state.
    let meetings: [Meeting]

    init(meetings: [Meeting]) {
        self.meetings = meetings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if summaries.isEmpty {
                emptyState
            } else {
                ForEach(summaries) { summary in
                    speakerRow(summary)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.mint(scheme))
            Text("Talk time")
                .font(.nutola(12, .semibold))
                .foregroundStyle(Theme.secondary(scheme))
            if !summaries.isEmpty {
                Spacer(minLength: 0)
                Text(grandTotalLabel)
                    .font(.nutola(11, .medium))
                    .foregroundStyle(Theme.tertiary(scheme))
            }
        }
    }

    private var grandTotalLabel: String {
        let total = summaries.reduce(0) { $0 + $1.totalTalkTime }
        return "\(summaries.count) speakers · \(Self.format(hours: total))"
    }

    // MARK: - Rows

    private func speakerRow(_ summary: SpeakerTalkTimeSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(summary.name)
                    .font(.nutola(13, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                    .lineLimit(1)
                meetingCountBadge(summary.meetingCount)
                Spacer(minLength: 0)
                Text(Self.format(hours: summary.totalTalkTime))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondary(scheme))
            }
            percentageBar(summary)
            HStack(spacing: 8) {
                Text(String(format: "%.0f%%", summary.percentageOfTotal))
                    .font(.nutola(10, .medium))
                    .foregroundStyle(Theme.tertiary(scheme))
                if summary.meetingCount > 1 {
                    Text("avg \(Self.format(hours: summary.avgTalkTimePerMeeting)) / meeting")
                        .font(.nutola(10))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: summary))
    }

    private func meetingCountBadge(_ count: Int) -> some View {
        Text(count == 1 ? "1 meeting" : "\(count) meetings")
            .font(.nutola(9, .semibold))
            .foregroundStyle(Theme.secondary(scheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.chip(scheme), in: Capsule())
    }

    private func percentageBar(_ summary: SpeakerTalkTimeSummary) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.chip(scheme))
                    .frame(height: 6)
                Capsule()
                    .fill(barColor(for: summary))
                    .frame(width: max(2, geo.size.width * CGFloat(summary.percentageOfTotal / 100)), height: 6)
            }
        }
        .frame(height: 6)
    }

    private func barColor(for summary: SpeakerTalkTimeSummary) -> Color {
        // Cycle through the Nutola palette so distinct speakers stay visually
        // distinct without depending on a stable per-speaker color map.
        let palette: [Color] = [
            Theme.mint(scheme),
            Theme.blueberry(scheme),
            Theme.honey(scheme),
            Theme.raspberry,
        ]
        let idx = summaries.firstIndex { $0.speakerID == summary.speakerID } ?? 0
        return palette[idx % palette.count]
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No talk time yet")
                .font(.nutola(12, .semibold))
                .foregroundStyle(Theme.tertiary(scheme))
            Text("Transcribe a meeting to see who talks the most.")
                .font(.nutola(11))
                .foregroundStyle(Theme.tertiary(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Aggregation

    private var summaries: [SpeakerTalkTimeSummary] {
        let transcripts = meetings.map { ($0.id, app.store.transcript(for: $0.id)) }
        let speakers = meetings.map { ($0.id, $0.speakers) }
        return TalkTimeAggregator.aggregate(
            meetings: meetings,
            transcripts: transcripts,
            speakers: speakers)
    }

    // MARK: - Formatting

    /// Formats a duration (in seconds) as compact `Xh Ym`, or just `Ym` under an
    /// hour, or `Xs` under a minute. Keeps the rows narrow.
    static func format(hours seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        if m > 0 {
            return s > 0 ? "\(m)m" : "\(m)m"
        }
        return "\(s)s"
    }

    private func accessibilityLabel(for summary: SpeakerTalkTimeSummary) -> String {
        var parts = [summary.name, Self.format(hours: summary.totalTalkTime)]
        parts.append("\(summary.meetingCount) \(summary.meetingCount == 1 ? "meeting" : "meetings")")
        parts.append(String(format: "%.0f percent of total talk time", summary.percentageOfTotal))
        if summary.meetingCount > 1 {
            parts.append("average \(Self.format(hours: summary.avgTalkTimePerMeeting)) per meeting")
        }
        return parts.joined(separator: ", ")
    }
}
