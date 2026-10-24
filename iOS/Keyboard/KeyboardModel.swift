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
    @ObservationIgnored private let pending: PendingLaunchStore
    @ObservationIgnored var insertText: (String) -> Void = { _ in }
    /// Opens the host app with the given launch URL; false when no launch path was found.
    @ObservationIgnored var launchApp: (URL) -> Bool = { _ in false }
    /// The app the keyboard is typing in, when iOS still exposes it.
    @ObservationIgnored var hostBundleID: () -> String? = { nil }

    init(store: SessionFileStore? = .appGroup, pending: PendingLaunchStore = PendingLaunchStore()) {
        self.store = store
        self.pending = pending
        // A launch from an earlier keyboard instance may still be recording.
        if let requestID = pending.load() {
            issued.insert(requestID)
            pendingRequestID = requestID
        }
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
            launchAndStart()
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

    /// Writes the start command, then opens the app with its request ID so the app starts
    /// recording and sends the user straight back (REQ-IOS-007). Not posted as a signal:
    /// the app reads it when the launch URL arrives.
    private func launchAndStart() {
        let requestID = UUID()
        if let store {
            try? store.write(SessionCommand(requestID: requestID, action: .start, issuedAt: Date()))
        }
        issued.insert(requestID)
        pendingRequestID = requestID
        pending.save(requestID)
        let launch = SessionLaunch(requestID: requestID, hostBundleID: hostBundleID())
        if !launchApp(launch.url) {
            notice = "Open MacParakeet, then come back to dictate."
        }
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
        if pending.load() == result.requestID {
            pending.clear()
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
