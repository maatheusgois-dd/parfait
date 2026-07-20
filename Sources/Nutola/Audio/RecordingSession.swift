import AppKit
import Foundation
import SwiftUI

/// Owns the two capture paths for one meeting. Either side may fail to start
/// (missing permission, no tap grant) — a session is viable with at least one.
@MainActor
final class RecordingSession: ObservableObject {
  /// Number of bars in the live mic level meter. Drives `micBarLevels` init.
  private static let levelBarCount = 12
  /// Seconds to wait for a non-silent system-audio signal before warning the
  /// user that System Audio Recording may not be granted.
  private static let systemSignalCheckInterval: TimeInterval = 15
  /// Watchdog polls the system tap callback count this often.
  private static let systemTapWatchdogInterval: TimeInterval = 5
  /// If callbacks haven't advanced for this long, the tap is considered stalled.
  private static let systemTapWatchdogGrace: TimeInterval = 10

  let meetingID: UUID
  let startedAt = Date()
  /// Elapsed time already on the meeting before this session (continue recording).
  private let elapsedOffset: TimeInterval
  private let sourceApp: String?

  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var micBarLevels: [Float] = Array(repeating: 0, count: levelBarCount)
  /// Rolling live transcript (finalized segments) + the current in-progress
  /// fragment, updated in real time while recording. A convenience surface — the
  /// accurate, diarized transcript is still produced post-hoc by the batch pipeline.
  @Published private(set) var liveSegments: [TranscriptSegment] = []
  @Published private(set) var volatileText: String = ""
  /// Display name of whoever Zoom marks as the active remote speaker, when known.
  @Published private(set) var activeRemoteSpeaker: String?
  /// Zoom participant names captured at recording start, for the live UI.
  @Published private(set) var liveRoster: [String] = []
  /// Set when the mic engine failed to restart after an audio route change
  /// (e.g. AirPods connecting mid-recording), so the UI can warn that the mic
  /// side of the recording has gone silent. Cleared on the next successful restart.
  @Published private(set) var micRestartError: String?
  /// Set by `stop()` when neither side of the recording captured any audio
  /// (both mic and system file are zero bytes), so the UI can warn the user
  /// their microphone and system audio settings need checking.
  @Published private(set) var stopNotice: String?
  /// Bookmarks dropped during recording via the ⌃⌥B hotkey or the
  /// "Hey Nutola, mark this" voice trigger. Mirrored from the shared
  /// `TranscriptMarkerStore` so the live UI badges turns in real time.
  @Published private(set) var markers: [TranscriptMarker] = []
  private(set) var micStarted = false
  private(set) var systemStarted = false
  /// True when the local participant is muted in Zoom — the mic buffer sink is
  /// disconnected so no silent buffers reach the live transcriber or the .m4a file.
  private var micPaused = false

  private let mic = MicRecorder()
  private let tap = SystemAudioTap()
  private let archive: MeetingArchive
  private var liveTranscriber: LiveTranscriber?
  /// Per-meeting transcription locale. When non-nil, both live channels pin to
  /// this locale for the whole call; nil means "auto" (code-switching). Set via
  /// `transcriptionLocale(forMeeting:)` from `TranscriptionLocaleStore` at start.
  private var transcriptionLocale: Locale?
  private var platformSpeakerTracker: PlatformSpeakerTracker?
  private var activeObserver: NSObjectProtocol?
  private var rosterTimer: Timer?
  private var systemSignalCheck: Task<Void, Never>?
  /// Watchdog that monitors the system tap callback count. If callbacks stall
  /// (the tap died but isRunning is still true), triggers a rebuild so the
  /// system side of the recording resumes without losing the mic side.
  private var systemTapWatchdog: Task<Void, Never>?
  private var lastLivePersist = Date.distantPast
  private var ticker: Timer?

  enum SessionError: LocalizedError {
    case nothingStarted(String)
    var errorDescription: String? {
      if case .nothingStarted(let detail) = self {
        return "Could not start recording: \(detail)"
      }
      return nil
    }
  }

  init(
    meetingID: UUID,
    archive: MeetingArchive,
    elapsedOffset: TimeInterval = 0,
    sourceApp: String? = nil
  ) {
    self.meetingID = meetingID
    self.archive = archive
    self.elapsedOffset = elapsedOffset
    self.sourceApp = sourceApp
  }

  /// Pin the transcription locale for this meeting. Persists via `store` so the
  /// choice survives a resume/restart, and applies to the live transcriber
  /// immediately if it's already running (the running channels keep their
  /// current locale until `stop()`/restart; the next `start()` honors the pin).
  func setTranscriptionLocale(_ locale: Locale?, store: TranscriptionLocaleStore) {
    let id = locale.map { $0.identifier(.bcp47) }
    store.set(meetingID: meetingID.uuidString, localeIdentifier: id)
    transcriptionLocale = locale
    liveTranscriber?.localeOverride = locale
    NutolaConsoleLog.locales(
      "transcription locale \(locale.map { $0.identifier(.bcp47) } ?? "auto") for \(meetingID.uuidString.prefix(8))"
    )
  }

  /// Drop a bookmark at the current recording timestamp. Called by the
  /// ⌃⌥B hotkey (or the "Hey Nutola, mark this" voice trigger) while
  /// recording. The label is stored on the marker and the marker is
  /// mirrored to the shared `TranscriptMarkerStore` so the transcript reader
  /// badges the nearest turn.
  func addMarker(label: String = "Bookmark") {
    TranscriptMarkerStore.shared.add(
      meetingID: meetingID,
      timestamp: elapsed,
      label: label)
    markers = TranscriptMarkerStore.shared.markers(for: meetingID)
    NutolaConsoleLog.recording(
      "marker added at \(Int(elapsed))s label=\"\(label)\" meeting=\(meetingID.uuidString.prefix(8))"
    )
  }

  func start(micURL: URL, systemURL: URL, localeStore: TranscriptionLocaleStore? = nil) throws {
    MicRecorder.logAudioDeviceSnapshot(context: "session start")
    NutolaConsoleLog.recording(
      "start meeting=\(meetingID.uuidString.prefix(8)) offset=\(Int(elapsedOffset))s source=\(sourceApp ?? "manual") accessibility=\(AccessibilityPermission.isTrusted)"
    )
    if let localeStore, transcriptionLocale == nil {
      transcriptionLocale = localeStore.locale(forMeetingID: meetingID.uuidString)
    }
    var problems: [String] = []

    // Live transcription runs alongside capture. Set the buffer sinks BEFORE
    // starting the recorders so no early audio is missed; it's best-effort —
    // any failure here never affects the recording itself.
    let live = LiveTranscriber(startDate: startedAt, timeOffset: elapsedOffset)
    live.headphoneBleedMode = MicRecorder.headphoneBleedLikely
    live.localeOverride = transcriptionLocale
    if live.headphoneBleedMode {
      NutolaConsoleLog.recording("headphone bleed mode — mic bleed will attribute to Others")
    }
    live.onUpdate = { [weak self] segments, volatile in
      Task { @MainActor in self?.applyLive(segments, volatile) }
    }
    liveTranscriber = live

    // Set the local speaker's display name immediately from the macOS account
    // holder. When the Zoom roster arrives, it's refined to the Zoom display name.
    let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
    if !full.isEmpty {
      LiveTranscriber.localSpeakerName = full
    }

    mic.levelHandler = { [weak self] levels in
      Task { @MainActor in self?.micBarLevels = levels }
    }
    mic.bufferSink = { [weak live] buffer in live?.feedMic(buffer) }
    mic.onRestartFailure = { [weak self] error in
      // The mic engine failed to restart after an audio route change —
      // surface it so the UI can warn that the mic side went silent.
      Task { @MainActor in self?.micRestartError = error.localizedDescription }
    }
    tap.signalDetectedHandler = {
      AppSettings.markSystemAudioConfirmed()
      NutolaConsoleLog.recording("system audio confirmed — non-silent signal received")
    }
    tap.bufferSink = { [weak live] buffer in live?.feedSystem(buffer) }
    // Start the system audio tap FIRST. It creates a Core Audio aggregate
    // device (AudioHardwareCreateAggregateDevice) which can disrupt an
    // already-running AVAudioEngine's input node — the engine's input route
    // becomes stale and no buffers arrive. Starting the tap first means the
    // aggregate device exists before the mic engine starts, so the engine
    // binds to the correct input device.
    do {
      try tap.start(writingTo: systemURL)
      systemStarted = true
      live.systemPeakProvider = { [weak tap] in tap?.recentSystemPeak ?? 0 }
    } catch {
      let ns = error as NSError
      NutolaConsoleLog.recording(
        "system tap start failed domain=\(ns.domain) code=\(ns.code) — \(error.localizedDescription)"
      )
      problems.append("system audio: \(error.localizedDescription)")
    }
    do {
      try mic.start(writingTo: micURL, sourceApp: sourceApp)
      micStarted = true
    } catch {
      let ns = error as NSError
      NutolaConsoleLog.recording(
        "mic start failed domain=\(ns.domain) code=\(ns.code) — \(error.localizedDescription)")
      problems.append("microphone: \(error.localizedDescription)")
    }
    guard micStarted || systemStarted else {
      NutolaConsoleLog.recording("failed to start — \(problems.joined(separator: "; "))")
      throw SessionError.nothingStarted(problems.joined(separator: "; "))
    }
    NutolaConsoleLog.recording("capture mic=\(micStarted) system=\(systemStarted) live=starting")

    // Model/asset setup is async; buffers fed before it's ready are dropped.
    Task {
      do {
        try await live.start()
        NutolaConsoleLog.recording("live transcription ready")
      } catch {
        NutolaConsoleLog.recording("live transcription unavailable — \(error.localizedDescription)")
      }
    }

    if shouldTrackZoomSpeakers() {
      NutolaConsoleLog.recording(
        "Zoom speaker tracker \(AccessibilityPermission.isTrusted ? "starting" : "waiting for Accessibility")"
      )
      ensureZoomTracker()
      activeObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.ensureZoomTracker() }
      }
    }

    ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.elapsed = self.elapsedOffset + Date().timeIntervalSince(self.startedAt)
      }
    }

    if systemStarted {
      systemSignalCheck = Task { [weak self] in
        try? await Task.sleep(for: .seconds(Self.systemSignalCheckInterval))
        guard !Task.isCancelled, let self, self.systemStarted, !self.tap.signalDetected else {
          return
        }
        let input = MicRecorder.defaultInputDeviceName ?? "unknown"
        NutolaConsoleLog.recording(
          "system audio still silent after \(Int(Self.systemSignalCheckInterval))s (input=\(input)) — grant System Audio Recording in Privacy & Security → System Audio Recording Only"
        )
      }
      startSystemTapWatchdog()
    }
  }

  /// Monitors the system tap's IO callback count. If it stops advancing for
  /// more than the grace window (the tap died — common when Bluetooth output
  /// changes mid-call or the aggregate device is disrupted), triggers a
  /// rebuild so the system side of the recording resumes. The mic side is
  /// unaffected. One rebuild at a time; a rebuild that fails leaves the
  /// watchdog armed for the next interval.
  private func startSystemTapWatchdog() {
    let interval = Self.systemTapWatchdogInterval
    let grace = Self.systemTapWatchdogGrace
    systemTapWatchdog = Task { [weak self] in
      var lastCount: UInt64 = 0
      var stalledSince: Date? = nil
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled, let self, self.systemStarted else { return }
        let count = self.tap.currentCallbackCount
        if count == lastCount {
          // No new callbacks since last check — tap may have stalled.
          let since = stalledSince ?? Date()
          stalledSince = since
          if Date().timeIntervalSince(since) >= grace {
            NutolaConsoleLog.recording(
              "system tap stalled (callbacks=\(count) for \(Int(Date().timeIntervalSince(since)))s) — rebuilding"
            )
            self.tap.rebuildCapture()
            // Reset so the watchdog re-arms after the rebuild; the
            // callback count will advance if the rebuild succeeded.
            lastCount = self.tap.currentCallbackCount
            stalledSince = nil
          }
        } else {
          lastCount = count
          stalledSince = nil
        }
      }
    }
  }

  /// Applies a live-transcript update on the main actor: refreshes the observable
  /// state and persists to live.json at most every ~1.5 s (throttled so the MCP
  /// process sees a fresh file without thrashing the disk).
  private func applyLive(_ segments: [TranscriptSegment], _ volatile: String) {
    volatileText = volatile
    // The finalized transcript only ever grows, so a count change is a cheap,
    // exact "did it actually change?" test. Interim (volatile) updates arrive
    // several times a second and leave the finalized list untouched — skipping
    // the republish + full re-render + disk write on those is what keeps a
    // multi-hour meeting from getting steadily heavier as the transcript grows.
    guard segments.count != liveSegments.count else { return }
    liveSegments = segments
    let now = Date()
    if now.timeIntervalSince(lastLivePersist) >= 1.5 {
      lastLivePersist = now
      archive.saveLiveTranscript(segments, for: meetingID)
    }
  }

  /// Returns the parts that had problems starting, for the meeting notice.
  var startupNotice: String? {
    var parts: [String] = []
    switch (micStarted, systemStarted) {
    case (true, true): break
    case (false, true):
      if MicRecorder.defaultInputIsBluetooth {
        // The built-in mic fallback should have caught this, but if it
        // also failed (no built-in mic, or TCC blocked), the mic side
        // is lost. The message is source-agnostic now — Chrome/Meet and
        // Zoom all contend for the BT headset mic.
        parts.append(
          "Microphone wasn't recorded — your Bluetooth headset mic is held by the meeting app."
            + " The other side of the call was captured. To record your voice too, switch the meeting app's microphone to your Mac's built-in mic."
        )
      } else {
        parts.append(
          "Microphone wasn't recorded (permission missing?) — only the other side of the call was captured."
        )
      }
      if SystemAudioPermission.status() != .authorized {
        parts.append(
          "Grant System Audio Recording in Privacy & Security → System Audio Recording Only.")
      }
    case (true, false):
      parts.append(
        "System audio wasn't recorded — only your microphone was captured. Grant System Audio Recording in Privacy & Security."
      )
    case (false, false): break
    }
    if shouldTrackZoomSpeakers(), !AccessibilityPermission.isTrusted {
      parts.append(
        "Enable Accessibility for Nutola in Privacy & Security to label Zoom speakers by name.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  func stop() {
    NutolaConsoleLog.recording(
      "stop meeting=\(meetingID.uuidString.prefix(8)) elapsed=\(Int(elapsed))s liveSegments=\(liveSegments.count)"
    )
    systemSignalCheck?.cancel()
    systemSignalCheck = nil
    systemTapWatchdog?.cancel()
    systemTapWatchdog = nil
    ticker?.invalidate()
    ticker = nil
    if let activeObserver {
      NotificationCenter.default.removeObserver(activeObserver)
      self.activeObserver = nil
    }
    platformSpeakerTracker?.stop()
    platformSpeakerTracker = nil
    rosterTimer?.invalidate()
    rosterTimer = nil
    liveRoster = []
    LiveTranscriber.localSpeakerName = "You"
    LiveTranscriber.remoteSpeakerName = "Others"
    activeRemoteSpeaker = nil
    micBarLevels = Array(repeating: 0, count: Self.levelBarCount)
    let micURL = archive.micURL(for: meetingID)
    let systemURL = archive.systemURL(for: meetingID)
    let micHeard = micStarted ? mic.captureStats.receivedAnyBuffer : false
    let systemSignal = systemStarted ? tap.signalDetected : false
    if micStarted { mic.stop() }
    if systemStarted { tap.stop() }
    let micBytes =
      (try? FileManager.default.attributesOfItem(atPath: micURL.path)[.size] as? Int) ?? 0
    let systemBytes =
      (try? FileManager.default.attributesOfItem(atPath: systemURL.path)[.size] as? Int) ?? 0
    NutolaConsoleLog.recording(
      "capture files mic=\(micBytes)B system=\(systemBytes)B micSignal=\(micHeard) systemSignal=\(systemSignal)"
    )
    if micBytes == 0 && systemBytes == 0 {
      stopNotice = "No audio was captured — check your microphone and system audio settings"
      NutolaConsoleLog.recording("stop notice: no audio captured (both files empty)")
    } else {
      stopNotice = nil
    }
    if let live = liveTranscriber {
      liveTranscriber = nil
      // This Task inherits the main actor. After the transcribers finalize,
      // flush the last live.json; the pipeline removes it once the durable
      // transcript.json lands.
      Task {
        await live.stop()
        archive.saveLiveTranscript(liveSegments, for: meetingID)
        NutolaConsoleLog.recording("live transcript flushed (\(liveSegments.count) segments)")
      }
    }
  }

  private static func isZoom(_ sourceApp: String?) -> Bool {
    MeetingDetector.isZoomSource(sourceApp)
  }

  /// Zoom speaker tracking when source is Zoom, or Zoom's meeting UI is visible via AX.
  private func shouldTrackZoomSpeakers() -> Bool {
    if Self.isZoom(sourceApp) { return true }
    guard AccessibilityPermission.isTrusted else { return false }
    let scan = ZoomActiveSpeakerReader.scan()
    guard scan.zoomPID != nil, !scan.roster.isEmpty else { return false }
    NutolaConsoleLog.zoom(
      "inferred Zoom meeting from AX roster [\(scan.roster.joined(separator: ", "))] despite source=\(sourceApp ?? "manual")"
    )
    return true
  }

  /// Starts (or resumes) the Zoom tracker once Accessibility trust is granted.
  private func ensureZoomTracker() {
    guard shouldTrackZoomSpeakers() else {
      NutolaConsoleLog.zoom(
        "ensureZoomTracker skipped source=\(sourceApp ?? "manual") accessibility=\(AccessibilityPermission.isTrusted)"
      )
      return
    }
    if platformSpeakerTracker != nil {
      NutolaConsoleLog.zoom("ensureZoomTracker — already running")
      return
    }
    NutolaConsoleLog.zoom(
      "ensureZoomTracker — creating tracker accessibility=\(AccessibilityPermission.isTrusted)")
    let tracker = PlatformSpeakerTrackerFactory.forApp(
      bundleID: sourceApp,
      meetingID: meetingID,
      archive: archive,
      startDate: startedAt,
      elapsedOffset: elapsedOffset)
    tracker.onActiveSpeaker = { [weak self] name in
      NutolaConsoleLog.zoom("UI activeRemoteSpeaker=\(name ?? "nil")")
      self?.activeRemoteSpeaker = name
    }
    tracker.onLocalMuteChanged = { [weak self] muted in
      guard let self else { return }
      self.micPaused = muted
      if muted {
        NutolaConsoleLog.zoom("mic paused — local participant muted in Zoom")
        self.mic.bufferSink = nil
      } else {
        NutolaConsoleLog.zoom("mic resumed — local participant unmuted in Zoom")
        if let live = self.liveTranscriber {
          self.mic.bufferSink = { buffer in live.feedMic(buffer) }
        }
      }
    }
    // Poll the tracker's roster for the live UI (participant names).
    let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, let tracker = self.platformSpeakerTracker else { return }
        let roster = tracker.currentRoster()
        if roster != self.liveRoster {
          self.liveRoster = roster
          NutolaConsoleLog.zoom("live roster updated: [\(roster.joined(separator: ", "))]")
          self.updateLiveSpeakerNames(from: roster)
        }
      }
    }
    timer.tolerance = 0.5
    rosterTimer = timer
    // Bridge: LiveTranscriber queries the platform tracker's timeline to attribute
    // system-audio segments to the active speaker's name in real time.
    if let live = liveTranscriber {
      live.platformSpeakerResolver = { [weak tracker] t in
        tracker?.speakerAt(t)
      }
      NutolaConsoleLog.zoom("platformSpeakerResolver wired to LiveTranscriber")
    }
    platformSpeakerTracker = tracker
    tracker.start()

    // Do an immediate roster scan so participant names appear right away,
    // rather than waiting up to 2s for the first timer tick.
    let initialRoster = tracker.currentRoster()
    if !initialRoster.isEmpty {
      liveRoster = initialRoster
      updateLiveSpeakerNames(from: initialRoster)
    }
  }

  /// Updates `LiveTranscriber.localSpeakerName` and `.remoteSpeakerName` from the
  /// Zoom roster. The local participant is identified by matching NSFullUserName;
  /// the remote name is the single non-local participant in a 1:1 call, or
  /// "Others" when there are multiple remote participants (until the active-speaker
  /// timeline can disambiguate them).
  private func updateLiveSpeakerNames(from roster: [String]) {
    let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
    let localName =
      roster.first(where: { ZoomActiveSpeakerReader.isLocalParticipant($0) })
      ?? (full.isEmpty ? nil : full)
    let remoteNames = roster.filter { !ZoomActiveSpeakerReader.isLocalParticipant($0) }

    if let localName, !localName.isEmpty {
      LiveTranscriber.localSpeakerName = localName
      NutolaConsoleLog.zoom("local speaker name → \(localName)")
    }
    // In a 1:1 call with one remote participant, use their name directly.
    // With multiple remotes, keep "Others" — the platform speaker resolver
    // handles per-segment attribution via active-speaker tracking.
    if remoteNames.count == 1 {
      LiveTranscriber.remoteSpeakerName = remoteNames[0]
      NutolaConsoleLog.zoom("remote speaker name → \(remoteNames[0])")
    } else {
      LiveTranscriber.remoteSpeakerName = "Others"
    }
  }
}
