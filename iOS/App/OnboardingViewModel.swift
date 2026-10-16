import AVFoundation
import FluidAudio
import Foundation
import MacParakeetCore

enum ModelStatus: Equatable, Sendable {
    case notDownloaded
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case downloading(message: String, progress: Double?)
    case ready
    case failed(message: String)
}

enum MicrophonePermission: Equatable, Sendable {
    case undetermined
    case granted
    case denied
}

protocol SpeechModelProviding: Sendable {
    var isDownloaded: Bool { get }
    var availableBytes: Int64 { get }
    func excludeFromBackup()
    /// Starts or joins the download + load; the stream yields until ready or failed.
    func prepare() async -> AsyncStream<ModelStatus>
}

protocol MicrophonePermissionProviding: Sendable {
    var current: MicrophonePermission { get }
    func request() async -> Bool
}

/// First-run onboarding (REQ-IOS-004). Every step is derived from live state or a stored
/// flag, so onboarding resumes where it left off and never blocks reopening the app.
@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: Equatable, CaseIterable {
        case model
        case microphone
        case keyboard
        case fullAccess
    }

    /// Parakeet TDT v3 CoreML bundle plus compile scratch space.
    static let modelBytes: Int64 = 650_000_000
    static let spaceMarginBytes: Int64 = 500_000_000

    private(set) var modelStatus: ModelStatus
    private(set) var microphone: MicrophonePermission
    private(set) var keyboardAdded: Bool
    private(set) var fullAccessExplained: Bool

    @ObservationIgnored private let models: SpeechModelProviding
    @ObservationIgnored private let mic: MicrophonePermissionProviding
    @ObservationIgnored private let defaults: UserDefaults

    init(models: SpeechModelProviding, mic: MicrophonePermissionProviding, defaults: UserDefaults = .standard) {
        self.models = models
        self.mic = mic
        self.defaults = defaults
        modelStatus = models.isDownloaded ? .ready : .notDownloaded
        microphone = mic.current
        keyboardAdded = defaults.bool(forKey: AppSettings.onboardingKeyboardAddedKey)
        fullAccessExplained = defaults.bool(forKey: AppSettings.onboardingFullAccessExplainedKey)
    }

    var currentStep: Step? {
        Step.allCases.first { !isComplete($0) }
    }

    var isFinished: Bool { currentStep == nil }

    func isComplete(_ step: Step) -> Bool {
        switch step {
        case .model: return modelStatus == .ready
        case .microphone: return microphone == .granted
        case .keyboard: return keyboardAdded
        case .fullAccess: return fullAccessExplained
        }
    }

    func refresh() {
        microphone = mic.current
        if models.isDownloaded, case .notDownloaded = modelStatus {
            modelStatus = .ready
        }
    }

    func downloadModel() async {
        switch modelStatus {
        case .downloading, .ready: return
        default: break
        }
        let required = Self.modelBytes + Self.spaceMarginBytes
        let available = models.availableBytes
        guard models.isDownloaded || available >= required else {
            modelStatus = .insufficientSpace(requiredBytes: required, availableBytes: available)
            return
        }
        models.excludeFromBackup()
        modelStatus = .downloading(message: "Preparing speech model download...", progress: nil)
        for await status in await models.prepare() {
            modelStatus = status
        }
        models.excludeFromBackup()
    }

    func requestMicrophone() async {
        _ = await mic.request()
        microphone = mic.current
    }

    func markKeyboardAdded() {
        keyboardAdded = true
        defaults.set(true, forKey: AppSettings.onboardingKeyboardAddedKey)
    }

    func markFullAccessExplained() {
        fullAccessExplained = true
        defaults.set(true, forKey: AppSettings.onboardingFullAccessExplainedKey)
    }
}

struct LiveSpeechModelProvider: SpeechModelProviding {
    let sttClient: STTClient

    var isDownloaded: Bool { STTClient.isModelCached() }

    var availableBytes: Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func excludeFromBackup() {
        var directory = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    func prepare() async -> AsyncStream<ModelStatus> {
        await sttClient.backgroundWarmUp()
        let (_, states) = await sttClient.observeWarmUpProgress()
        return AsyncStream { continuation in
            let task = Task {
                for await state in states {
                    switch state {
                    case .idle:
                        continue
                    case .working(let message, let progress):
                        continuation.yield(.downloading(message: message, progress: progress))
                    case .ready:
                        continuation.yield(.ready)
                        continuation.finish()
                        return
                    case .failed(let message):
                        continuation.yield(.failed(message: message))
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct LiveMicrophonePermission: MicrophonePermissionProviding {
    var current: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
