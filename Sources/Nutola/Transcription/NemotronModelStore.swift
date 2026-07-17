import AppKit
import Foundation

/// Manages the NVIDIA Nemotron-3.5-ASR-Streaming-0.6B model on disk.
///
/// Downloads the model's files from Hugging Face into a stable directory under the
/// app's Application Support folder, reports download progress, and exposes
/// install/delete. The `.nemo` archive (~2.4 GB) is the primary payload; a small set
/// of config/tokenizer files are pulled alongside it. Nothing is extracted or run
/// here — this type only owns the bytes on disk; a future transcription engine will
/// consume them.
enum NemotronModelStore {
    static let repoID = "nvidia/nemotron-3.5-asr-streaming-0.6b"

    static let manifest: [RemoteModelFile] = [
        .init(path: "nemotron-3.5-asr-streaming-0.6b.nemo", size: 2_368_284_501, isPrimary: true),
        .init(path: "config.json", size: 1_376, isPrimary: false),
        .init(path: "tokenizer.json", size: 752_051, isPrimary: false),
        .init(path: "tokenizer_config.json", size: 881, isPrimary: false),
        .init(path: "processor_config.json", size: 2_519, isPrimary: false),
        .init(path: "generation_config.json", size: 193, isPrimary: false),
    ]

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nutola/Models/Nemotron", isDirectory: true)
    }

    static var totalSize: Int64 { RemoteModelDownloader.totalSize(manifest) }

    static func formatBytes(_ bytes: Int64) -> String {
        RemoteModelDownloader.formatBytes(bytes)
    }

    static var isInstalled: Bool {
        RemoteModelDownloader.isInstalled(directory: directory, manifest: manifest)
    }

    static var installedBytes: Int64 {
        RemoteModelDownloader.installedBytes(directory: directory, manifest: manifest)
    }

    static func download(progress: @Sendable @escaping (Double) -> Void) async throws {
        try await RemoteModelDownloader.download(
            repoID: repoID,
            directory: directory,
            manifest: manifest,
            onComplete: { NutolaConsoleLog.nemotron($0) },
            progress: progress
        )
    }

    @discardableResult
    static func delete() throws -> Int64 {
        let freed = installedBytes
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        try FileManager.default.removeItem(at: directory)
        NutolaConsoleLog.nemotron("deleted model — freed \(formatBytes(freed))")
        return freed
    }

    static func revealInFinder() {
        let target = FileManager.default.fileExists(atPath: directory.path)
            ? directory
            : directory.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}
