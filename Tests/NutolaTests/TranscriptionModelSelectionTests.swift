import XCTest
@testable import Nutola

/// Tests that `Transcriber` branches on the user's selected transcription model.
///
/// The branch point lives in `Transcriber.resolveEngine(for:)`, a pure decision
/// over `TranscriptionModel.isModelInstalled` (a real check of the CoreML /
/// `.nemo` files under Application Support). It returns an `EngineDecision` that
/// the audio path switches on, so the selection can be verified without running
/// the async Apple SpeechAnalyzer or touching real audio. The Parakeet/Nemotron
/// inference engines aren't wired in Nutola yet (SoniqoModelStore /
/// NemotronModelStore manage bytes only), so every non-Apple selection resolves
/// to a fallback decision with a clear log — the whole point of this wiring.
final class TranscriptionModelSelectionTests: XCTestCase {

    // MARK: - Apple path

    func testAppleAlwaysResolvesToApple() {
        XCTAssertEqual(Transcriber.resolveEngine(for: .apple), .apple)
    }

    func testAppleResolvesToAppleRegardlessOfInstallState() {
        // Apple isn't downloadable and `isModelInstalled` is unconditionally true,
        // so the decision never depends on disk state.
        XCTAssertTrue(TranscriptionModel.apple.isModelInstalled)
        XCTAssertEqual(Transcriber.resolveEngine(for: .apple), .apple)
    }

    // MARK: - Parakeet fallback (no inference engine wired)

    func testParakeetStreamingResolvesToFallbackWhenNotInstalled() {
        let decision = Transcriber.resolveEngine(for: .parakeetStreaming)
        // Either the weights aren't on disk (the common test-machine case) or
        // they are but there's no inference engine — both fall back to Apple,
        // never to .apple directly, so the selection is *not* silently ignored.
        switch decision {
        case .parakeetNotInstalled(.parakeetStreaming),
             .parakeetInstalledButNoInference(.parakeetStreaming):
            break
        default:
            XCTFail("parakeetStreaming should fall back, got \(decision)")
        }
        XCTAssertNotEqual(decision, .apple)
    }

    func testParakeetBatchResolvesToFallbackWhenNotInstalled() {
        let decision = Transcriber.resolveEngine(for: .parakeetBatch)
        switch decision {
        case .parakeetNotInstalled(.parakeetBatch),
             .parakeetInstalledButNoInference(.parakeetBatch):
            break
        default:
            XCTFail("parakeetBatch should fall back, got \(decision)")
        }
        XCTAssertNotEqual(decision, .apple)
    }

    func testParakeetFallbackDecisionCarriesSelectedModel() {
        // The decision must remember *which* Parakeet variant was selected so the
        // log can name it; a generic fallback would lose that.
        let streaming = Transcriber.resolveEngine(for: .parakeetStreaming)
        let batch = Transcriber.resolveEngine(for: .parakeetBatch)
        let streamingModel: TranscriptionModel? = {
            if case .parakeetNotInstalled(let m) = streaming { return m }
            if case .parakeetInstalledButNoInference(let m) = streaming { return m }
            return nil
        }()
        let batchModel: TranscriptionModel? = {
            if case .parakeetNotInstalled(let m) = batch { return m }
            if case .parakeetInstalledButNoInference(let m) = batch { return m }
            return nil
        }()
        XCTAssertEqual(streamingModel, .parakeetStreaming)
        XCTAssertEqual(batchModel, .parakeetBatch)
    }

    func testParakeetDecisionMatchesRealInstallState() {
        // resolveEngine must reflect the actual on-disk state: the
        // parakeetInstalledButNoInference branch fires exactly when
        // isModelInstalled is true, and parakeetNotInstalled when it's false.
        // (This is what makes the fallback a *real* model-file check, not a stub.)
        for variant in [TranscriptionModel.parakeetStreaming, .parakeetBatch] {
            let installed = variant.isModelInstalled
            let decision = Transcriber.resolveEngine(for: variant)
            if installed {
                XCTAssertEqual(decision, .parakeetInstalledButNoInference(variant),
                               "\(variant.rawValue) is installed → should report no-inference fallback")
            } else {
                XCTAssertEqual(decision, .parakeetNotInstalled(variant),
                               "\(variant.rawValue) not installed → should report not-installed fallback")
            }
        }
    }

    // MARK: - Nemotron fallback

    func testNemotronResolvesToFallback() {
        XCTAssertEqual(Transcriber.resolveEngine(for: .nemotron), .nemotronNotAvailable)
    }

    func testNemotronIsNeverApple() {
        // Nemotron has no inference runner wired; it must always fall back, and
        // the decision must be distinct from .apple so the log says "coming soon".
        let decision = Transcriber.resolveEngine(for: .nemotron)
        XCTAssertNotEqual(decision, .apple)
        XCTAssertEqual(decision, .nemotronNotAvailable)
    }

    // MARK: - AppSettings is respected (the production entrypoint)

    func testDefaultSelectionIsApple() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.transcriptionModel)
        XCTAssertEqual(AppSettings.transcriptionModel, .apple)
        XCTAssertEqual(Transcriber.resolveEngine(for: nil), .apple)
    }

    func testResolveEngineDefaultsToAppSettings() {
        // resolveEngine(for: nil) must read AppSettings.transcriptionModel so the
        // pipeline (which calls transcribeFile(at:) → transcribeFile(at:selected: nil))
        // honors the user's Settings choice.
        for model in TranscriptionModel.allCases {
            UserDefaults.standard.set(model.rawValue, forKey: SettingsKey.transcriptionModel)
            XCTAssertEqual(AppSettings.transcriptionModel, model)
            // The default-arg call should match the explicit-model call for each.
            let viaDefault = Transcriber.resolveEngine(for: nil)
            let explicit = Transcriber.resolveEngine(for: model)
            XCTAssertEqual(viaDefault, explicit,
                           "resolveEngine(for: nil) must track AppSettings for \(model.rawValue)")
        }
        UserDefaults.standard.removeObject(forKey: SettingsKey.transcriptionModel)
    }

    func testExplicitSelectionOverridesAppSettings() {
        // Even if AppSettings says apple, an explicit .nemotron must resolve to
        // nemotronNotAvailable — the branch point takes the explicit argument.
        UserDefaults.standard.set(TranscriptionModel.apple.rawValue, forKey: SettingsKey.transcriptionModel)
        XCTAssertEqual(Transcriber.resolveEngine(for: .nemotron), .nemotronNotAvailable)
        XCTAssertEqual(Transcriber.resolveEngine(for: .parakeetStreaming), .parakeetNotInstalled(.parakeetStreaming))
        UserDefaults.standard.removeObject(forKey: SettingsKey.transcriptionModel)
    }

    // MARK: - EngineDecision exhaustiveness

    func testEveryModelProducesADecision() {
        // No model should slip through unhandled — every selection yields a real
        // decision, so the audio switch is always exhaustive.
        for model in TranscriptionModel.allCases {
            let decision = Transcriber.resolveEngine(for: model)
            switch decision {
            case .apple,
                 .parakeetInstalledButNoInference,
                 .parakeetNotInstalled,
                 .nemotronNotAvailable:
                break
            }
        }
    }

    func testEngineDecisionEquality() {
        // The associated-value cases compare on the carried model, so two
        // different Parakeet variants are distinct decisions.
        XCTAssertNotEqual(
            Transcriber.EngineDecision.parakeetNotInstalled(.parakeetStreaming),
            Transcriber.EngineDecision.parakeetNotInstalled(.parakeetBatch))
        XCTAssertEqual(
            Transcriber.EngineDecision.parakeetNotInstalled(.parakeetStreaming),
            Transcriber.EngineDecision.parakeetNotInstalled(.parakeetStreaming))
        XCTAssertNotEqual(Transcriber.EngineDecision.apple, .nemotronNotAvailable)
    }
}
