import XCTest

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "OnboardingViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testStartsAtModelStepWhenNothingDone() {
        let viewModel = OnboardingViewModel(models: MockModels(), mic: MockMic(), defaults: defaults)
        XCTAssertEqual(viewModel.currentStep, .model)
        XCTAssertFalse(viewModel.isFinished)
    }

    func testRefusesDownloadWhenSpaceBelowModelPlusMargin() async {
        let models = MockModels(availableBytes: OnboardingViewModel.modelBytes)
        let viewModel = OnboardingViewModel(models: models, mic: MockMic(), defaults: defaults)
        await viewModel.downloadModel()
        let required = OnboardingViewModel.modelBytes + OnboardingViewModel.spaceMarginBytes
        XCTAssertEqual(viewModel.modelStatus, .insufficientSpace(requiredBytes: required, availableBytes: OnboardingViewModel.modelBytes))
        XCTAssertEqual(models.prepareCount, 0)
    }

    func testDownloadReportsProgressAndExcludesFromBackup() async {
        let models = MockModels(statuses: [.downloading(message: "50%", progress: 0.5), .ready])
        let viewModel = OnboardingViewModel(models: models, mic: MockMic(), defaults: defaults)
        await viewModel.downloadModel()
        XCTAssertEqual(viewModel.modelStatus, .ready)
        XCTAssertEqual(models.yielded, [.downloading(message: "50%", progress: 0.5), .ready])
        XCTAssertGreaterThan(models.excludeCount, 0)
        XCTAssertEqual(viewModel.currentStep, .microphone)
    }

    func testFailedDownloadCanResume() async {
        let models = MockModels(statuses: [.failed(message: "offline")])
        let viewModel = OnboardingViewModel(models: models, mic: MockMic(), defaults: defaults)
        await viewModel.downloadModel()
        XCTAssertEqual(viewModel.modelStatus, .failed(message: "offline"))
        models.statuses = [.ready]
        await viewModel.downloadModel()
        XCTAssertEqual(viewModel.modelStatus, .ready)
        XCTAssertEqual(models.prepareCount, 2)
    }

    func testStepsPersistAcrossLaunches() async {
        let models = MockModels(downloaded: true)
        let mic = MockMic(permission: .granted)
        let first = OnboardingViewModel(models: models, mic: mic, defaults: defaults)
        XCTAssertEqual(first.currentStep, .keyboard)
        first.markKeyboardAdded()
        XCTAssertEqual(first.currentStep, .fullAccess)

        let relaunched = OnboardingViewModel(models: models, mic: mic, defaults: defaults)
        XCTAssertEqual(relaunched.currentStep, .fullAccess)
        relaunched.markFullAccessExplained()
        XCTAssertTrue(relaunched.isFinished)
    }

    func testMicrophoneRequestUpdatesState() async {
        let mic = MockMic()
        let viewModel = OnboardingViewModel(models: MockModels(downloaded: true), mic: mic, defaults: defaults)
        mic.permission = .granted
        await viewModel.requestMicrophone()
        XCTAssertEqual(viewModel.microphone, .granted)
        XCTAssertEqual(viewModel.currentStep, .keyboard)
    }
}

private final class MockModels: SpeechModelProviding, @unchecked Sendable {
    var isDownloaded: Bool
    var availableBytes: Int64
    var statuses: [ModelStatus]
    private(set) var yielded: [ModelStatus] = []
    private(set) var prepareCount = 0
    private(set) var excludeCount = 0

    init(downloaded: Bool = false, availableBytes: Int64 = 10_000_000_000, statuses: [ModelStatus] = [.ready]) {
        isDownloaded = downloaded
        self.availableBytes = availableBytes
        self.statuses = statuses
    }

    func excludeFromBackup() { excludeCount += 1 }

    func prepare() async -> AsyncStream<ModelStatus> {
        prepareCount += 1
        let statuses = statuses
        yielded = statuses
        return AsyncStream { continuation in
            statuses.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private final class MockMic: MicrophonePermissionProviding, @unchecked Sendable {
    var permission: MicrophonePermission

    init(permission: MicrophonePermission = .undetermined) {
        self.permission = permission
    }

    var current: MicrophonePermission { permission }
    func request() async -> Bool { permission == .granted }
}
