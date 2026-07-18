import XCTest
@testable import Nutola

final class ArchivedEventStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "test-archived-events-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> ArchivedEventStore {
        ArchivedEventStore(
            defaults: defaults,
            titlesKey: "test-archived-titles",
            idsKey: "test-archived-ids"
        )
    }

    // MARK: - Title (series) archiving

    func testArchiveTitle() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        XCTAssertTrue(store.isTitleArchived("Lunch time"))
        XCTAssertFalse(store.isTitleArchived("Standup"))
    }

    func testArchiveTitleTrimsWhitespace() {
        let store = makeStore()
        store.archiveTitle("  Lunch time  ")
        XCTAssertTrue(store.isTitleArchived("Lunch time"))
    }

    func testArchiveEmptyTitleIsNoOp() {
        let store = makeStore()
        store.archiveTitle("   ")
        XCTAssertTrue(store.archivedTitles.isEmpty)
    }

    func testUnarchiveTitle() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        store.unarchiveTitle("Lunch time")
        XCTAssertFalse(store.isTitleArchived("Lunch time"))
    }

    // MARK: - Event ID archiving

    func testArchiveEventByID() {
        let store = makeStore()
        let id = UUID().uuidString
        store.archiveEvent(id: id)
        XCTAssertTrue(store.isEventArchived(id: id))
        XCTAssertFalse(store.isEventArchived(id: "other"))
    }

    func testUnarchiveEventByID() {
        let store = makeStore()
        let id = UUID().uuidString
        store.archiveEvent(id: id)
        store.unarchiveEvent(id: id)
        XCTAssertFalse(store.isEventArchived(id: id))
    }

    // MARK: - Combined filtering

    func testIsArchivedByTitle() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        XCTAssertTrue(store.isArchived(title: "Lunch time", eventID: "abc"))
    }

    func testIsArchivedByEventID() {
        let store = makeStore()
        store.archiveEvent(id: "evt-123")
        XCTAssertTrue(store.isArchived(title: "Other", eventID: "evt-123"))
    }

    func testIsNotArchivedWhenNeitherMatches() {
        let store = makeStore()
        XCTAssertFalse(store.isArchived(title: "Lunch time", eventID: "abc"))
    }

    // MARK: - Clear all

    func testClearAll() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        store.archiveEvent(id: "evt-123")
        store.clearAll()
        XCTAssertTrue(store.archivedTitles.isEmpty)
        XCTAssertTrue(store.archivedEventIDs.isEmpty)
        XCTAssertFalse(store.isArchived(title: "Lunch time", eventID: "evt-123"))
    }

    // MARK: - Persistence

    func testTitlesPersistAcrossInstances() {
        let store1 = makeStore()
        store1.archiveTitle("Standup")

        let store2 = makeStore()
        XCTAssertTrue(store2.isTitleArchived("Standup"))
    }

    func testEventIDsPersistAcrossInstances() {
        let store1 = makeStore()
        store1.archiveEvent(id: "evt-456")

        let store2 = makeStore()
        XCTAssertTrue(store2.isEventArchived(id: "evt-456"))
    }

    // MARK: - Multiple

    func testMultipleTitlesArchived() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        store.archiveTitle("Standup")
        store.archiveTitle("1:1")
        XCTAssertEqual(store.archivedTitles.count, 3)
    }

    func testDuplicateTitleIsIdempotent() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        store.archiveTitle("Lunch time")
        XCTAssertEqual(store.archivedTitles.count, 1)
    }
}
