@preconcurrency import ActivityKit
import Foundation
import OSLog

@MainActor
final class SessionActivityPresenter: SessionActivityPresenting {
    private let logger = Logger(subsystem: "com.macparakeet.ios", category: "LiveActivity")
    private var activity: Activity<SessionActivityAttributes>?

    func show(phase: SessionActivityAttributes.Phase, idleDeadline: Date) {
        let state = SessionActivityAttributes.ContentState(phase: phase, idleDeadline: idleDeadline)
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: SessionActivityAttributes(), content: content)
        } catch {
            logger.error("live activity request failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
