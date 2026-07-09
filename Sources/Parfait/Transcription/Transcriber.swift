import AVFoundation
import CoreMedia
import Foundation
import Speech

enum TranscriberError: LocalizedError {
    case unsupportedLocale(String)
    case modelUnavailable
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let identifier):
            return "Transcription isn't available for the language “\(identifier)”."
        case .modelUnavailable:
            return "On-device transcription isn't supported on this Mac."
        case .emptyAudio:
            return "The recording contains no audio."
        }
    }
}

enum Transcriber {
    static func modelInstalled(locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return false }
        // Locale matching is BCP-47 based; direct == misses equivalents.
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }
    }

    static func ensureModel(locale: Locale, progress: (@Sendable (Double) -> Void)?) async throws {
        let transcriber = try await makeTranscriber(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            progress?(1)
            return
        }
        var observation: NSKeyValueObservation?
        if let progress {
            observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                progress(p.fractionCompleted)
            }
        }
        defer { observation?.invalidate() }
        try await request.downloadAndInstall()
        progress?(1)
    }

    static func transcribeFile(at url: URL, locale: Locale) async throws -> TranscriptionOutput {
        let transcriber = try await makeTranscriber(locale: locale)

        // Results must be consumed concurrently: the stream only terminates when the
        // session finishes, so awaiting it before feeding audio would deadlock.
        async let collected = collectResults(from: transcriber)

        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) else {
            await analyzer.cancelAndFinishNow()
            throw TranscriberError.emptyAudio
        }
        // analyzeSequence returns when the file is read, not when analysis is done;
        // without this the results stream never terminates.
        try await analyzer.finalizeAndFinish(through: lastSampleTime)

        let (segments, words) = try await collected
        return TranscriptionOutput(words: words.isEmpty ? segments : words, segments: segments)
    }

    private static func makeTranscriber(locale: Locale) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.modelUnavailable }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }
        // Batch mode: no .volatileResults, so every result arrives final exactly once.
        return SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    private static func collectResults(
        from transcriber: SpeechTranscriber
    ) async throws -> (segments: [TranscribedWord], words: [TranscribedWord]) {
        var segments: [TranscribedWord] = []
        var words: [TranscribedWord] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(TranscribedWord(
                text: text,
                start: result.range.start.seconds,
                end: result.range.end.seconds
            ))
            for run in result.text.runs {
                // Runs without timing (punctuation, whitespace) are skipped; segments
                // remain the fallback when no run carries a time range.
                guard let timeRange = run.audioTimeRange else { continue }
                let word = String(result.text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { continue }
                words.append(TranscribedWord(
                    text: word,
                    start: timeRange.start.seconds,
                    end: timeRange.end.seconds
                ))
            }
        }
        return (segments, words)
    }
}
