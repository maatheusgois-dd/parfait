import SwiftUI

/// Compact 14-day bar chart of token usage, sized to sit inside a Settings
/// `Section`. Each bar's height is proportional to that day's `totalTokens`
/// relative to the busiest day in the window; missing days render as zero-
/// height stubs so the 14-bar rhythm is always visible. A headline above the
/// chart shows the 14-day total; the day-of-month number sits under each bar.
struct TokenUsageChart: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var tracker: TokenUsageTracker

    /// Test/UI hook: render a specific snapshot rather than reading live state.
    init(tracker: TokenUsageTracker = .shared) {
        self.tracker = tracker
    }

    private var days: [DailyTokenUsage] { tracker.last14Days() }
    private var maxTokens: Int { days.map(\.totalTokens).max() ?? 0 }
    private var total: Int { tracker.totalForLast14Days() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            bars
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Token usage, last 14 days")
        .accessibilityValue("\(total) total tokens")
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Last 14 days")
                .font(.nutola(12, .medium))
            Spacer()
            Text(formatted(total) + " tokens")
                .font(.nutola(12, .medium))
                .foregroundStyle(Theme.mint(scheme))
        }
        .font(.nutola(12))
    }

    private var bars: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { day in
                    bar(for: day, availableHeight: height)
                }
            }
        }
        .frame(height: 96)
    }

    private func bar(for day: DailyTokenUsage, availableHeight: CGFloat) -> some View {
        let ratio = maxTokens > 0 ? CGFloat(day.totalTokens) / CGFloat(maxTokens) : 0
        let barHeight = max(availableHeight * ratio, day.totalTokens > 0 ? 2 : 0)
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.mint(scheme).opacity(day.totalTokens > 0 ? 1 : 0.25))
                .frame(height: barHeight)
            Text(dayLabel(day.date))
                .font(.nutola(9))
                .foregroundStyle(Theme.secondary(scheme))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.date): \(day.totalTokens) tokens")
    }

    /// Day-of-month number for the under-bar label (e.g. "17" for "2026-07-17").
    private func dayLabel(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard let day = parts.last else { return "" }
        return String(day)
    }

    /// Locale-aware grouping for the total — matches the rest of Nutola's
    /// NumberFormatter usage rather than `String(format:)`.
    private func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
