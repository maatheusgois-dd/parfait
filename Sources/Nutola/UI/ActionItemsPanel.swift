import SwiftUI
import AppKit
import EventKit

/// Collapsible panel showing action items parsed from the meeting summary,
/// with checkboxes and an "Add to Reminders" button.
struct ActionItemsPanel: View {
    let meeting: Meeting
    let summary: String

    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var app: AppState
    @State private var isExpanded = true
    @State private var items: [ActionItem] = []
    @State private var remindersError: String?
    @State private var addedToReminders = false
    @State private var copiedToPasteboard = false

    private var openItems: [ActionItem] { items.filter { !$0.isChecked } }
    private var completedItems: [ActionItem] { items.filter { $0.isChecked } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary(scheme))
                        .accessibilityHidden(true)
                    Text("Action Items")
                        .font(.nutola(13, .semibold))
                        .foregroundStyle(Theme.heading(scheme))
                    Text("\(openItems.count)")
                        .font(.nutola(11, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            openItems.count > 0 ? Theme.mint(scheme) : Theme.secondary(scheme),
                            in: Capsule())
                    Button {
                        copyActionItems()
                    } label: {
                        Label(copiedToPasteboard ? "Copied" : "Copy", systemImage: "doc.on.doc")
                            .font(.nutola(11, .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy action items to clipboard")
                    .accessibilityLabel("Copy action items")
                    .accessibilityHint("Copy all action items to the clipboard")
                    .disabled(items.isEmpty)
                    Button {
                        addToReminders()
                    } label: {
                        Label("Reminders", systemImage: "checklist")
                            .font(.nutola(11, .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Add open action items to Apple Reminders")
                    .accessibilityLabel("Add to Reminders")
                    .accessibilityHint("Add open action items to Apple Reminders")
                    .disabled(items.isEmpty)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                if items.isEmpty {
                    // #11 — empty-state row so the panel isn't a bare header.
                    Text("No action items found")
                        .font(.nutola(12))
                        .foregroundStyle(Theme.tertiary(scheme))
                        .padding(.vertical, 4)
                        .padding(.leading, 18)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(openItems) { item in
                            actionItemRow(item)
                        }
                        if !completedItems.isEmpty {
                            Divider().padding(.vertical, 2)
                            ForEach(completedItems) { item in
                                actionItemRow(item)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if let remindersError {
                Text(remindersError)
                    .font(.nutola(10))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
        // #12 — confirmation is a brief overlay that auto-clears after 2s so it
        // doesn't reflow the panel the way inline text would.
        .overlay(alignment: .top) {
            if addedToReminders {
                Text("Added \(openItems.count) item\(openItems.count == 1 ? "" : "s") to Reminders")
                    .font(.nutola(11, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.mint(scheme), in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(14)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .frame(maxWidth: 660, alignment: .leading)
        .onAppear { parseItems() }
        .onChange(of: summary) { parseItems() }
    }

    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(item.isChecked ? Theme.secondary(scheme) : Theme.mint(scheme))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.nutola(13))
                    .foregroundStyle(item.isChecked ? Theme.secondary(scheme) : Theme.heading(scheme))
                    .strikethrough(item.isChecked)
                if let owner = item.owner {
                    Text(owner)
                        .font(.nutola(11))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func parseItems() {
        items = ActionItemParser.parse(summary)
    }

    private func copyActionItems() {
        guard !items.isEmpty else { return }
        let text = items.map { item in
            var line = item.isChecked ? "☑ \(item.text)" : "☐ \(item.text)"
            if let owner = item.owner { line += " (\(owner))" }
            return line
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedToPasteboard = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedToPasteboard = false
        }
    }

    private func addToReminders() {
        guard !openItems.isEmpty else { return }
        let store = EKEventStore()
        store.requestFullAccessToReminders { granted, error in
            DispatchQueue.main.async {
                guard granted, error == nil else {
                    remindersError = "Can't access Reminders. Grant access in System Settings."
                        + " → Privacy & Security → Reminders."
                    return
                }
                let reminder = EKReminder(eventStore: store)
                reminder.title = "Action Items: \(meeting.title)"
                reminder.notes = openItems.map { item in
                    var line = "☐ \(item.text)"
                    if let owner = item.owner { line += " (\(owner))" }
                    return line
                }.joined(separator: "\n")
                reminder.calendar = store.defaultCalendarForNewReminders()
                do {
                    try store.save(reminder, commit: true)
                    addedToReminders = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        addedToReminders = false
                    }
                } catch {
                    remindersError = "Failed to create reminder: \(error.localizedDescription)"
                }
            }
        }
    }
}
