import AppKit
import SwiftUI

/// Settings tab for choosing the transcription (ASR) engine and managing downloadable
/// models: pick Apple vs Soniqo Parakeet vs Nemotron, download weights into
/// Application Support with a live progress bar, and remove to reclaim disk space.
struct TranscriptionSettings: View {
    @Environment(\.parfaitActionColor) private var actionColor
    @AppStorage(SettingsKey.transcriptionModel) private var model: TranscriptionModel = .apple

    @State private var installed = false
    @State private var installedBytes: Int64 = 0
    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var pendingRemove = false
    @State private var freedBytes: Int64 = 0
    @State private var downloadTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Speech recognition") {
                Picker("Transcription engine", selection: $model) {
                    ForEach(TranscriptionModel.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Text(model.detail)
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
                if model.isDownloadable {
                    Text(model.supportsLiveTranscription
                         ? "Mode: live during meetings"
                         : "Mode: batch after recording")
                        .font(.parfait(11))
                        .foregroundStyle(.secondary)
                }
            }

            if model.isDownloadable {
                Section("\(model.displayName) model") {
                    modelStatusRow
                    if downloading || !installed {
                        downloadRow
                    }
                    if installed {
                        removeModelRow
                    }
                    if let error {
                        Text(error)
                            .font(.parfait(11))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    // MARK: - Rows

    private var modelStatusRow: some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: installed ? true : (downloading ? nil : false))
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.parfait(12, .medium))
                Text(statusDetail)
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if installed {
                Button("Reveal in Finder") { model.revealModelInFinder() }
                    .controlSize(.small)
            }
        }
    }

    private var statusTitle: String {
        if installed { "Installed on this Mac" }
        else if downloading { "Downloading…" }
        else { "Not downloaded yet" }
    }

    private var statusDetail: String {
        if installed {
            "Uses \(TranscriptionModel.formatBytes(installedBytes)) of disk space"
        } else if downloading {
            "\(Int(progress * 100))% complete"
        } else {
            "About \(TranscriptionModel.formatBytes(model.modelTotalBytes)) from Hugging Face"
        }
    }

    private var downloadRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if downloading {
                ProgressView(value: progress) {
                    Text("Downloading \(model.displayName)…")
                        .font(.parfait(11))
                }
                Button("Cancel download") { cancelDownload() }
                    .controlSize(.small)
            } else {
                Button("Download model") { startDownload() }
                    .buttonStyle(.borderedProminent)
                    .tint(actionColor)
                    .controlSize(.small)
                Text("Downloads once to this Mac and stays available for future meetings until you remove it.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var removeModelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if pendingRemove {
                Text("Remove this model? You'll free up \(TranscriptionModel.formatBytes(installedBytes)). You can download it again anytime.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Remove", role: .destructive) {
                        Task { await confirmRemove() }
                    }
                    .controlSize(.small)
                    Button("Cancel") { pendingRemove = false }
                        .controlSize(.small)
                }
            } else {
                Button("Remove model") { pendingRemove = true }
                    .controlSize(.small)
                if freedBytes > 0 {
                    Text("Freed \(TranscriptionModel.formatBytes(freedBytes)).")
                        .font(.parfait(11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() async {
        installed = model.isModelInstalled
        installedBytes = model.modelInstalledBytes
        if installed {
            progress = 1
            downloading = false
        }
    }

    private func startDownload() {
        downloading = true
        progress = 0
        error = nil
        model.logModelEvent("starting download")
        downloadTask = Task {
            do {
                try await model.downloadModel { fraction in
                    Task { @MainActor in progress = fraction }
                }
                await MainActor.run {
                    Task { await refresh() }
                    model.logModelEvent("model installed")
                }
            } catch is CancellationError {
                model.logModelEvent("download cancelled")
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
                model.logModelEvent("download failed — \(error.localizedDescription)")
            }
            await MainActor.run {
                downloading = false
                downloadTask = nil
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloading = false
        progress = 0
        Task { await refresh() }
    }

    private func confirmRemove() async {
        do {
            freedBytes = try model.deleteModel()
            pendingRemove = false
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
