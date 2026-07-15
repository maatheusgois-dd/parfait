import AVFoundation

enum MicRecorderError: LocalizedError {
    case alreadyRecording
    case inputUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Microphone recording is already in progress."
        case .inputUnavailable: return "No usable microphone input was found."
        }
    }
}

final class MicRecorder: @unchecked Sendable {
    var levelHandler: (@Sendable ([Float]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _levelHandler }
        set { lock.lock(); defer { lock.unlock() }; _levelHandler = newValue }
    }

    /// Fork of each captured buffer for live transcription. The sink deep-copies
    /// immediately — the buffer here is only valid during the tap callback.
    var bufferSink: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _bufferSink }
        set { lock.lock(); defer { lock.unlock() }; _bufferSink = newValue }
    }

    static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private let lock = NSLock()
    private let restartQueue = DispatchQueue(label: "parfait.mic-recorder.restart")
    private var _levelHandler: (@Sendable ([Float]) -> Void)?
    private var _bufferSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var configObserver: (any NSObjectProtocol)?
    private static let barCount = 12
    private var smoothedLevels = [Float](repeating: 0, count: barCount)

    func start(writingTo url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil else { throw MicRecorderError.alreadyRecording }

        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicRecorderError.inputUnavailable
        }

        // Apple's AAC encoder tops out at 48 kHz; higher-rate inputs go through a converter.
        let fileSampleRate = min(inputFormat.sampleRate, 48_000)
        let fileChannels = min(inputFormat.channelCount, 2)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: fileSampleRate,
                AVNumberOfChannelsKey: Int(fileChannels),
                AVEncoderBitRateKey: 128_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)

        self.engine = engine
        self.file = file

        do {
            try installTapLocked(on: engine)
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.restartQueue.async { self?.restartAfterConfigurationChange() }
            }
            engine.prepare()
            try engine.start()
        } catch {
            teardownLocked()
            throw error
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    deinit {
        stop()
    }

    // MARK: - Engine plumbing

    private func installTapLocked(on engine: AVAudioEngine) throws {
        guard let file else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicRecorderError.inputUnavailable
        }
        if format == file.processingFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: format, to: file.processingFormat) else {
                throw MicRecorderError.inputUnavailable
            }
            self.converter = converter
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
    }

    /// Default input device switched: the engine stops itself and the old tap format is stale.
    private func restartAfterConfigurationChange() {
        lock.lock()
        defer { lock.unlock() }
        guard let engine, file != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTapLocked(on: engine)
            engine.prepare()
            try engine.start()
        } catch {
            // No usable input right now; the next configuration change retries.
        }
    }

    private func teardownLocked() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        converter = nil
        file = nil // releases the writer, finalizing the .m4a
        smoothedLevels = Array(repeating: 0, count: Self.barCount)
    }

    // MARK: - Tap callback

    private func process(_ buffer: AVAudioPCMBuffer) {
        var emit: (@Sendable ([Float]) -> Void, [Float])?
        var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
        lock.lock()
        writeLocked(buffer)
        if let level = meterLocked(buffer), let handler = _levelHandler {
            emit = (handler, level)
        }
        sink = _bufferSink
        lock.unlock()
        sink?(buffer)
        if let (handler, level) = emit {
            handler(level)
        }
    }

    private func writeLocked(_ buffer: AVAudioPCMBuffer) {
        guard let file else { return }
        guard let converter else {
            try? file.write(from: buffer)
            return
        }
        let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            return
        }
        var fed = false
        var conversionError: NSError?
        // .noDataNow keeps the converter's resampler state alive across tap buffers.
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status != .error, out.frameLength > 0 {
            try? file.write(from: out)
        }
    }

    private static let meterSilenceDB: Float = -55

    private func meterLocked(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        let newLevels = Self.barLevels(from: samples, frameCount: frameCount, barCount: Self.barCount)
        for index in 0..<Self.barCount {
            let old = smoothedLevels[index]
            let new = newLevels[index]
            // Rise quickly, fall more slowly so speech feels lively.
            let smoothing: Float = new > old ? 0.75 : 0.25
            smoothedLevels[index] = old + ((new - old) * smoothing)
        }
        return smoothedLevels
    }

    /// RMS per buffer segment, mapped to 0...1 with a quiet-speech curve.
    static func barLevels(
        from samples: UnsafePointer<Float>,
        frameCount: Int,
        barCount: Int
    ) -> [Float] {
        guard frameCount > 0, barCount > 0 else {
            return Array(repeating: 0, count: max(barCount, 0))
        }

        return (0..<barCount).map { index in
            let start = index * frameCount / barCount
            let proposedEnd = (index + 1) * frameCount / barCount
            let end = min(frameCount, max(start + 1, proposedEnd))

            var sumOfSquares: Float = 0
            for frame in start..<end {
                let sample = samples[frame]
                sumOfSquares += sample * sample
            }

            let sampleCount = Float(end - start)
            let rms = sqrt(sumOfSquares / sampleCount)
            let decibels = 20 * log10(max(rms, 0.000_001))
            let normalized = max(0, min(1, (decibels - meterSilenceDB) / -meterSilenceDB))
            return powf(normalized, 0.7)
        }
    }
}
