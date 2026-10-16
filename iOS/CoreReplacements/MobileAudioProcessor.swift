import AVFoundation
import Foundation
import OSLog

/// `AudioProcessorProtocol` on `AVAudioEngine` + `AVAudioSession` for iOS.
///
/// The engine runs for as long as the session is held (`activateSession()` …
/// `deactivateSession()`), because a running input is what keeps the app alive in
/// the background between dictations. Buffers are only written to disk between
/// `startCapture()` and `stopCapture()`.
public actor MobileAudioProcessor: AudioProcessorProtocol {
    private let logger = Logger(subsystem: "com.macparakeet.ios", category: "MobileAudioProcessor")
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    nonisolated private let sink = OSAllocatedUnfairLock<CaptureWriter?>(initialState: nil)
    nonisolated private let level = OSAllocatedUnfairLock<Float>(initialState: 0)
    private var captureURL: URL?
    private var _deviceInfo: RecordingDeviceInfo?

    /// FluidAudio requires at least 1 second of 16 kHz audio.
    private static let minimumSamples = 16_000

    public init() {}

    public var audioLevel: Float {
        level.withLock { $0 }
    }

    public var isRecording: Bool {
        captureURL != nil
    }

    public var isSessionActive: Bool {
        engine?.isRunning ?? false
    }

    public var recordingDeviceInfo: RecordingDeviceInfo? {
        _deviceInfo
    }

    public func convert(fileURL: URL) async throws -> URL {
        throw AudioProcessorError.unsupportedFormat("File transcription is not available on iOS")
    }

    public func activateSession() throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw AudioProcessorError.microphonePermissionDenied
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker]
            )
            try session.setActive(true)
        } catch {
            throw AudioProcessorError.recordingFailed("Audio session: \(error.localizedDescription)")
        }
        try startEngine()
    }

    public func deactivateSession() {
        stopEngine()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("deactivate failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Restart the engine after an interruption ends. Throws if the session cannot be reactivated.
    public func resumeAfterInterruption() throws {
        stopEngine()
        try activateSession()
    }

    public func startCapture() async throws {
        guard captureURL == nil else { return }
        if !isSessionActive {
            try activateSession()
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        let writer = try CaptureWriter(url: url)
        sink.withLock { $0 = writer }
        captureURL = url
        _deviceInfo = Self.currentDeviceInfo(format: engine?.inputNode.outputFormat(forBus: 0))
    }

    public func stopCapture() async throws -> URL {
        guard let url = captureURL else {
            throw AudioProcessorError.recordingFailed("Not recording")
        }
        captureURL = nil
        let writer = sink.withLock { current -> CaptureWriter? in
            defer { current = nil }
            return current
        }
        let samples = writer?.finish() ?? 0
        guard samples >= Self.minimumSamples else {
            try? FileManager.default.removeItem(at: url)
            throw AudioProcessorError.insufficientSamples
        }
        return url
    }

    // MARK: - Engine

    private func startEngine() throws {
        guard engine?.isRunning != true else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioProcessorError.microphoneNotAvailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [sink, level] buffer, _ in
            level.withLock { $0 = $0 * 0.3 + Self.normalizedRMS(buffer) * 0.7 }
            sink.withLock { $0?.write(buffer) }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioProcessorError.recordingFailed("Engine start: \(error.localizedDescription)")
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleConfigurationChange() }
        }
        self.engine = engine
        logger.info("engine started sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public)")
    }

    private func stopEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level.withLock { $0 = 0 }
    }

    /// Route changes (e.g. AirPods connected) stop the engine and may change the input
    /// format. Rebuild the tap; an in-progress capture keeps writing to the same file
    /// because `CaptureWriter` rebuilds its converter when the input format changes.
    private func handleConfigurationChange() {
        logger.info("engine configuration changed; restarting")
        stopEngine()
        do {
            try startEngine()
        } catch {
            logger.error("engine restart failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func currentDeviceInfo(format: AVAudioFormat?) -> RecordingDeviceInfo? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return nil }
        return RecordingDeviceInfo(
            deviceName: port.portName,
            transport: port.portType.rawValue,
            subTransport: nil,
            sampleRate: format?.sampleRate ?? 0,
            channels: format?.channelCount ?? 0,
            fallbackUsed: false
        )
    }

    private static func normalizedRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count {
            sum += data[i] * data[i]
        }
        return min(sqrtf(sum / Float(count)) * 5.0, 1.0)
    }
}

/// Converts tap buffers to 16 kHz mono Float32 and appends them to a WAV file.
/// Only touched from the audio thread while held inside `MobileAudioProcessor.sink`'s lock.
private final class CaptureWriter: @unchecked Sendable {
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sampleCount = 0

    init(url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: Self.outputFormat.settings)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard let file else { return }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.outputFormat)
        }
        guard let converter else { return }

        let capacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * Self.outputFormat.sampleRate / buffer.format.sampleRate)
        )
        guard capacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity)
        else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData else { return }
        do {
            try file.write(from: converted)
            sampleCount += Int(converted.frameLength)
        } catch {
            self.file = nil
        }
    }

    /// Closes the file and returns the number of 16 kHz samples written.
    func finish() -> Int {
        file = nil
        return sampleCount
    }
}
