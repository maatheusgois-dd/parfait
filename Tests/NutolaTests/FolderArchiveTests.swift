import XCTest
@testable import Nutola

@MainActor
final class FolderArchiveTests: XCTestCase {
    var tmp: URL!
    var archive: FolderArchive!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-folder-tests-\(UUID().uuidString)")
        archive = FolderArchive(root: tmp)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testFolderRoundTrip() throws {
        let folder = MeetingFolder(name: "Eng Standup", createdAt: Date())
        try archive.save(folder)
        XCTAssertEqual(archive.allFolders().map(\.id), [folder.id])
        XCTAssertEqual(archive.allFolders().first?.name, "Eng Standup")
    }

    func testUpdateFolder() throws {
        var folder = MeetingFolder(name: "Old", createdAt: Date())
        try archive.save(folder)
        folder.name = "New"
        try archive.save(folder)
        XCTAssertEqual(archive.allFolders().count, 1)
        XCTAssertEqual(archive.allFolders().first?.name, "New")
    }

    func testUpdateFolderDescription() throws {
        var folder = MeetingFolder(name: "Team", description: "Weekly syncs", createdAt: Date())
        try archive.save(folder)
        folder.description = "1:1 notes and standups"
        try archive.save(folder)
        XCTAssertEqual(archive.allFolders().first?.description, "1:1 notes and standups")
    }

    func testDeleteFolderClearsRules() throws {
        let folder = MeetingFolder(name: "Team", createdAt: Date())
        try archive.save(folder)
        try archive.setRule(normalizedTitle: "standup", folderID: folder.id)
        XCTAssertEqual(archive.allTitleRules().count, 1)
        try archive.deleteFolder(id: folder.id)
        XCTAssertTrue(archive.allFolders().isEmpty)
        XCTAssertTrue(archive.allTitleRules().isEmpty)
    }

    func testRuleLookup() throws {
        let folder = MeetingFolder(name: "1:1s", createdAt: Date())
        try archive.save(folder)
        try archive.setRule(normalizedTitle: "weekly 1:1", folderID: folder.id)
        let rule = archive.rule(forTitle: "  Weekly  1:1  ")
        XCTAssertEqual(rule?.folderID, folder.id)
    }

    func testSetRuleUpserts() throws {
        let a = MeetingFolder(name: "A", createdAt: Date())
        let b = MeetingFolder(name: "B", createdAt: Date())
        try archive.save(a)
        try archive.save(b)
        try archive.setRule(normalizedTitle: "sync", folderID: a.id)
        try archive.setRule(normalizedTitle: "sync", folderID: b.id)
        XCTAssertEqual(archive.allTitleRules().count, 1)
        XCTAssertEqual(archive.rule(forTitle: "sync")?.folderID, b.id)
    }
}

@MainActor
final class MeetingFolderStoreTests: XCTestCase {
    var tmp: URL!
    var meetingArchive: MeetingArchive!
    var folderArchive: FolderArchive!
    var meetingStore: MeetingStore!
    var folderStore: MeetingFolderStore!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-folder-store-\(UUID().uuidString)")
        meetingArchive = MeetingArchive(root: tmp)
        folderArchive = FolderArchive(root: tmp)
        meetingStore = MeetingStore(archive: meetingArchive)
        folderStore = MeetingFolderStore(archive: folderArchive)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeMeeting(title: String, calendarTitle: String? = nil) -> Meeting {
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        var m = Meeting(title: title, createdAt: now)
        m.calendarEventTitle = calendarTitle
        m.state = .ready
        try? meetingArchive.createFolder(for: m.id)
        meetingStore.upsert(m)
        return m
    }

    func testCreateFolderWithDescription() {
        let folder = folderStore.createFolder(
            name: "Standups",
            description: "Engineering team recurring meetings")
        XCTAssertEqual(folder.description, "Engineering team recurring meetings")
        XCTAssertEqual(folderStore.folder(id: folder.id)?.description, "Engineering team recurring meetings")
    }

    func testAssignWritesRuleAndBackfills() {
        let folder = folderStore.createFolder(name: "Standups")
        let old = makeMeeting(title: "Standup", calendarTitle: "Engineering Standup")
        folderStore.assign(meetingID: old.id, to: folder.id, meetingStore: meetingStore)
        XCTAssertEqual(meetingStore.meeting(id: old.id)?.folderID, folder.id)
        XCTAssertNotNil(folderArchive.rule(forTitle: "Engineering Standup"))

        let unfiled = makeMeeting(title: "Engineering Standup", calendarTitle: "Engineering Standup")
        XCTAssertEqual(unfiled.folderID, nil)
        folderStore.assign(calendarTitle: "Engineering Standup", to: folder.id, meetingStore: meetingStore)
        XCTAssertEqual(meetingStore.meeting(id: unfiled.id)?.folderID, folder.id)
    }

    func testDeleteFolderUnfilesMeetings() {
        let folder = folderStore.createFolder(name: "Temp")
        let m = makeMeeting(title: "Notes")
        folderStore.assign(meetingID: m.id, to: folder.id, meetingStore: meetingStore)
        folderStore.deleteFolder(id: folder.id, meetingStore: meetingStore)
        XCTAssertNil(meetingStore.meeting(id: m.id)?.folderID)
        XCTAssertTrue(folderStore.folders.isEmpty)
    }

    func testMeetingsInFolderSortedNewestFirst() {
        let folder = folderStore.createFolder(name: "Series")
        let older = makeMeeting(title: "A")
        var newer = makeMeeting(title: "B")
        newer.createdAt = older.createdAt.addingTimeInterval(3600)
        meetingStore.upsert(newer)
        folderStore.assign(meetingID: older.id, to: folder.id, meetingStore: meetingStore)
        folderStore.assign(meetingID: newer.id, to: folder.id, meetingStore: meetingStore)
        let listed = folderStore.meetings(in: folder.id, from: meetingStore)
        XCTAssertEqual(listed.map(\.id), [newer.id, older.id])
    }
}
