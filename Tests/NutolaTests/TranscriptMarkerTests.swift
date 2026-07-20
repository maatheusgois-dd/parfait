import XCTest
@testable import Nutola

final class TranscriptMarkerTests: XCTestCase {
    var defaults: UserDefaults!
    var store: TranscriptMarkerStore!
    private var suite: String!

    override func setUp() {
        super.setUp()
        // A fresh, isolated UserDefaults suite per test so markers never leak
        // across tests or into the host app's .standard defaults.
        suite = "nutola-markers-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = TranscriptMarkerStore(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        store = nil
        suite = nil
        super.tearDown()
    }

    // MARK: - add / markers(for:)

    func testAddMarker() {
        let meetingID = UUID()
        store.add(meetingID: meetingID, timestamp: 42, label: "Important point")

        let markers = store.markers(for: meetingID)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.meetingID, meetingID)
        XCTAssertEqual(markers.first?.timestamp ?? -1, 42, accuracy: 0.001)
        XCTAssertEqual(markers.first?.label, "Important point")
        XCTAssertNotNil(markers.first?.id)
        XCTAssertNotNil(markers.first?.createdAt)
    }

    func testRemoveMarker() {
        let meetingID = UUID()
        store.add(meetingID: meetingID, timestamp: 10, label: "Remove me")
        let id = store.markers(for: meetingID).first!.id

        store.remove(id: id, meetingID: meetingID)
        XCTAssertTrue(store.markers(for: meetingID).isEmpty)
    }

    func testMultipleMarkers() {
        let meetingID = UUID()
        // Add out of timestamp order to verify the read sorts by timestamp.
        store.add(meetingID: meetingID, timestamp: 30, label: "C")
        store.add(meetingID: meetingID, timestamp: 5, label: "A")
        store.add(meetingID: meetingID, timestamp: 20, label: "B")

        let markers = store.markers(for: meetingID)
        XCTAssertEqual(markers.count, 3)
        // Sorted by timestamp ascending.
        XCTAssertEqual(markers.map(\.label), ["A", "B", "C"])
        XCTAssertEqual(markers.map(\.timestamp), [5, 20, 30])
    }

    func testMarkersForDifferentMeetings() {
        let m1 = UUID()
        let m2 = UUID()

        store.add(meetingID: m1, timestamp: 1, label: "Meeting 1 marker")
        XCTAssertEqual(store.markers(for: m1).count, 1)
        // The other meeting must not see this marker.
        XCTAssertTrue(store.markers(for: m2).isEmpty)

        // Adding a marker under m2 leaves m1 alone.
        store.add(meetingID: m2, timestamp: 2, label: "Meeting 2 marker")
        XCTAssertEqual(store.markers(for: m1).count, 1)
        XCTAssertEqual(store.markers(for: m2).count, 1)
        XCTAssertEqual(store.markers(for: m2).first?.label, "Meeting 2 marker")
    }

    // MARK: - isMarked

    func testIsMarked() {
        let meetingID = UUID()
        store.add(meetingID: meetingID, timestamp: 100, label: "Boundary")

        // Exact timestamp is within default tolerance.
        XCTAssertTrue(store.isMarked(meetingID: meetingID, timestamp: 100))
        // Within the default 1.0s tolerance.
        XCTAssertTrue(store.isMarked(meetingID: meetingID, timestamp: 100.5))
        XCTAssertTrue(store.isMarked(meetingID: meetingID, timestamp: 100.9))
        // Just outside the default tolerance.
        XCTAssertFalse(store.isMarked(meetingID: meetingID, timestamp: 101.5))

        // A custom tolerance widens the window.
        XCTAssertTrue(store.isMarked(meetingID: meetingID, timestamp: 103, tolerance: 5))
        XCTAssertFalse(store.isMarked(meetingID: meetingID, timestamp: 200, tolerance: 5))

        // A meeting with no markers is never marked.
        let other = UUID()
        XCTAssertFalse(store.isMarked(meetingID: other, timestamp: 100))
    }

    // MARK: - clear

    func testClearAll() {
        let meetingID = UUID()
        store.add(meetingID: meetingID, timestamp: 1, label: "A")
        store.add(meetingID: meetingID, timestamp: 2, label: "B")
        store.add(meetingID: meetingID, timestamp: 3, label: "C")
        XCTAssertEqual(store.markers(for: meetingID).count, 3)

        store.clear(meetingID: meetingID)
        XCTAssertTrue(store.markers(for: meetingID).isEmpty)

        // Clearing an already-empty meeting is a no-op.
        store.clear(meetingID: meetingID)
        XCTAssertTrue(store.markers(for: meetingID).isEmpty)
    }

    // MARK: - persistence

    func testPersistAcrossInstances() {
        // A new store reading the same defaults sees previously-added markers —
        // the persistence layer is UserDefaults, not in-memory state.
        let meetingID = UUID()
        store.add(meetingID: meetingID, timestamp: 7, label: "Survives a restart")

        let revived = TranscriptMarkerStore(defaults: defaults)
        XCTAssertEqual(revived.markers(for: meetingID).count, 1)
        XCTAssertEqual(revived.markers(for: meetingID).first?.label, "Survives a restart")
    }

    func testLabelStored() {
        let meetingID = UUID()
        store.add(
            meetingID: meetingID,
            timestamp: 88.5,
            label: "Decided on the Q3 roadmap",
            turnIndex: 4)

        let marker = store.markers(for: meetingID).first
        XCTAssertNotNil(marker)
        XCTAssertEqual(marker?.label, "Decided on the Q3 roadmap")
        XCTAssertEqual(marker?.timestamp ?? -1, 88.5, accuracy: 0.001)
        XCTAssertEqual(marker?.transcriptTurnIndex, 4)
        XCTAssertEqual(marker?.meetingID, meetingID)
    }
}
