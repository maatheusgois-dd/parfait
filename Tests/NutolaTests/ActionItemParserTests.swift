import XCTest
@testable import Nutola

final class ActionItemParserTests: XCTestCase {
    func testParsesUncheckedCheckbox() {
        let markdown = """
        ## Action Items
        - [ ] Send the proposal — Alice
        - [ ] Review the code
        """
        let items = ActionItemParser.parse(markdown)
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].isChecked)
        XCTAssertEqual(items[0].text, "Send the proposal")
        XCTAssertEqual(items[0].owner, "Alice")
        XCTAssertNil(items[1].owner)
        XCTAssertEqual(items[1].text, "Review the code")
    }

    func testParsesCheckedCheckbox() {
        let markdown = "- [x] Done task\n- [X] Also done"
        let items = ActionItemParser.parse(markdown)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].isChecked)
        XCTAssertTrue(items[1].isChecked)
    }

    func testIgnoresNonCheckboxLines() {
        let markdown = """
        # Meeting Notes
        Some regular text.
        - Not a checkbox, just a bullet.
        - [ ] Real action item
        More text.
        """
        let items = ActionItemParser.parse(markdown)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Real action item")
    }

    func testOwnerExtractionWithParen() {
        let markdown = "- [ ] Fix the bug (Bob)"
        let items = ActionItemParser.parse(markdown)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Fix the bug")
        XCTAssertEqual(items[0].owner, "Bob")
    }

    func testOwnerExtractionWithHyphen() {
        let markdown = "- [ ] Deploy the service - Carol"
        let items = ActionItemParser.parse(markdown)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Deploy the service")
        XCTAssertEqual(items[0].owner, "Carol")
    }

    func testNoOwner() {
        let markdown = "- [ ] Just a task with no owner"
        let items = ActionItemParser.parse(markdown)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].owner)
        XCTAssertEqual(items[0].text, "Just a task with no owner")
    }

    func testOpenItemsFiltersChecked() {
        let markdown = """
        - [x] Completed task
        - [ ] Open task
        - [X] Also completed
        - [ ] Another open task
        """
        let open = ActionItemParser.openItems(markdown)
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(open[0].text, "Open task")
        XCTAssertEqual(open[1].text, "Another open task")
    }

    func testOpenCount() {
        let markdown = """
        - [x] Done
        - [ ] Todo 1
        - [ ] Todo 2
        """
        XCTAssertEqual(ActionItemParser.openCount(markdown), 2)
    }

    func testEmptyMarkdown() {
        XCTAssertTrue(ActionItemParser.parse("").isEmpty)
        XCTAssertEqual(ActionItemParser.openCount(""), 0)
    }

    func testAsteriskBulletCheckbox() {
        let markdown = "* [ ] Task with asterisk"
        let items = ActionItemParser.parse(markdown)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Task with asterisk")
    }

    func testIndentedCheckbox() {
        let markdown = "  - [ ] Indented task"
        let items = ActionItemParser.parse(markdown)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Indented task")
    }

    func testLineNumberTracking() {
        let markdown = """
        Line 0
        Line 1
        - [ ] Task on line 2
        Line 3
        """
        let items = ActionItemParser.parse(markdown)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].lineNumber, 2)
    }

    func testKeyStability() {
        let items = ActionItemParser.parse("- [ ] Do something")
        XCTAssertEqual(items[0].key, "do something")
    }

    // MARK: - #85: lines without checkbox patterns are skipped

    func testNonMatchingLinesAreIgnored() {
        // A paragraph of regular prose, headings, bullets, and dividers must
        // produce zero action items — only checkbox lines like "- [ ]", "* [ ]",
        // and "- [x]" match. Guards against the parser accidentally treating
        // plain bullets or headings as tasks.
        let markdown = """
        # Meeting Notes

        We discussed the roadmap and the Q4 OKRs.

        - Attendees: Alice, Bob, Carol
        - Date: 2026-07-18

        ---

        ## Discussion
        * Topic A: backend refactor
        - Topic B: launch timeline

        Action item: ship the release (no checkbox, just prose)
        TODO: refactor the API (no dash prefix)
        """
        let items = ActionItemParser.parse(markdown)
        XCTAssertTrue(items.isEmpty, "Non-checkbox lines should produce no action items — got \(items)")
    }
}
