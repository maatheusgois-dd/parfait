import Foundation
import os

/// A single file in a Hugging Face model repo, tracked for resumable download.
struct RemoteModelFile: Hashable, Sendable {
    let path: String
    let size: Int64
    let isPrimary: Bool
}

/// Resumable parallel downloads from `huggingface.co/{repo}/resolve/main/…` into a
/// local directory. Supports nested paths (CoreML `.mlmodelc` bundles).
enum RemoteModelDownloader {
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func totalSize(_ manifest: [RemoteModelFile]) -> Int64 {
        manifest.reduce(0) { $0 + $1.size }
    }

    static func fileURL(directory: URL, path: String) -> URL {
        directory.appending(path: path)
    }

    static func partURL(directory: URL, path: String) -> URL {
        directory.appending(path: path + ".part")
    }

    static func isInstalled(directory: URL, manifest: [RemoteModelFile]) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        return manifest.allSatisfy { isComplete(directory: directory, file: $0) }
    }

    static func installedBytes(directory: URL, manifest: [RemoteModelFile]) -> Int64 {
        manifest.reduce(Int64(0)) { total, file in
            let url = fileURL(directory: directory, path: file.path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber
            else { return total }
            return total + Int64(truncating: size)
        }
    }

    static func download(
        repoID: String,
        directory: URL,
        manifest: [RemoteModelFile],
        onComplete: @Sendable (String) -> Void,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = totalSize(manifest)
        let tracker = DownloadProgressTracker(total: total, progress: progress)

        let complete = manifest.filter { isComplete(directory: directory, file: $0) }
        for file in complete { tracker.markComplete(file) }

        let toDownload = manifest.filter { !isComplete(directory: directory, file: $0) }
        for file in toDownload { tracker.markStarting(file) }

        try await withThrowingTaskGroup(of: Int64.self) { group in
            for file in toDownload {
                group.addTask {
                    let part = partURL(directory: directory, path: file.path)
                    let fileDone = try await downloadFile(
                        repoID: repoID, file: file, to: part
                    ) { bytesWritten in
                        tracker.update(file, bytes: bytesWritten)
                    }
                    let finalURL = fileURL(directory: directory, path: file.path)
                    try FileManager.default.createDirectory(
                        at: finalURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.moveItem(at: part, to: finalURL)
                    return fileDone
                }
            }
            try await group.waitForAll()
        }
        onComplete("download complete — \(formatBytes(total))")
    }

    private static func downloadFile(
        repoID: String,
        file: RemoteModelFile,
        to partURL: URL,
        onBytes: @Sendable @escaping (Int64) -> Void
    ) async throws -> Int64 {
        let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(encoded)")!
        let resumeDataPath = partURL.appendingPathExtension("resume")
        var resumeData: Data?
        if FileManager.default.fileExists(atPath: partURL.path) {
            resumeData = try? Data(contentsOf: resumeDataPath)
        }
        try FileManager.default.createDirectory(
            at: partURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let (bytes, finalResume) = try await transfer(
            url: url, to: partURL, resumeData: resumeData, onBytes: onBytes
        )
        if let finalResume {
            try? finalResume.write(to: resumeDataPath)
        } else {
            try? FileManager.default.removeItem(at: resumeDataPath)
        }
        return bytes
    }

    private static func transfer(
        url: URL,
        to partURL: URL,
        resumeData: Data?,
        onBytes: @Sendable @escaping (Int64) -> Void
    ) async throws -> (bytes: Int64, resumeData: Data?) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60 * 60
        let delegate = ModelDownloadDelegate(partURL: partURL, onBytes: onBytes)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: url)
        }
        task.resume()

        return try await withTaskCancellationHandler(
            operation: { try await delegate.run(task: task) },
            onCancel: { [weak task] in task?.cancel() }
        )
    }

    private static func isComplete(directory: URL, file: RemoteModelFile) -> Bool {
        let url = fileURL(directory: directory, path: file.path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.intValue >= Int(file.size)
    }
}
// MARK: - Progress aggregation

/// Thread-safe aggregate progress across concurrent downloads. Uses a lock
/// (not an actor) so the progress callback can fire synchronously from the
/// URLSession delegate thread without an async hop.
private final class DownloadProgressTracker: @unchecked Sendable {
    private let total: Int64
    private let progress: @Sendable (Double) -> Void
    private var bytesByFile: [RemoteModelFile: Int64] = [:]
    private let lock = OSAllocatedUnfairLock()

    init(total: Int64, progress: @Sendable @escaping (Double) -> Void) {
        self.total = total
        self.progress = progress
    }

    func markComplete(_ file: RemoteModelFile) {
        lock.withLock { bytesByFile[file] = file.size }
        emit()
    }

    func markStarting(_ file: RemoteModelFile) {
        lock.withLock { bytesByFile[file] = 0 }
    }

    func update(_ file: RemoteModelFile, bytes: Int64) {
        lock.withLock { bytesByFile[file] = bytes }
        emit()
    }

    private func emit() {
        let done = lock.withLock { bytesByFile.values.reduce(0, +) }
        progress(Double(done) / Double(total))
    }
}

// MARK: - URLSession delegate

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let partURL: URL
    let onBytes: @Sendable (Int64) -> Void
    var continuation: CheckedContinuation<(bytes: Int64, resumeData: Data?), Error>?

    init(partURL: URL, onBytes: @Sendable @escaping (Int64) -> Void) {
        self.partURL = partURL
        self.onBytes = onBytes
        super.init()
    }

    func run(task: URLSessionDownloadTask) async throws -> (bytes: Int64, resumeData: Data?) {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            // HF may redirect to a CDN; the temp file at `location` is only valid
            // during this callback, so move it immediately.
            let expectedSize = downloadTask.countOfBytesExpectedToReceive
            if expectedSize > 0 {
                NutolaConsoleLog.nemotron("download finished — expected \(expectedSize) bytes for \(partURL.lastPathComponent)")
            }
            if FileManager.default.fileExists(atPath: partURL.path) {
                try FileManager.default.removeItem(at: partURL)
            }
            try FileManager.default.moveItem(at: location, to: partURL)
            let attrs = try FileManager.default.attributesOfItem(atPath: partURL.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            NutolaConsoleLog.nemotron("download saved \(bytes) bytes → \(partURL.lastPathComponent)")
            continuation?.resume(returning: (bytes: bytes, resumeData: nil))
        } catch {
            NutolaConsoleLog.nemotron("download save failed — \(error.localizedDescription)")
            continuation?.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onBytes(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        NutolaConsoleLog.nemotron("download task error — \(error.localizedDescription)")
        if let urlError = error as? URLError, urlError.code == .cancelled,
           let resumeData = urlError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            continuation?.resume(returning: (bytes: 0, resumeData: resumeData))
        } else {
            continuation?.resume(throwing: error)
        }
    }
}
