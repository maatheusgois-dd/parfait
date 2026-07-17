import Accelerate
import AVFoundation
import CoreAudio

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

    /// True when the default input routes over Bluetooth (AirPods, etc.). Zoom often
    /// holds exclusive access to that mic during a call, so Nutola may fail to start.
    static var defaultInputIsBluetooth: Bool {
        defaultInputTransport == kAudioDeviceTransportTypeBluetooth
    }

    static var defaultOutputIsBluetooth: Bool {
        guard let device = defaultOutputDeviceID else { return false }
        return deviceTransport(device) == kAudioDeviceTransportTypeBluetooth
    }

    /// True when remote audio is likely bleeding into the built-in mic (BT output).
    static var headphoneBleedLikely: Bool {
        defaultOutputIsBluetooth
    }

    static var defaultInputDeviceName: String? {
        guard let device = defaultInputDeviceID else { return nil }
        return deviceName(device)
    }

    static var defaultOutputDeviceName: String? {
        guard let device = defaultOutputDeviceID else { return nil }
        return deviceName(device)
    }

    static func logAudioDeviceSnapshot(context: String) {
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        let micLabel: String = switch micAuth {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown(\(micAuth.rawValue))"
        }
        let sysLabel = SystemAudioPermission.statusLabel
        let input = defaultInputDeviceName ?? "none"
        let output = defaultOutputDeviceName ?? "none"
        let transport = defaultInputTransport.map(transportLabel) ?? "unknown"
        NutolaConsoleLog.recording(
            "\(context) micTCC=\(micLabel) systemTCC=\(sysLabel) input=[\(input)] transport=\(transport) output=[\(output)]")
    }

    struct CaptureStats: Sendable {
        var bufferCount = 0
        var framesWritten: UInt64 = 0
        var peakLevel: Float = 0
        var receivedAnyBuffer = false
    }

    private(set) var captureStats = CaptureStats()

    private static func deviceName(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr
        else { return nil }
        return name as String
    }

    private static var defaultOutputDeviceID: AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func transportLabel(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "builtIn"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        default: return "other(\(transport))"
        }
    }

    private static var defaultInputDeviceID: AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static var defaultInputTransport: UInt32? {
        guard let device = defaultInputDeviceID else { return nil }
        return deviceTransport(device)
    }

    private static func deviceTransport(_ device: AudioObjectID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr
        else { return nil }
        return transport
    }

    private static func builtInInputDevice() -> AudioObjectID? {
        for device in allInputDevices() {
            guard deviceTransport(device) == kAudioDeviceTransportTypeBuiltIn,
                  let name = deviceName(device),
                  name.localizedCaseInsensitiveContains("microphone")
            else { continue }
            return device
        }
        return allInputDevices().first { deviceTransport($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    private static func allInputDevices() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var devices = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices.filter { inputChannelCount($0) > 0 }
    }

    private static func inputChannelCount(_ device: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr
        else { return 0 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    private static func setDefaultInputDevice(_ device: AudioObjectID) throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceCopy = device
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.stride), &deviceCopy)
        guard status == noErr else { throw MicRecorderError.inputUnavailable }
    }

    private static func restoreDefaultInputDevice(_ device: AudioObjectID) {
        try? setDefaultInputDevice(device)
    }

    private static func fourCC(_ code: Int) -> String {
        let v = UInt32(truncatingIfNeeded: code)
        return String(bytes: [
            UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
        ], encoding: .ascii) ?? "?"
    }

    private let lock = NSLock()
    private let restartQueue = DispatchQueue(label: "nutola.mic-recorder.restart")
    private var _levelHandler: (@Sendable ([Float]) -> Void)?
    private var _bufferSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var configObserver: (any NSObjectProtocol)?
    private static let barCount = 12
    private var smoothedLevels = [Float](repeating: 0, count: barCount)
    /// When we temporarily switch HAL default input for a built-in fallback.
    private var savedDefaultInputDevice: AudioObjectID?
    private var activeInputDeviceName: String?

    func start(writingTo url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil else { throw MicRecorderError.alreadyRecording }

        captureStats = CaptureStats()
        savedDefaultInputDevice = nil
        activeInputDeviceName = nil
        Self.logAudioDeviceSnapshot(context: "mic start")

        do {
            try startEngineLocked(writingTo: url)
        } catch {
            guard Self.defaultInputIsBluetooth, let builtIn = Self.builtInInputDevice(),
                  let previous = Self.defaultInputDeviceID
            else { throw error }
            let builtInName = Self.deviceName(builtIn) ?? "built-in"
            NutolaConsoleLog.recording(
                "mic BT engine failed — retrying with [\(builtInName)] (Zoom keeps the headset mic)")
            teardownLocked()
            try Self.setDefaultInputDevice(builtIn)
            savedDefaultInputDevice = previous
            do {
                try startEngineLocked(writingTo: url)
                activeInputDeviceName = builtInName
                NutolaConsoleLog.recording("mic started on built-in fallback [\(builtInName)]")
            } catch let fallbackError {
                Self.restoreDefaultInputDevice(previous)
                savedDefaultInputDevice = nil
                throw fallbackError
            }
        }
    }

    private func startEngineLocked(writingTo url: URL) throws {
        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let inputName = Self.defaultInputDeviceName ?? "unknown"
        NutolaConsoleLog.recording(
            "mic engine format device=[\(inputName)] sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)")
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            NutolaConsoleLog.recording("mic input unavailable — zero sample rate or channels")
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
        activeInputDeviceName = inputName

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
            NutolaConsoleLog.recording(
                "mic engine started device=[\(inputName)] fileRate=\(file.processingFormat.sampleRate)")
        } catch {
            let ns = error as NSError
            NutolaConsoleLog.recording(
                "mic engine failed device=[\(inputName)] domain=\(ns.domain) code=\(ns.code) fourCC=\(Self.fourCC(ns.code)) — \(error.localizedDescription)")
            teardownLocked()
            throw error
        }
    }

    func stop() {
        lock.lock()
        let stats = captureStats
        let device = activeInputDeviceName ?? "unknown"
        let saved = savedDefaultInputDevice
        lock.unlock()
        NutolaConsoleLog.recording(
            "mic stop device=[\(device)] buffers=\(stats.bufferCount) frames=\(stats.framesWritten) peak=\(String(format: "%.4f", stats.peakLevel)) heard=\(stats.receivedAnyBuffer)")
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
        if let saved {
            Self.restoreDefaultInputDevice(saved)
            savedDefaultInputDevice = nil
            NutolaConsoleLog.recording("mic restored default input device")
        }
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
            NutolaConsoleLog.recording("mic restart after config change failed — \(error.localizedDescription)")
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
        var logFirst = false
        var logHeartbeat = false
        lock.lock()
        captureStats.bufferCount += 1
        captureStats.framesWritten += UInt64(buffer.frameLength)
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(buffer.frameLength))
            captureStats.peakLevel = max(captureStats.peakLevel, peak)
            if !captureStats.receivedAnyBuffer {
                captureStats.receivedAnyBuffer = true
                logFirst = true
            } else if captureStats.bufferCount % 500 == 0 {
                logHeartbeat = true
            }
        }
        writeLocked(buffer)
        if let level = meterLocked(buffer), let handler = _levelHandler {
            emit = (handler, level)
        }
        sink = _bufferSink
        let firstPeak = captureStats.peakLevel
        let bufCount = captureStats.bufferCount
        lock.unlock()
        if logFirst {
            NutolaConsoleLog.recording(
                "mic first buffer frames=\(buffer.frameLength) peak=\(String(format: "%.4f", firstPeak))")
        } else if logHeartbeat {
            NutolaConsoleLog.recording(
                "mic heartbeat buffers=\(bufCount) peak=\(String(format: "%.4f", firstPeak))")
        }
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
