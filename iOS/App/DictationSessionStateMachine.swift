import Foundation

/// `iOS/spec/kernel/state_machines/dictation_session.yaml`, transitions only.
enum DictationSessionPhase: Equatable, Sendable {
    case inactive
    case activating
    case ready
    case recording
    case processing
    case ended

    var ipcState: SessionState? {
        switch self {
        case .inactive, .activating: return nil
        case .ready: return .ready
        case .recording: return .recording
        case .processing: return .processing
        case .ended: return .ended
        }
    }

    var holdsAudioSession: Bool {
        switch self {
        case .ready, .recording, .processing: return true
        case .inactive, .activating, .ended: return false
        }
    }
}

enum DictationSessionEvent: Equatable, Sendable {
    case launchURLOpened
    case appSessionRequested
    case audioSessionActivated
    case audioSessionFailed
    case startCommand
    case stopCommand
    case cancelCommand
    case transcriptReady
    case transcriptEmpty
    case sttFailed
    case interruptionBegan
    case interruptionEnded
    case interruptionUnrecoverable
    case idleTimeout
    case userEndedSession
}

enum DictationSessionStateMachine {
    static func next(from phase: DictationSessionPhase, on event: DictationSessionEvent) -> DictationSessionPhase? {
        switch (phase, event) {
        case (.inactive, .launchURLOpened), (.ended, .launchURLOpened),
             (.inactive, .appSessionRequested), (.ended, .appSessionRequested):
            return .activating
        case (.activating, .audioSessionActivated):
            return .ready
        case (.activating, .audioSessionFailed):
            return .ended
        case (.ready, .startCommand):
            return .recording
        case (.ready, .idleTimeout), (.ready, .userEndedSession), (.ready, .interruptionUnrecoverable):
            return .ended
        case (.recording, .stopCommand), (.recording, .interruptionBegan):
            return .processing
        case (.recording, .cancelCommand):
            return .ready
        case (.processing, .transcriptReady), (.processing, .transcriptEmpty), (.processing, .sttFailed):
            return .ready
        case (.ready, .interruptionEnded):
            return .ready
        default:
            return nil
        }
    }
}
