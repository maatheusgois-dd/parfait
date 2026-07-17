import XCTest
@testable import Nutola

final class TranscriptionLocalesTests: XCTestCase {
    func testAssetCandidatesIncludeEnglishAndBrazilianPortuguese() {
        let ids = TranscriptionLocales.assetCandidateIdentifiers()
        XCTAssertTrue(ids.contains("en-US"))
        XCTAssertTrue(ids.contains("pt-BR"))
    }

    func testAssetCandidatesDedupeCurrentWhenEnglish() {
        // On English-primary Macs, current and en-US collapse to one entry.
        let ids = TranscriptionLocales.assetCandidateIdentifiers()
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testPrimaryCandidatesPreferPortugueseWhenInPreferredLanguages() throws {
        let ids = TranscriptionLocales.primaryCandidateIdentifiers()
        guard Locale.preferredLanguages.contains(where: { $0.hasPrefix("pt") }) else {
            throw XCTSkip("Portuguese not in preferred languages on this machine")
        }
        XCTAssertEqual(ids.first, "pt-BR")
    }
}
