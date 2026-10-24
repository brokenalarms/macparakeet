import XCTest

final class SessionIPCTests: XCTestCase {
    private var store: SessionFileStore!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionIPCTests-\(UUID().uuidString)", isDirectory: true)
        store = SessionFileStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: store.directory)
    }

    func testLaunchURLRoundTrips() throws {
        let launch = SessionLaunch(requestID: UUID(), hostBundleID: "com.apple.mobilenotes")
        XCTAssertEqual(SessionLaunch(url: launch.url), launch)
    }

    func testPlainLaunchURLHasNoRequest() throws {
        let launch = try XCTUnwrap(SessionLaunch(url: SessionIPC.launchURL))
        XCTAssertNil(launch.requestID)
        XCTAssertNil(launch.hostBundleID)
        XCTAssertEqual(SessionLaunch().url, SessionIPC.launchURL)
    }

    func testOtherURLsAreNotLaunches() {
        XCTAssertNil(SessionLaunch(url: URL(string: "macparakeet://other")!))
        XCTAssertNil(SessionLaunch(url: URL(string: "https://session/start")!))
    }

    func testMalformedRequestIsDropped() throws {
        let launch = try XCTUnwrap(SessionLaunch(url: URL(string: "macparakeet://session/start?request=nope&host=")!))
        XCTAssertNil(launch.requestID)
        XCTAssertNil(launch.hostBundleID)
    }

    func testPendingLaunchStoreExpires() throws {
        let suite = "PendingLaunchStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PendingLaunchStore(defaults: defaults)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(id, now: start)
        XCTAssertEqual(store.load(now: start.addingTimeInterval(60)), id)
        XCTAssertNil(store.load(now: start.addingTimeInterval(PendingLaunchStore.lifetime + 1)))
        store.clear()
        XCTAssertNil(store.load(now: start))
    }

    func testSessionRoundTripsThroughFile() throws {
        let snapshot = SessionSnapshot(
            sessionID: UUID(),
            state: .ready,
            heartbeatAt: Date(timeIntervalSince1970: 1_700_000_000.25),
            activeRequestID: UUID(),
            result: SessionResult(requestID: UUID(), text: "hello", postAction: .returnKey, completedAt: Date(timeIntervalSince1970: 1_700_000_001)),
            error: SessionError(requestID: nil, code: .sttFailed)
        )
        try store.write(snapshot)
        XCTAssertEqual(store.readSession(), snapshot)
    }

    func testCommandRoundTripsThroughFile() throws {
        let command = SessionCommand(requestID: UUID(), action: .stop, issuedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.write(command)
        XCTAssertEqual(store.readCommand(), command)
    }

    func testWireFormatMatchesContract() throws {
        let requestID = UUID()
        try store.write(SessionSnapshot(
            sessionID: UUID(),
            state: .processing,
            heartbeatAt: Date(),
            activeRequestID: requestID,
            result: SessionResult(requestID: requestID, text: "", postAction: .returnKey, completedAt: Date()),
            error: SessionError(requestID: requestID, code: .staleCommand)
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.sessionURL)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["state"] as? String, "processing")
        XCTAssertNotNil(json["heartbeatAt"] as? String)
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(result["postAction"] as? String, "return")
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "stale_command")
    }

    func testMissingFilesReadAsNil() {
        XCTAssertNil(store.readSession())
        XCTAssertNil(store.readCommand())
    }

    func testLivenessUsesFiveSecondWindow() {
        let now = Date()
        var snapshot = SessionSnapshot(sessionID: UUID(), state: .ready, heartbeatAt: now.addingTimeInterval(-4.9))
        XCTAssertTrue(snapshot.isLive(at: now))
        snapshot.heartbeatAt = now.addingTimeInterval(-5.1)
        XCTAssertFalse(snapshot.isLive(at: now))
        snapshot.heartbeatAt = now
        snapshot.state = .ended
        XCTAssertFalse(snapshot.isLive(at: now))
    }

    func testStaleCommandsAreRejected() {
        let now = Date()
        let command = SessionCommand(requestID: UUID(), action: .start, issuedAt: now.addingTimeInterval(-10.1))
        XCTAssertEqual(CommandDecision.evaluate(command, state: .ready, activeRequestID: nil, now: now), .reject(.staleCommand))
    }

    func testStartIsAcceptedOnlyWhenReady() {
        let now = Date()
        let command = SessionCommand(requestID: UUID(), action: .start, issuedAt: now)
        XCTAssertEqual(CommandDecision.evaluate(command, state: .ready, activeRequestID: nil, now: now), .accept)
        XCTAssertEqual(CommandDecision.evaluate(command, state: .recording, activeRequestID: UUID(), now: now), .ignore)
        XCTAssertEqual(CommandDecision.evaluate(command, state: .processing, activeRequestID: UUID(), now: now), .ignore)
    }

    func testStopAndCancelRequireActiveRequestID() {
        let now = Date()
        let active = UUID()
        for action in [CommandAction.stop, .cancel] {
            let own = SessionCommand(requestID: active, action: action, issuedAt: now)
            let other = SessionCommand(requestID: UUID(), action: action, issuedAt: now)
            XCTAssertEqual(CommandDecision.evaluate(own, state: .recording, activeRequestID: active, now: now), .accept)
            XCTAssertEqual(CommandDecision.evaluate(other, state: .recording, activeRequestID: active, now: now), .ignore)
        }
    }
}
