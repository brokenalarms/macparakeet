import MacParakeetCore
import XCTest

@MainActor
final class DictationSessionControllerTests: XCTestCase {
    private var store: SessionFileStore!
    private var audio: MockSessionAudio!
    private var dictation: MockDictationService!
    private var activity: MockActivity!
    private var modelReady: LockedFlag!
    private var clock: Date!
    private var sessionChangedCount = 0

    override func setUp() async throws {
        store = SessionFileStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionControllerTests-\(UUID().uuidString)", isDirectory: true))
        audio = MockSessionAudio()
        dictation = MockDictationService()
        activity = MockActivity()
        modelReady = LockedFlag(true)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        sessionChangedCount = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: store.directory)
    }

    private func makeController() -> DictationSessionController {
        let modelReady = modelReady!
        return DictationSessionController(
            audio: audio,
            dictation: dictation,
            store: store,
            activity: activity,
            isModelReady: { modelReady.value },
            idleTimeout: { .seconds(3600) },
            postSessionChanged: { [weak self] in self?.sessionChangedCount += 1 },
            now: { [unowned self] in self.clock }
        )
    }

    private func readyController() async -> DictationSessionController {
        let controller = makeController()
        await controller.handle(url: SessionIPC.launchURL)
        return controller
    }

    private func post(_ action: CommandAction, requestID: UUID, to controller: DictationSessionController, age: TimeInterval = 0) async throws {
        try store.write(SessionCommand(requestID: requestID, action: action, issuedAt: clock.addingTimeInterval(-age)))
        await controller.handleCommandPosted()
    }

    // MARK: - Activation

    func testLaunchURLActivatesSessionAndPublishesReady() async throws {
        let controller = await readyController()
        XCTAssertEqual(controller.phase, .ready)
        let activations = await audio.activations
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(store.readSession()?.state, .ready)
        XCTAssertEqual(store.readSession()?.heartbeatAt, clock)
        XCTAssertEqual(activity.shown.last, .ready)
        XCTAssertGreaterThan(sessionChangedCount, 0)
    }

    func testUnrelatedURLIsIgnored() async {
        let controller = makeController()
        await controller.handle(url: URL(string: "macparakeet://other")!)
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertNil(store.readSession())
    }

    // MARK: - Keyboard launch (REQ-IOS-007)

    func testLaunchWithRequestStartsRecordingThatRequest() async throws {
        let controller = makeController()
        let requestID = UUID()
        try store.write(SessionCommand(requestID: requestID, action: .start, issuedAt: clock))
        let launch = await controller.handle(url: SessionLaunch(requestID: requestID, hostBundleID: "com.apple.MobileSMS").url)
        XCTAssertEqual(launch, SessionLaunch(requestID: requestID, hostBundleID: "com.apple.MobileSMS"))
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertTrue(controller.isRecording(requestID: requestID))
        XCTAssertEqual(store.readSession()?.activeRequestID, requestID)
    }

    func testLaunchWithRequestStartsRecordingInLiveSession() async throws {
        let controller = await readyController()
        let requestID = UUID()
        try store.write(SessionCommand(requestID: requestID, action: .start, issuedAt: clock))
        await controller.handle(url: SessionLaunch(requestID: requestID).url)
        XCTAssertTrue(controller.isRecording(requestID: requestID))
    }

    func testLaunchWithStaleCommandStaysReadyAndReportsError() async throws {
        let controller = makeController()
        let requestID = UUID()
        try store.write(SessionCommand(requestID: requestID, action: .start, issuedAt: clock.addingTimeInterval(-11)))
        await controller.handle(url: SessionLaunch(requestID: requestID).url)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(store.readSession()?.error, SessionError(requestID: requestID, code: .staleCommand))
    }

    func testLaunchWithMismatchedCommandOnlyActivates() async throws {
        let controller = makeController()
        try store.write(SessionCommand(requestID: UUID(), action: .start, issuedAt: clock))
        let requestID = UUID()
        await controller.handle(url: SessionLaunch(requestID: requestID).url)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertFalse(controller.isRecording(requestID: requestID))
    }

    func testMicrophoneDeniedEndsSessionWithError() async {
        await audio.setActivationError(AudioProcessorError.microphonePermissionDenied)
        let controller = await readyController()
        XCTAssertEqual(controller.phase, .ended)
        XCTAssertEqual(store.readSession()?.state, .ended)
        XCTAssertEqual(store.readSession()?.error?.code, .microphoneDenied)
    }

    func testAudioSessionFailureEndsSession() async {
        await audio.setActivationError(AudioProcessorError.recordingFailed("busy"))
        let controller = await readyController()
        XCTAssertEqual(controller.phase, .ended)
        XCTAssertEqual(controller.lastError?.code, .audioSessionFailed)
    }

    func testRelaunchAfterEndedActivatesNewSession() async throws {
        let controller = await readyController()
        let firstSessionID = try XCTUnwrap(store.readSession()?.sessionID)
        await controller.idleTimeoutElapsed()
        await controller.handle(url: SessionIPC.launchURL)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertNotEqual(store.readSession()?.sessionID, firstSessionID)
    }

    // MARK: - Commands

    func testStartAndStopProduceResultForRequest() async throws {
        let controller = await readyController()
        let requestID = UUID()
        try await post(.start, requestID: requestID, to: controller)
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(store.readSession()?.state, .recording)
        XCTAssertEqual(store.readSession()?.activeRequestID, requestID)
        XCTAssertEqual(activity.shown.last, .recording)

        await dictation.setStopResult(.success(DictationResult(
            dictation: Dictation(durationMs: 1000, rawTranscript: "um hello", cleanTranscript: "Hello"),
            postPasteAction: .returnKey
        )))
        try await post(.stop, requestID: requestID, to: controller)

        XCTAssertEqual(controller.phase, .ready)
        let session = try XCTUnwrap(store.readSession())
        XCTAssertEqual(session.state, .ready)
        XCTAssertNil(session.activeRequestID)
        XCTAssertEqual(session.result?.requestID, requestID)
        XCTAssertEqual(session.result?.text, "Hello")
        XCTAssertEqual(session.result?.postAction, .returnKey)
    }

    func testRawTranscriptUsedWhenNoCleanTranscript() async throws {
        let controller = await readyController()
        await dictation.setStopResult(.success(DictationResult(dictation: Dictation(durationMs: 1000, rawTranscript: "raw text"))))
        let requestID = UUID()
        try await post(.start, requestID: requestID, to: controller)
        try await post(.stop, requestID: requestID, to: controller)
        XCTAssertEqual(store.readSession()?.result?.text, "raw text")
        XCTAssertNil(store.readSession()?.result?.postAction)
    }

    func testEmptyTranscriptWritesEmptyResultWithoutError() async throws {
        let controller = await readyController()
        await dictation.setStopResult(.failure(DictationServiceError.emptyTranscript))
        let requestID = UUID()
        try await post(.start, requestID: requestID, to: controller)
        try await post(.stop, requestID: requestID, to: controller)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(store.readSession()?.result?.text, "")
        XCTAssertNil(store.readSession()?.error)
    }

    func testTooShortRecordingIsTreatedAsEmpty() async throws {
        let controller = await readyController()
        await dictation.setStopResult(.failure(AudioProcessorError.insufficientSamples))
        let requestID = UUID()
        try await post(.start, requestID: requestID, to: controller)
        try await post(.stop, requestID: requestID, to: controller)
        XCTAssertEqual(store.readSession()?.result?.text, "")
        XCTAssertNil(store.readSession()?.error)
    }

    func testSTTFailureReportsErrorAndReturnsToReady() async throws {
        let controller = await readyController()
        await dictation.setStopResult(.failure(STTError.transcriptionFailed("boom")))
        let requestID = UUID()
        try await post(.start, requestID: requestID, to: controller)
        try await post(.stop, requestID: requestID, to: controller)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(store.readSession()?.error, SessionError(requestID: requestID, code: .sttFailed))
    }

    func testCancelDiscardsRecording() async throws {
        let controller = await readyController()
        let requestID = UUID()
        try await post(.start, requestID: requestID, to: controller)
        try await post(.cancel, requestID: requestID, to: controller)
        XCTAssertEqual(controller.phase, .ready)
        let cancels = await dictation.confirmCancelCount
        XCTAssertEqual(cancels, 1)
        XCTAssertNil(store.readSession()?.result)
    }

    func testStopFromAnotherRequestIsIgnored() async throws {
        let controller = await readyController()
        try await post(.start, requestID: UUID(), to: controller)
        try await post(.stop, requestID: UUID(), to: controller)
        XCTAssertEqual(controller.phase, .recording)
    }

    func testStaleCommandReportsError() async throws {
        let controller = await readyController()
        let requestID = UUID()
        try await post(.start, requestID: requestID, to: controller, age: 11)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(store.readSession()?.error, SessionError(requestID: requestID, code: .staleCommand))
    }

    func testStartWithoutModelReportsModelNotReady() async throws {
        modelReady.value = false
        let controller = await readyController()
        let requestID = UUID()
        try await post(.start, requestID: requestID, to: controller)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(store.readSession()?.error, SessionError(requestID: requestID, code: .modelNotReady))
        let starts = await dictation.startCount
        XCTAssertEqual(starts, 0)
    }

    func testCommandsIgnoredWithoutSession() async throws {
        let controller = makeController()
        try await post(.start, requestID: UUID(), to: controller)
        XCTAssertEqual(controller.phase, .inactive)
    }

    // MARK: - Session lifetime

    func testIdleTimeoutEndsSession() async {
        let controller = await readyController()
        await controller.idleTimeoutElapsed()
        XCTAssertEqual(controller.phase, .ended)
        XCTAssertEqual(store.readSession()?.state, .ended)
        let deactivations = await audio.deactivations
        XCTAssertEqual(deactivations, 1)
        XCTAssertEqual(activity.endCount, 1)
    }

    func testIdleTimeoutIgnoredWhileRecording() async throws {
        let controller = await readyController()
        try await post(.start, requestID: UUID(), to: controller)
        await controller.idleTimeoutElapsed()
        XCTAssertEqual(controller.phase, .recording)
    }

    func testUserCanEndSessionWhenReady() async {
        let controller = await readyController()
        await controller.endSession()
        XCTAssertEqual(controller.phase, .ended)
        XCTAssertEqual(activity.endCount, 1)
    }

    func testInAppDictationActivatesSessionAndRecords() async {
        let controller = makeController()
        await controller.startInApp()
        XCTAssertEqual(controller.phase, .recording)
        await dictation.setStopResult(.success(DictationResult(dictation: Dictation(durationMs: 1000, rawTranscript: "in app"))))
        await controller.stopInApp()
        XCTAssertEqual(controller.lastResult?.text, "in app")
        XCTAssertEqual(controller.phase, .ready)
    }

    // MARK: - Interruptions

    func testInterruptionDuringRecordingTranscribesCapturedAudio() async throws {
        let controller = await readyController()
        await dictation.setStopResult(.success(DictationResult(dictation: Dictation(durationMs: 1000, rawTranscript: "partial"))))
        let requestID = UUID()
        try await post(.start, requestID: requestID, to: controller)
        await controller.interruptionBegan()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(store.readSession()?.result?.requestID, requestID)
        XCTAssertEqual(store.readSession()?.result?.text, "partial")
    }

    func testInterruptionEndedResumesAudio() async {
        let controller = await readyController()
        await controller.interruptionBegan()
        await controller.interruptionEnded()
        XCTAssertEqual(controller.phase, .ready)
        let resumes = await audio.resumes
        XCTAssertEqual(resumes, 1)
    }

    func testUnrecoverableInterruptionEndsSession() async {
        let controller = await readyController()
        await audio.setResumeError(AudioProcessorError.recordingFailed("gone"))
        await controller.interruptionBegan()
        await controller.interruptionEnded()
        XCTAssertEqual(controller.phase, .ended)
        XCTAssertEqual(store.readSession()?.state, .ended)
        XCTAssertEqual(activity.endCount, 1)
    }
}

final class DictationSessionStateMachineTests: XCTestCase {
    func testTransitionsMatchKernelStateMachine() {
        let expected: [(DictationSessionPhase, DictationSessionEvent, DictationSessionPhase)] = [
            (.inactive, .launchURLOpened, .activating),
            (.ended, .launchURLOpened, .activating),
            (.inactive, .appSessionRequested, .activating),
            (.ended, .appSessionRequested, .activating),
            (.activating, .audioSessionActivated, .ready),
            (.activating, .audioSessionFailed, .ended),
            (.ready, .startCommand, .recording),
            (.ready, .idleTimeout, .ended),
            (.ready, .userEndedSession, .ended),
            (.ready, .interruptionUnrecoverable, .ended),
            (.recording, .stopCommand, .processing),
            (.recording, .cancelCommand, .ready),
            (.recording, .interruptionBegan, .processing),
            (.processing, .transcriptReady, .ready),
            (.processing, .transcriptEmpty, .ready),
            (.processing, .sttFailed, .ready),
            (.ready, .interruptionEnded, .ready),
        ]
        for (from, event, to) in expected {
            XCTAssertEqual(DictationSessionStateMachine.next(from: from, on: event), to, "\(from) + \(event)")
        }
    }

    func testEndedIsTerminalExceptForRelaunch() {
        let events: [DictationSessionEvent] = [.startCommand, .stopCommand, .idleTimeout, .audioSessionActivated, .interruptionEnded]
        for event in events {
            XCTAssertNil(DictationSessionStateMachine.next(from: .ended, on: event), "\(event)")
        }
    }

    func testRecordingIgnoresIdleTimeout() {
        XCTAssertNil(DictationSessionStateMachine.next(from: .recording, on: .idleTimeout))
        XCTAssertNil(DictationSessionStateMachine.next(from: .processing, on: .idleTimeout))
    }
}

// MARK: - Mocks

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

actor MockSessionAudio: SessionAudioControlling {
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var resumes = 0
    private var activationError: Error?
    private var resumeError: Error?

    func setActivationError(_ error: Error) { activationError = error }
    func setResumeError(_ error: Error) { resumeError = error }

    func activateSession() async throws {
        activations += 1
        if let activationError { throw activationError }
    }

    func deactivateSession() async {
        deactivations += 1
    }

    func resumeAfterInterruption() async throws {
        resumes += 1
        if let resumeError { throw resumeError }
    }
}

actor MockDictationService: DictationServiceProtocol {
    private(set) var startCount = 0
    private(set) var confirmCancelCount = 0
    private var stopResult: Result<DictationResult, Error> = .failure(DictationServiceError.emptyTranscript)

    func setStopResult(_ result: Result<DictationResult, Error>) { stopResult = result }

    func startRecording(context: DictationTelemetryContext) async throws { startCount += 1 }
    func stopRecording() async throws -> DictationResult { try stopResult.get() }
    func cancelRecording(reason: TelemetryDictationCancelReason?) async {}
    func confirmCancel() async { confirmCancelCount += 1 }
    func undoCancel() async throws -> DictationResult { throw DictationServiceError.notCancelled }
    var state: DictationState { .idle }
    var audioLevel: Float { 0 }
}

@MainActor
final class MockActivity: SessionActivityPresenting {
    private(set) var shown: [SessionActivityAttributes.Phase] = []
    private(set) var endCount = 0

    func show(phase: SessionActivityAttributes.Phase, idleDeadline: Date) { shown.append(phase) }
    func end() { endCount += 1 }
}
