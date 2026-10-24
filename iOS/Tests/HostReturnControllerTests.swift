import XCTest

@MainActor
final class HostReturnControllerTests: XCTestCase {
    private let launchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testKeyboardHostWinsOverObserver() async {
        let observer = MockObserver(host: "com.tinyspeck.chatlyio")
        let opener = MockOpener(results: [true])
        let controller = makeController(observer: observer, opener: opener)
        await controller.returnToHost(keyboardHost: "com.apple.MobileSMS", launchedAt: launchedAt)
        XCTAssertEqual(opener.opened, [URL(string: "sms://")!])
        XCTAssertEqual(controller.status, .returned(hostName: "Messages"))
        XCTAssertEqual(observer.queries, 0)
    }

    func testObserverHostUsedWhenKeyboardCannotSeeHost() async {
        let observer = MockObserver(host: "com.apple.mobilenotes")
        let opener = MockOpener(results: [true])
        let controller = makeController(observer: observer, opener: opener)
        await controller.returnToHost(keyboardHost: nil, launchedAt: launchedAt)
        XCTAssertEqual(opener.opened, [URL(string: "mobilenotes://")!])
        XCTAssertEqual(controller.status, .returned(hostName: "Notes"))
        XCTAssertEqual(observer.lastSince, launchedAt.addingTimeInterval(-HostReturnController.observerLookBack))
    }

    func testUnknownHostNeedsManualReturn() async {
        let opener = MockOpener(results: [])
        let controller = makeController(observer: MockObserver(host: "com.example.unlisted"), opener: opener)
        await controller.returnToHost(keyboardHost: nil, launchedAt: launchedAt)
        XCTAssertEqual(controller.status, .manual(hostName: nil))
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testOwnAppIsNeverAReturnTarget() async {
        let opener = MockOpener(results: [true])
        let controller = makeController(observer: MockObserver(host: nil), opener: opener, appBundleID: "com.macparakeet.ios")
        await controller.returnToHost(keyboardHost: "com.macparakeet.ios.keyboard", launchedAt: launchedAt)
        XCTAssertEqual(controller.status, .manual(hostName: nil))
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testFailedOpenWhileLaunchingIsRetried() async {
        let opener = MockOpener(results: [false, true], active: false)
        let controller = makeController(observer: nil, opener: opener)
        await controller.returnToHost(keyboardHost: "com.apple.MobileSMS", launchedAt: launchedAt)
        XCTAssertEqual(opener.opened.count, 2)
        XCTAssertEqual(controller.status, .returned(hostName: "Messages"))
    }

    func testFailedOpenWhileActiveIsFinal() async {
        let opener = MockOpener(results: [false, true], active: true)
        let controller = makeController(observer: nil, opener: opener)
        await controller.returnToHost(keyboardHost: "com.apple.MobileSMS", launchedAt: launchedAt)
        XCTAssertEqual(opener.opened.count, 1)
        XCTAssertEqual(controller.status, .manual(hostName: "Messages"))
    }

    func testRetriesAreBounded() async {
        let opener = MockOpener(results: [false, false, false, false], active: false)
        let controller = makeController(observer: nil, opener: opener)
        await controller.returnToHost(keyboardHost: "com.apple.MobileSMS", launchedAt: launchedAt)
        XCTAssertEqual(opener.opened.count, 1 + HostReturnController.openRetries)
        XCTAssertEqual(controller.status, .manual(hostName: "Messages"))
    }

    func testDisabledDoesNothing() async {
        let opener = MockOpener(results: [true])
        let controller = makeController(observer: MockObserver(host: "com.apple.MobileSMS"), opener: opener, enabled: false)
        await controller.returnToHost(keyboardHost: "com.apple.MobileSMS", launchedAt: launchedAt)
        XCTAssertEqual(controller.status, .idle)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testCatalogLookupIgnoresCaseAndWhitespace() {
        XCTAssertEqual(HostAppCatalog.lookup(" com.apple.mobilesms ")?.name, "Messages")
        XCTAssertNil(HostAppCatalog.lookup(""))
        XCTAssertNil(HostAppCatalog.lookup(nil))
    }

    private func makeController(
        observer: MockObserver?,
        opener: MockOpener,
        enabled: Bool = true,
        appBundleID: String = "com.macparakeet.ios"
    ) -> HostReturnController {
        HostReturnController(
            observer: observer,
            opener: opener,
            isEnabled: { enabled },
            appBundleID: appBundleID,
            sleep: { _ in }
        )
    }
}

@MainActor
private final class MockObserver: HostAppObserving {
    let host: String?
    private(set) var queries = 0
    private(set) var lastSince: Date?

    init(host: String?) {
        self.host = host
    }

    func host(seenSince since: Date, timeout: Duration) async -> String? {
        queries += 1
        lastSince = since
        return host
    }
}

@MainActor
private final class MockOpener: URLOpening {
    private var results: [Bool]
    let isAppActive: Bool
    private(set) var opened: [URL] = []

    init(results: [Bool], active: Bool = true) {
        self.results = results
        isAppActive = active
    }

    func open(_ url: URL) async -> Bool {
        opened.append(url)
        return results.isEmpty ? false : results.removeFirst()
    }
}
