import SwiftUI

/// Compact talk-time breakdown shown in the Transcript tab header.
///
/// Renders one chip per speaker ("Alice 45% · Bob 30% · You 25%"); tapping the
/// row opens a popover with talk time, word count, and segment counts. Hidden
/// when there are no segments or a single speaker (no split to show).
struct TalkTimeStatsBar: View {
    let stats: [SpeakerStats]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    var body: some View {
        if stats.count >= 2 {
            Group {
                talkTimeChips
                    .popover(isPresented: $showDetail, arrowEdge: .top) {
                        detail
                    }
            }
            // #20 — click target in addition to hover, with a disclosure
            // chevron so the popover is discoverable as tappable.
            .onTapGesture { showDetail.toggle() }
            .onHover { hovering in
                if hovering { showDetail = true }
            }
            .onExitCommand { showDetail = false }
        }
    }

    @State private var showDetail = false

    private var talkTimeChips: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary(scheme))
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 {
                    Text("·")
                        .font(.nutola(11))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                HStack(spacing: 3) {
                    Circle()
                        .fill(swatch(for: stat, at: index))
                        .frame(width: 6, height: 6)
                    Text(stat.name)
                        .font(.nutola(11))
                        .foregroundStyle(Theme.secondary(scheme))
                    Text(percentageLabel(stat))
                        .font(.nutola(11, .medium))
                        .foregroundStyle(scheme == .dark ? .primary : Theme.cocoa)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(stat.name) \(percentageLabel(stat))")
                .accessibilityValue(detailLine(stat))
            }
            // #20 — disclosure chevron that flips when the popover is open.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiary(scheme))
                .rotationEffect(.degrees(showDetail ? 90 : 0))
                .animation(.easeOut(duration: 0.15), value: showDetail)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .help("Talk time per speaker — click or hover for details")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Talk time")
                .font(.nutola(13, .semibold))
                .foregroundStyle(Theme.tertiary(scheme))
            Divider()
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                HStack {
                    // #19 — use the per-speaker swatch color (matching the chips)
                    // so the legend circles are identifiable by more than position.
                    Circle()
                        .fill(swatch(for: stat, at: index))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stat.name)
                            .font(.nutola(12, .medium))
                        Text(detailLine(stat))
                            .font(.nutola(10))
                            .foregroundStyle(Theme.tertiary(scheme))
                    }
                    Spacer()
                    Text(percentageLabel(stat))
                        .font(.nutola(12, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(scheme == .dark ? .primary : Theme.cocoa)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(.regularMaterial)
    }

    // MARK: - Formatting

    private func percentageLabel(_ stat: SpeakerStats) -> String {
        let n = Self.percentFormatter.string(from: NSNumber(value: stat.percentage)) ?? "\(Int(stat.percentage.rounded()))"
        return n + "%"
    }

    private func detailLine(_ stat: SpeakerStats) -> String {
        let time = Self.durationFormatter.string(from: stat.talkTime) ?? stat.talkTime.formatted()
        let words = stat.wordCount == 1 ? "1 word" : "\(stat.wordCount) words"
        let segs = stat.segmentCount == 1 ? "1 segment" : "\(stat.segmentCount) segments"
        return "\(time) · \(words) · \(segs)"
    }

    /// Per-speaker color swatch: "me" uses blueberry, remote speakers cycle the
    /// dessert palette by first-seen order — mirroring TranscriptTurnBuilder's
    /// speaker-color convention so the chips match the transcript cards.
    private func swatch(for stat: SpeakerStats, at index: Int) -> Color {
        // "me" is always blueberry; remote speakers cycle the palette.
        if stat.speakerID == "me" {
            return Theme.blueberry(scheme)
        }
        let palette: [Color] = [
            Theme.raspberry, Theme.honey, Theme.mint, Theme.blueberry,
        ]
        return palette[index % palette.count]
    }

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.maximumFractionDigits = 0
        f.roundingMode = .halfEven
        return f
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.minute, .second]
        f.unitsStyle = .abbreviated
        f.zeroFormattingBehavior = .dropAll
        return f
    }()
}
