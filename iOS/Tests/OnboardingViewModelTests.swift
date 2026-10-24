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

    func testBundledModelCompletesModelStep() {
        let viewModel = OnboardingViewModel(models: MockModels(), mic: MockMic(), defaults: defaults)
        XCTAssertTrue(viewModel.isComplete(.model))
        XCTAssertEqual(viewModel.currentStep, .microphone)
        XCTAssertFalse(viewModel.isFinished)
    }

    func testMissingBundledModelBlocksAtModelStep() {
        let viewModel = OnboardingViewModel(models: MockModels(bundled: false), mic: MockMic(), defaults: defaults)
        XCTAssertEqual(viewModel.currentStep, .model)
    }

    func testStepsPersistAcrossLaunches() async {
        let models = MockModels()
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
        let viewModel = OnboardingViewModel(models: MockModels(), mic: mic, defaults: defaults)
        mic.permission = .granted
        await viewModel.requestMicrophone()
        XCTAssertEqual(viewModel.microphone, .granted)
        XCTAssertEqual(viewModel.currentStep, .keyboard)
    }
}

private struct MockModels: SpeechModelProviding {
    var bundled = true
    var isBundledModelAvailable: Bool { bundled }
}

private final class MockMic: MicrophonePermissionProviding, @unchecked Sendable {
    var permission: MicrophonePermission

    init(permission: MicrophonePermission = .undetermined) {
        self.permission = permission
    }

    var current: MicrophonePermission { permission }
    func request() async -> Bool { permission == .granted }
}
