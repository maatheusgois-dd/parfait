import Foundation

/// Which ASR engine Parfait uses to transcribe meetings.
///
/// `.apple` is the default — the macOS SpeechAnalyzer / SpeechTranscriber framework,
/// downloaded as on-device assets through `AssetInventory`. Downloadable engines store
/// weights under Application Support and are managed by their model stores; inference
/// engines for those paths ship separately.
///
/// Transcription pipelines branch on this value:
/// - **Apple** path uses `SpeechTranscriber` / `SpeechAnalyzer` (live + batch).
/// - **Soniqo Parakeet** paths use CoreML weights from anarlog's Hugging Face repos.
/// - **Nemotron** path is a future batch engine over the downloaded `.nemo` archive.
enum TranscriptionModel: String, CaseIterable, Identifiable, Hashable {
    case apple
    case parakeetStreaming
    case parakeetBatch
    case nemotron

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple Speech"
        case .parakeetStreaming: "Soniqo Parakeet Streaming"
        case .parakeetBatch: "Soniqo Parakeet Batch"
        case .nemotron: "Nemotron-3.5 ASR"
        }
    }

    var detail: String {
        switch self {
        case .apple:
            "macOS on-device SpeechAnalyzer. English & Brazilian Portuguese ready; "
                + "other system languages download on first use."
        case .parakeetStreaming:
            "Live transcription during meetings. 25 European languages "
                + "(en, pt, es, fr, de, …). CoreML on Apple Silicon; "
                + "~\(SoniqoModelStore.formatBytes(SoniqoModelStore.totalSize(.parakeetStreaming)))."
        case .parakeetBatch:
            "Batch transcription after recording. Same 25 European languages. "
                + "CoreML on Apple Silicon; "
                + "~\(SoniqoModelStore.formatBytes(SoniqoModelStore.totalSize(.parakeetBatch)))."
        case .nemotron:
            "NVIDIA Nemotron-3.5-ASR-Streaming-0.6B (600M). Multilingual (40 locales), "
                + "streaming FastConformer-RNNT. Downloaded to this Mac; ~2.4 GB."
        }
    }

    var isDownloadable: Bool { self != .apple }

    var soniqoModel: SoniqoModel? {
        switch self {
        case .parakeetStreaming: .parakeetStreaming
        case .parakeetBatch: .parakeetBatch
        default: nil
        }
    }

    var supportsLiveTranscription: Bool {
        switch self {
        case .apple, .parakeetStreaming, .nemotron: true
        case .parakeetBatch: false
        }
    }

    var isModelInstalled: Bool {
        switch self {
        case .apple: true
        case .nemotron: NemotronModelStore.isInstalled
        case .parakeetStreaming: SoniqoModelStore.isInstalled(.parakeetStreaming)
        case .parakeetBatch: SoniqoModelStore.isInstalled(.parakeetBatch)
        }
    }

    var modelInstalledBytes: Int64 {
        switch self {
        case .apple: 0
        case .nemotron: NemotronModelStore.installedBytes
        case .parakeetStreaming: SoniqoModelStore.installedBytes(.parakeetStreaming)
        case .parakeetBatch: SoniqoModelStore.installedBytes(.parakeetBatch)
        }
    }

    var modelTotalBytes: Int64 {
        switch self {
        case .apple: 0
        case .nemotron: NemotronModelStore.totalSize
        case .parakeetStreaming: SoniqoModelStore.totalSize(.parakeetStreaming)
        case .parakeetBatch: SoniqoModelStore.totalSize(.parakeetBatch)
        }
    }

    func downloadModel(progress: @Sendable @escaping (Double) -> Void) async throws {
        switch self {
        case .apple:
            break
        case .nemotron:
            try await NemotronModelStore.download(progress: progress)
        case .parakeetStreaming:
            try await SoniqoModelStore.download(.parakeetStreaming, progress: progress)
        case .parakeetBatch:
            try await SoniqoModelStore.download(.parakeetBatch, progress: progress)
        }
    }

    @discardableResult
    func deleteModel() throws -> Int64 {
        switch self {
        case .apple: 0
        case .nemotron: try NemotronModelStore.delete()
        case .parakeetStreaming: try SoniqoModelStore.delete(.parakeetStreaming)
        case .parakeetBatch: try SoniqoModelStore.delete(.parakeetBatch)
        }
    }

    func revealModelInFinder() {
        switch self {
        case .apple:
            break
        case .nemotron:
            NemotronModelStore.revealInFinder()
        case .parakeetStreaming:
            SoniqoModelStore.revealInFinder(.parakeetStreaming)
        case .parakeetBatch:
            SoniqoModelStore.revealInFinder(.parakeetBatch)
        }
    }

    func logModelEvent(_ message: String) {
        switch self {
        case .apple:
            break
        case .nemotron:
            ParfaitConsoleLog.nemotron(message)
        case .parakeetStreaming, .parakeetBatch:
            ParfaitConsoleLog.soniqo(message)
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        RemoteModelDownloader.formatBytes(bytes)
    }
}
