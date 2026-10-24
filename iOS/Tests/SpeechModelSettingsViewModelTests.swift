import MacParakeetCore
import XCTest

@MainActor
final class SpeechModelSettingsViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "SpeechModelSettingsViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsToBundledEnglish() {
        let viewModel = makeViewModel(MockModelStore())
        XCTAssertEqual(viewModel.selected, .english)
        XCTAssertEqual(viewModel.multilingual, .notDownloaded)
    }

    func testStoredMultilingualFallsBackToEnglishWhenNotDownloaded() {
        defaults.set(SpeechModel.multilingual.rawValue, forKey: AppSettings.speechModelKey)
        let viewModel = makeViewModel(MockModelStore())
        XCTAssertEqual(viewModel.selected, .english)
    }

    func testCannotSelectMultilingualBeforeDownload() {
        let viewModel = makeViewModel(MockModelStore())
        viewModel.select(.multilingual)
        XCTAssertEqual(viewModel.selected, .english)
        XCTAssertNil(defaults.string(forKey: AppSettings.speechModelKey))
    }

    func testRefusesDownloadWhenSpaceBelowModelPlusMargin() async {
        let store = MockModelStore()
        let viewModel = makeViewModel(store, availableBytes: SpeechModelSettingsViewModel.multilingualBytes)
        await viewModel.download()
        let required = SpeechModelSettingsViewModel.multilingualBytes + SpeechModelSettingsViewModel.spaceMarginBytes
        XCTAssertEqual(viewModel.multilingual, .insufficientSpace(requiredBytes: required, availableBytes: SpeechModelSettingsViewModel.multilingualBytes))
        XCTAssertEqual(store.downloadCount, 0)
    }

    func testDownloadSelectsMultilingual() async {
        let store = MockModelStore()
        let viewModel = makeViewModel(store)
        await viewModel.download()
        XCTAssertEqual(viewModel.multilingual, .downloaded)
        XCTAssertEqual(viewModel.selected, .multilingual)
        XCTAssertEqual(AppSettings.speechModel(defaults), .multilingual)
    }

    func testFailedDownloadCanBeRetried() async {
        let store = MockModelStore()
        store.failure = URLError(.notConnectedToInternet)
        let viewModel = makeViewModel(store)
        await viewModel.download()
        guard case .failed = viewModel.multilingual else {
            return XCTFail("expected failure, got \(viewModel.multilingual)")
        }
        store.failure = nil
        await viewModel.download()
        XCTAssertEqual(viewModel.multilingual, .downloaded)
        XCTAssertEqual(store.downloadCount, 2)
    }

    func testDeleteReturnsToEnglish() async {
        let store = MockModelStore()
        store.multilingualDownloaded = true
        defaults.set(SpeechModel.multilingual.rawValue, forKey: AppSettings.speechModelKey)
        let viewModel = makeViewModel(store)
        XCTAssertEqual(viewModel.selected, .multilingual)
        await viewModel.delete()
        XCTAssertEqual(viewModel.multilingual, .notDownloaded)
        XCTAssertEqual(viewModel.selected, .english)
        XCTAssertEqual(AppSettings.speechModel(defaults), .english)
    }

    private func makeViewModel(_ store: MockModelStore, availableBytes: Int64 = 10_000_000_000) -> SpeechModelSettingsViewModel {
        SpeechModelSettingsViewModel(models: store, availableBytes: { availableBytes }, defaults: defaults)
    }
}

private final class MockModelStore: SpeechModelManaging, @unchecked Sendable {
    var multilingualDownloaded = false
    var failure: Error?
    private(set) var downloadCount = 0

    func isAvailable(_ model: SpeechModel) -> Bool {
        model == .english || multilingualDownloaded
    }

    func downloadMultilingual(onProgress: @escaping @Sendable (SpeechModelDownloadProgress) -> Void) async throws {
        downloadCount += 1
        onProgress(SpeechModelDownloadProgress(message: "50%", fraction: 0.5))
        if let failure { throw failure }
        multilingualDownloaded = true
    }

    func deleteMultilingual() async throws {
        multilingualDownloaded = false
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}
}
