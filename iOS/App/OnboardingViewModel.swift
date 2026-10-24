import AVFoundation
import Foundation
import MacParakeetCore

enum MicrophonePermission: Equatable, Sendable {
    case undetermined
    case granted
    case denied
}

protocol SpeechModelProviding: Sendable {
    /// The bundled English model is in the app. Only a build without it fails this.
    var isBundledModelAvailable: Bool { get }
}

protocol MicrophonePermissionProviding: Sendable {
    var current: MicrophonePermission { get }
    func request() async -> Bool
}

/// First-run onboarding (REQ-IOS-004). Every step is derived from live state or a stored
/// flag, so onboarding resumes where it left off and never blocks reopening the app. The
/// English speech model ships in the app, so there is nothing to download.
@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: Equatable, CaseIterable {
        case model
        case microphone
        case keyboard
        case fullAccess
    }

    let isModelAvailable: Bool
    private(set) var microphone: MicrophonePermission
    private(set) var keyboardAdded: Bool
    private(set) var fullAccessExplained: Bool

    @ObservationIgnored private let mic: MicrophonePermissionProviding
    @ObservationIgnored private let defaults: UserDefaults

    init(models: SpeechModelProviding, mic: MicrophonePermissionProviding, defaults: UserDefaults = .standard) {
        self.mic = mic
        self.defaults = defaults
        isModelAvailable = models.isBundledModelAvailable
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
        case .model: return isModelAvailable
        case .microphone: return microphone == .granted
        case .keyboard: return keyboardAdded
        case .fullAccess: return fullAccessExplained
        }
    }

    func refresh() {
        microphone = mic.current
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
    let sttClient: MobileSTTClient

    var isBundledModelAvailable: Bool { sttClient.isAvailable(.english) }
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
