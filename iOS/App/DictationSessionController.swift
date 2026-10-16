import AVFoundation
import Foundation
import MacParakeetCore
import OSLog

protocol SessionAudioControlling: Sendable {
    func activateSession() async throws
    func deactivateSession() async
    func resumeAfterInterruption() async throws
}

extension MobileAudioProcessor: SessionAudioControlling {}

@MainActor
protocol SessionActivityPresenting: AnyObject {
    func show(phase: SessionActivityAttributes.Phase, idleDeadline: Date)
    func end()
}

/// Owns the host-app dictation session (REQ-IOS-002): holds the audio session, answers
/// keyboard commands over IPC, keeps the heartbeat fresh, and ends the session when idle.
@MainActor
@Observable
final class DictationSessionController {
    private(set) var phase: DictationSessionPhase = .inactive
    private(set) var activeRequestID: UUID?
    private(set) var lastResult: SessionResult?
    private(set) var lastError: SessionError?

    @ObservationIgnored private let logger = Logger(subsystem: "com.macparakeet.ios", category: "DictationSession")
    @ObservationIgnored private let audio: SessionAudioControlling
    @ObservationIgnored private let dictation: DictationServiceProtocol
    @ObservationIgnored private let store: SessionFileStore?
    @ObservationIgnored private let activity: SessionActivityPresenting
    @ObservationIgnored private let isModelReady: @Sendable () -> Bool
    @ObservationIgnored private let idleTimeout: () -> Duration
    @ObservationIgnored private let postSessionChanged: () -> Void
    @ObservationIgnored private let now: () -> Date

    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var idleDeadline = Date.distantFuture
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var commandObserver: DarwinNotifier?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    init(
        audio: SessionAudioControlling,
        dictation: DictationServiceProtocol,
        store: SessionFileStore?,
        activity: SessionActivityPresenting,
        isModelReady: @escaping @Sendable () -> Bool,
        idleTimeout: @escaping () -> Duration,
        postSessionChanged: @escaping () -> Void = { DarwinNotifier.post(SessionIPC.sessionChanged) },
        now: @escaping () -> Date = Date.init
    ) {
        self.audio = audio
        self.dictation = dictation
        self.store = store
        self.activity = activity
        self.isModelReady = isModelReady
        self.idleTimeout = idleTimeout
        self.postSessionChanged = postSessionChanged
        self.now = now
    }

    /// Subscribe to keyboard commands and audio interruptions. Not called by tests.
    func startObserving() {
        commandObserver = DarwinNotifier.observe(SessionIPC.commandPosted) { [weak self] in
            Task { @MainActor in await self?.handleCommandPosted() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            Task { @MainActor in
                if began {
                    await self?.interruptionBegan()
                } else {
                    await self?.interruptionEnded()
                }
            }
        }
    }

    // MARK: - Entry points

    func handle(url: URL) async {
        guard url.scheme == SessionIPC.launchURL.scheme,
              url.host() == SessionIPC.launchURL.host(),
              url.path() == SessionIPC.launchURL.path()
        else { return }
        if phase.holdsAudioSession {
            enterReady()
            return
        }
        await activate(via: .launchURLOpened)
    }

    func startInApp() async {
        if !phase.holdsAudioSession {
            await activate(via: .appSessionRequested)
        }
        await start(requestID: UUID())
    }

    func stopInApp() async {
        guard let activeRequestID else { return }
        await stop(requestID: activeRequestID)
    }

    func cancelInApp() async {
        guard let activeRequestID else { return }
        await cancel(requestID: activeRequestID)
    }

    func endSession() async {
        guard transition(.userEndedSession) else { return }
        await didEnd()
    }

    func handleCommandPosted() async {
        guard let command = store?.readCommand(), let state = phase.ipcState else { return }
        switch CommandDecision.evaluate(command, state: state, activeRequestID: activeRequestID, now: now()) {
        case .ignore:
            return
        case .reject(let code):
            report(SessionError(requestID: command.requestID, code: code))
        case .accept:
            switch command.action {
            case .start: await start(requestID: command.requestID)
            case .stop: await stop(requestID: command.requestID)
            case .cancel: await cancel(requestID: command.requestID)
            }
        }
    }

    func interruptionBegan() async {
        resumeAfterInterruption = true
        guard phase == .recording, let activeRequestID else { return }
        await finishRecording(requestID: activeRequestID, via: .interruptionBegan)
    }

    func interruptionEnded() async {
        guard resumeAfterInterruption else { return }
        resumeAfterInterruption = false
        guard phase == .ready else { return }
        do {
            try await audio.resumeAfterInterruption()
            transition(.interruptionEnded)
            enterReady()
        } catch {
            logger.error("resume after interruption failed error=\(error.localizedDescription, privacy: .public)")
            report(SessionError(requestID: nil, code: .audioSessionFailed))
            guard transition(.interruptionUnrecoverable) else { return }
            await didEnd()
        }
    }

    func idleTimeoutElapsed() async {
        guard transition(.idleTimeout) else { return }
        await didEnd()
    }

    // MARK: - Transitions

    private func activate(via event: DictationSessionEvent) async {
        guard transition(event) else { return }
        sessionID = UUID()
        lastError = nil
        do {
            try await audio.activateSession()
            transition(.audioSessionActivated)
            enterReady()
        } catch {
            logger.error("activate failed error=\(error.localizedDescription, privacy: .public)")
            let code: SessionErrorCode = if case AudioProcessorError.microphonePermissionDenied = error {
                .microphoneDenied
            } else {
                .audioSessionFailed
            }
            lastError = SessionError(requestID: nil, code: code)
            transition(.audioSessionFailed)
            await didEnd()
        }
    }

    private func start(requestID: UUID) async {
        guard phase == .ready else { return }
        guard isModelReady() else {
            report(SessionError(requestID: requestID, code: .modelNotReady))
            return
        }
        activeRequestID = requestID
        lastError = nil
        transition(.startCommand)
        do {
            try await dictation.startRecording()
        } catch {
            logger.error("startRecording failed error=\(error.localizedDescription, privacy: .public)")
            lastError = SessionError(requestID: requestID, code: .audioSessionFailed)
            transition(.cancelCommand)
            activeRequestID = nil
            enterReady()
        }
    }

    private func stop(requestID: UUID) async {
        guard phase == .recording, requestID == activeRequestID else { return }
        await finishRecording(requestID: requestID, via: .stopCommand)
    }

    private func cancel(requestID: UUID) async {
        guard phase == .recording, requestID == activeRequestID else { return }
        await dictation.confirmCancel()
        activeRequestID = nil
        transition(.cancelCommand)
        enterReady()
    }

    private func finishRecording(requestID: UUID, via event: DictationSessionEvent) async {
        transition(event)
        do {
            let result = try await dictation.stopRecording()
            lastResult = SessionResult(
                requestID: requestID,
                text: result.dictation.cleanTranscript ?? result.dictation.rawTranscript,
                postAction: result.postPasteAction.flatMap { PostAction(rawValue: $0.rawValue) },
                completedAt: now()
            )
            activeRequestID = nil
            transition(.transcriptReady)
        } catch {
            activeRequestID = nil
            if Self.isEmptyTranscript(error) {
                lastResult = SessionResult(requestID: requestID, text: "", postAction: nil, completedAt: now())
                transition(.transcriptEmpty)
            } else {
                logger.error("stopRecording failed error=\(error.localizedDescription, privacy: .public)")
                lastError = SessionError(requestID: requestID, code: .sttFailed)
                transition(.sttFailed)
            }
        }
        enterReady()
    }

    /// Applies a state-machine transition and publishes it; returns false if the event is not valid here.
    @discardableResult
    private func transition(_ event: DictationSessionEvent) -> Bool {
        guard let next = DictationSessionStateMachine.next(from: phase, on: event) else {
            logger.debug("ignored event=\(String(describing: event), privacy: .public) phase=\(String(describing: self.phase), privacy: .public)")
            return false
        }
        phase = next
        if next != .ready {
            idleTask?.cancel()
            idleTask = nil
        }
        publish()
        return true
    }

    private func enterReady() {
        guard phase == .ready else { return }
        idleTask?.cancel()
        let timeout = idleTimeout()
        idleDeadline = now().addingTimeInterval(TimeInterval(timeout.components.seconds))
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.idleTimeoutElapsed()
        }
        startHeartbeat()
        publish()
    }

    private func didEnd() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        idleTask?.cancel()
        idleTask = nil
        activeRequestID = nil
        await audio.deactivateSession()
        activity.end()
        publish()
    }

    private func report(_ error: SessionError) {
        lastError = error
        publish()
    }

    // MARK: - Publishing

    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SessionIPC.heartbeatInterval)
                guard let self, self.phase.holdsAudioSession else { return }
                self.writeSnapshot()
            }
        }
    }

    private func publish() {
        writeSnapshot()
        postSessionChanged()
        if let activityPhase = phase.activityPhase {
            activity.show(phase: activityPhase, idleDeadline: idleDeadline)
        }
    }

    private func writeSnapshot() {
        guard let state = phase.ipcState, let store else { return }
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            state: state,
            heartbeatAt: now(),
            activeRequestID: activeRequestID,
            result: lastResult,
            error: lastError
        )
        do {
            try store.write(snapshot)
        } catch {
            logger.error("session write failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func isEmptyTranscript(_ error: Error) -> Bool {
        if case DictationServiceError.emptyTranscript = error { return true }
        if case AudioProcessorError.insufficientSamples = error { return true }
        return false
    }
}

private extension DictationSessionPhase {
    var activityPhase: SessionActivityAttributes.Phase? {
        switch self {
        case .ready: return .ready
        case .recording: return .recording
        case .processing: return .processing
        case .inactive, .activating, .ended: return nil
        }
    }
}
