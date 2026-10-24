import Foundation
import MacParakeetCore

/// iOS settings. Keys match the Mac app's `UserDefaults` keys so `DictationService`
/// closures read the same semantics; the stores themselves are per-device.
enum AppSettings {
    static let processingModeKey = "processingMode"
    static let saveDictationHistoryKey = "saveDictationHistory"
    static let voiceReturnEnabledKey = "voiceReturnEnabled"
    static let voiceReturnTriggerKey = "voiceReturnTrigger"
    static let idleTimeoutMinutesKey = "sessionIdleTimeoutMinutes"
    static let onboardingKeyboardAddedKey = "onboardingKeyboardAdded"
    static let onboardingFullAccessExplainedKey = "onboardingFullAccessExplained"
    static let speechModelKey = "speechModel"
    static let autoReturnKey = "autoReturnToHost"

    static let defaultIdleTimeoutMinutes = 5
    static let idleTimeoutChoices = [1, 2, 5, 10, 15, 30]
    static let defaultVoiceReturnTrigger = "press return"

    static func processingMode(_ defaults: UserDefaults = .standard) -> Dictation.ProcessingMode {
        Dictation.ProcessingMode(rawValue: defaults.string(forKey: processingModeKey) ?? "") ?? .raw
    }

    static func saveDictationHistory(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: saveDictationHistoryKey) as? Bool ?? true
    }

    static func voiceReturnTrigger(_ defaults: UserDefaults = .standard) -> String? {
        guard defaults.bool(forKey: voiceReturnEnabledKey) else { return nil }
        let trigger = (defaults.string(forKey: voiceReturnTriggerKey) ?? defaultVoiceReturnTrigger)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trigger.isEmpty ? nil : trigger
    }

    /// The chosen model; `MobileSTTClient.activeModel` falls back to English if it isn't downloaded.
    static func speechModel(_ defaults: UserDefaults = .standard) -> SpeechModel {
        SpeechModel(rawValue: defaults.string(forKey: speechModelKey) ?? "") ?? .english
    }

    /// Return to the app the keyboard was in after a keyboard launch starts recording.
    static func autoReturn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoReturnKey) as? Bool ?? true
    }

    static func idleTimeoutMinutes(_ defaults: UserDefaults = .standard) -> Int {
        let minutes = defaults.integer(forKey: idleTimeoutMinutesKey)
        return minutes > 0 ? minutes : defaultIdleTimeoutMinutes
    }
}
