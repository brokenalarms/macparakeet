import Foundation

/// Keyboard UI state derived from session.json (contract `keyboard_view_state`).
/// Lives in Shared so the host app's test target can exercise it.
enum KeyboardViewState: Equatable, Sendable {
    case fullAccessRequired
    case noSession
    case idle
    case recording
    case processing
    case busyElsewhere

    static func derive(hasFullAccess: Bool, session: SessionSnapshot?, issued: Set<UUID>, now: Date) -> KeyboardViewState {
        guard hasFullAccess else { return .fullAccessRequired }
        guard let session, session.isLive(at: now) else { return .noSession }
        let ownsActive = session.activeRequestID.map(issued.contains) ?? false
        switch session.state {
        case .ended: return .noSession
        case .ready: return .idle
        case .recording: return ownsActive ? .recording : .busyElsewhere
        case .processing: return ownsActive ? .processing : .busyElsewhere
        }
    }
}

/// What the keyboard should type for a session result, honoring issued-set and de-dup rules.
struct ResultInsertion: Equatable, Sendable {
    var text: String?
    var appendsReturn: Bool

    static func plan(for result: SessionResult?, issued: Set<UUID>, inserted: Set<UUID>) -> ResultInsertion? {
        guard let result, issued.contains(result.requestID), !inserted.contains(result.requestID) else {
            return nil
        }
        return ResultInsertion(
            text: result.text.isEmpty ? nil : result.text,
            appendsReturn: result.postAction == .returnKey
        )
    }
}
