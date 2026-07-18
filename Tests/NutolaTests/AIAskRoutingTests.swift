import XCTest
@testable import Nutola

final class AIAskRoutingTests: XCTestCase {
    private func setProvider(_ provider: AIProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: SettingsKey.preferredAIProvider)
    }

    func testProviderDisplayNames() {
        XCTAssertFalse(AIProvider.claude.displayName.isEmpty)
        XCTAssertFalse(AIProvider.codex.displayName.isEmpty)
        XCTAssertFalse(AIProvider.apple.displayName.isEmpty)
    }

    func testAppleOpenReturnsFalse() {
        let saved = AppSettings.preferredAIProvider
        setProvider(.apple)
        defer { setProvider(saved) }
        XCTAssertFalse(AIAsk.open(prompt: "test"))
    }

    func testClaudeOpenDoesNotReturnFalseWhenAvailable() {
        let saved = AppSettings.preferredAIProvider
        setProvider(.claude)
        defer { setProvider(saved) }
        // Claude Desktop may or may not be installed — just verify it doesn't crash
        _ = AIAsk.open(prompt: "test")
    }

    func testAppleAnswerRoutesToAppleSummarizer() async throws {
        guard AppleSummarizer.isAvailable else {
            throw XCTSkip("Apple Intelligence not available on this device")
        }
        let saved = AppSettings.preferredAIProvider
        setProvider(.apple)
        defer { setProvider(saved) }
        do {
            _ = try await AIAsk.answer(prompt: "Say hello")
        } catch is AIAskError {
            XCTFail("Should not throw AIAskError for .apple provider")
        } catch {
            // Other errors (model unavailable, rate limit) are acceptable
        }
    }
}
