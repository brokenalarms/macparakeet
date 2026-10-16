import Foundation
import Observation

/// Keyboard-side IPC client (REQ-IOS-003). Never links MacParakeetCore and never opens the
/// database; it reads session.json and writes command.json only.
@MainActor
@Observable
final class KeyboardModel {
    private(set) var viewState: KeyboardViewState = .noSession
    private(set) var notice: String?

    var hasFullAccess = false {
        didSet { refresh() }
    }

    @ObservationIgnored private let store: SessionFileStore?
    @ObservationIgnored private var issued: Set<UUID> = []
    @ObservationIgnored private var inserted: Set<UUID> = []
    @ObservationIgnored private var pendingRequestID: UUID?
    @ObservationIgnored private var observer: DarwinNotifier?
    @ObservationIgnored var insertText: (String) -> Void = { _ in }
    @ObservationIgnored var launchApp: () -> Bool = { false }

    init(store: SessionFileStore? = .appGroup) {
        self.store = store
    }

    func startObserving() {
        observer = DarwinNotifier.observe(SessionIPC.sessionChanged) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stopObserving() {
        observer = nil
    }

    func refresh() {
        let session = hasFullAccess ? store?.readSession() : nil
        viewState = KeyboardViewState.derive(hasFullAccess: hasFullAccess, session: session, issued: issued, now: Date())
        insertResultIfNeeded(session?.result)
        if let error = session?.error, let requestID = error.requestID, issued.contains(requestID) {
            notice = Self.message(for: error.code)
        }
    }

    func micTapped() {
        refresh()
        notice = nil
        switch viewState {
        case .fullAccessRequired, .busyElsewhere, .processing:
            return
        case .noSession:
            if !launchApp() {
                notice = "Open MacParakeet, then come back to dictate."
            }
        case .idle:
            send(.start, requestID: UUID())
        case .recording:
            guard let pendingRequestID else { return }
            send(.stop, requestID: pendingRequestID)
        }
    }

    func cancelTapped() {
        guard viewState == .recording, let pendingRequestID else { return }
        send(.cancel, requestID: pendingRequestID)
    }

    private func send(_ action: CommandAction, requestID: UUID) {
        guard let store else { return }
        if action == .start {
            issued.insert(requestID)
            pendingRequestID = requestID
        }
        do {
            try store.write(SessionCommand(requestID: requestID, action: action, issuedAt: Date()))
            DarwinNotifier.post(SessionIPC.commandPosted)
        } catch {
            notice = "Couldn't reach MacParakeet."
        }
    }

    private func insertResultIfNeeded(_ result: SessionResult?) {
        guard let result, let plan = ResultInsertion.plan(for: result, issued: issued, inserted: inserted) else { return }
        inserted.insert(result.requestID)
        if pendingRequestID == result.requestID {
            pendingRequestID = nil
        }
        if let text = plan.text {
            insertText(text)
        }
        if plan.appendsReturn {
            insertText("\n")
        }
    }

    private static func message(for code: SessionErrorCode) -> String {
        switch code {
        case .microphoneDenied: return "Allow the microphone in MacParakeet."
        case .modelNotReady: return "Open MacParakeet to finish downloading the speech model."
        case .audioSessionFailed: return "Couldn't start the microphone."
        case .sttFailed: return "Transcription failed. Try again."
        case .staleCommand: return "That took too long. Tap the mic again."
        case .fullAccessRequired: return "Allow Full Access for MacParakeet."
        case .appLaunchFailed: return "Open MacParakeet, then come back to dictate."
        }
    }
}
