import Foundation

/// Persists user-archived calendar events so they're hidden from Coming up.
///
/// Two modes:
/// - **By title** (series): hides all events sharing a title (e.g. "Lunch time" recurring)
/// - **By event ID**: hides a single event instance
final class ArchivedEventStore: ObservableObject {
    @Published private(set) var archivedTitles: Set<String>
    @Published private(set) var archivedEventIDs: Set<String>

    private let defaults: UserDefaults
    private let titlesKey: String
    private let idsKey: String

    init(defaults: UserDefaults = .standard,
         titlesKey: String = SettingsKey.archivedEventTitles,
         idsKey: String = SettingsKey.archivedEventIDs) {
        self.defaults = defaults
        self.titlesKey = titlesKey
        self.idsKey = idsKey
        self.archivedTitles = Set(defaults.stringArray(forKey: titlesKey) ?? [])
        self.archivedEventIDs = Set(defaults.stringArray(forKey: idsKey) ?? [])
    }

    // MARK: - Title (series) archiving

    func archiveTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        archivedTitles.insert(trimmed)
        persistTitles()
        objectWillChange.send()
    }

    func unarchiveTitle(_ title: String) {
        archivedTitles.remove(title)
        persistTitles()
        objectWillChange.send()
    }

    func isTitleArchived(_ title: String) -> Bool {
        archivedTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Individual event archiving

    func archiveEvent(id: String) {
        archivedEventIDs.insert(id)
        persistIDs()
        objectWillChange.send()
    }

    func unarchiveEvent(id: String) {
        archivedEventIDs.remove(id)
        persistIDs()
        objectWillChange.send()
    }

    func isEventArchived(id: String) -> Bool {
        archivedEventIDs.contains(id)
    }

    // MARK: - Filtering

    /// Returns `true` if the event should be hidden from views.
    func isArchived(title: String, eventID: String) -> Bool {
        isTitleArchived(title) || isEventArchived(id: eventID)
    }

    /// Clears all archived titles and event IDs.
    func clearAll() {
        archivedTitles.removeAll()
        archivedEventIDs.removeAll()
        persistTitles()
        persistIDs()
        objectWillChange.send()
    }

    // MARK: - Persistence

    private func persistTitles() {
        defaults.set(Array(archivedTitles).sorted(), forKey: titlesKey)
    }

    private func persistIDs() {
        defaults.set(Array(archivedEventIDs).sorted(), forKey: idsKey)
    }
}
