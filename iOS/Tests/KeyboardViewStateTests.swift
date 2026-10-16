import XCTest

final class KeyboardViewStateTests: XCTestCase {
    private let now = Date()

    private func session(_ state: SessionState, active: UUID? = nil, age: TimeInterval = 0) -> SessionSnapshot {
        SessionSnapshot(sessionID: UUID(), state: state, heartbeatAt: now.addingTimeInterval(-age), activeRequestID: active)
    }

    func testFullAccessRequiredWinsOverEverything() {
        XCTAssertEqual(KeyboardViewState.derive(hasFullAccess: false, session: session(.ready), issued: [], now: now), .fullAccessRequired)
    }

    func testNoSessionWhenMissingEndedOrStale() {
        XCTAssertEqual(KeyboardViewState.derive(hasFullAccess: true, session: nil, issued: [], now: now), .noSession)
        XCTAssertEqual(KeyboardViewState.derive(hasFullAccess: true, session: session(.ended), issued: [], now: now), .noSession)
        XCTAssertEqual(KeyboardViewState.derive(hasFullAccess: true, session: session(.ready, age: 6), issued: [], now: now), .noSession)
    }

    func testIdleWhenReady() {
        XCTAssertEqual(KeyboardViewState.derive(hasFullAccess: true, session: session(.ready), issued: [], now: now), .idle)
    }

    func testRecordingAndProcessingOnlyForOwnRequest() {
        let mine = UUID()
        XCTAssertEqual(KeyboardViewState.derive(hasFullAccess: true, session: session(.recording, active: mine), issued: [mine], now: now), .recording)
        XCTAssertEqual(KeyboardViewState.derive(hasFullAccess: true, session: session(.processing, active: mine), issued: [mine], now: now), .processing)
        XCTAssertEqual(KeyboardViewState.derive(hasFullAccess: true, session: session(.recording, active: UUID()), issued: [mine], now: now), .busyElsewhere)
        XCTAssertEqual(KeyboardViewState.derive(hasFullAccess: true, session: session(.processing, active: nil), issued: [mine], now: now), .busyElsewhere)
    }

    func testInsertsOnlyIssuedResultsOnce() {
        let mine = UUID()
        let result = SessionResult(requestID: mine, text: "hello", postAction: nil, completedAt: now)
        XCTAssertEqual(ResultInsertion.plan(for: result, issued: [mine], inserted: []), ResultInsertion(text: "hello", appendsReturn: false))
        XCTAssertNil(ResultInsertion.plan(for: result, issued: [mine], inserted: [mine]))
        XCTAssertNil(ResultInsertion.plan(for: result, issued: [], inserted: []))
        XCTAssertNil(ResultInsertion.plan(for: nil, issued: [mine], inserted: []))
    }

    func testEmptyTextInsertsNothing() {
        let mine = UUID()
        let result = SessionResult(requestID: mine, text: "", postAction: nil, completedAt: now)
        XCTAssertEqual(ResultInsertion.plan(for: result, issued: [mine], inserted: []), ResultInsertion(text: nil, appendsReturn: false))
    }

    func testVoiceReturnAppendsNewlineEvenWhenTextEmpty() {
        let mine = UUID()
        let withText = SessionResult(requestID: mine, text: "send it", postAction: .returnKey, completedAt: now)
        XCTAssertEqual(ResultInsertion.plan(for: withText, issued: [mine], inserted: []), ResultInsertion(text: "send it", appendsReturn: true))
        let empty = SessionResult(requestID: mine, text: "", postAction: .returnKey, completedAt: now)
        XCTAssertEqual(ResultInsertion.plan(for: empty, issued: [mine], inserted: []), ResultInsertion(text: nil, appendsReturn: true))
    }
}
