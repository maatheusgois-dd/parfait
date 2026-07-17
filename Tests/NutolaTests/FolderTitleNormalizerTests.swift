import XCTest
@testable import Nutola

final class FolderTitleNormalizerTests: XCTestCase {
    func testTrimsAndLowercases() {
        XCTAssertEqual(
            FolderTitleNormalizer.key(for: "Identity Intelligence Eng Standup"),
            "identity intelligence eng standup")
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(FolderTitleNormalizer.key(for: "  Weekly  1:1  "), "weekly 1:1")
    }

    func testEmptyString() {
        XCTAssertEqual(FolderTitleNormalizer.key(for: "   "), "")
    }
}
