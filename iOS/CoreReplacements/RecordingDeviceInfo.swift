import Foundation

/// iOS counterpart of the struct declared in the macOS-only `Audio/AudioRecorder.swift`.
/// Must keep the same public shape: `AudioProcessorProtocol` and `TelemetryEvent` use it.
public struct RecordingDeviceInfo: Sendable, Equatable {
    public let deviceName: String
    public let transport: String
    public let subTransport: String?
    public let sampleRate: Double
    public let channels: UInt32
    public let fallbackUsed: Bool
}
