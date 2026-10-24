import Foundation
import MacParakeetCore

protocol SpeechModelManaging: Sendable {
    func isAvailable(_ model: SpeechModel) -> Bool
    func downloadMultilingual(onProgress: @escaping @Sendable (SpeechModelDownloadProgress) -> Void) async throws
    func deleteMultilingual() async throws
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws
}

extension MobileSTTClient: SpeechModelManaging {}

/// Settings → Speech model (REQ-IOS-006). English is bundled; multilingual is an optional
/// download that becomes the selected model once it finishes.
@MainActor
@Observable
final class SpeechModelSettingsViewModel {
    enum MultilingualState: Equatable {
        case notDownloaded
        case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
        case downloading(SpeechModelDownloadProgress)
        case downloaded
        case failed(message: String)
    }

    /// Parakeet TDT 0.6B v3 (int8 encoder) as FluidAudio documents it, plus room to
    /// compile the CoreML models on device.
    static let multilingualBytes: Int64 = 480_000_000
    static let spaceMarginBytes: Int64 = 500_000_000

    private(set) var selected: SpeechModel
    private(set) var multilingual: MultilingualState

    @ObservationIgnored private let models: SpeechModelManaging
    @ObservationIgnored private let availableBytes: () -> Int64
    @ObservationIgnored private let defaults: UserDefaults

    init(models: SpeechModelManaging, availableBytes: @escaping () -> Int64 = DiskSpace.availableBytes, defaults: UserDefaults = .standard) {
        self.models = models
        self.availableBytes = availableBytes
        self.defaults = defaults
        let downloaded = models.isAvailable(.multilingual)
        multilingual = downloaded ? .downloaded : .notDownloaded
        let stored = AppSettings.speechModel(defaults)
        selected = stored == .multilingual && !downloaded ? .english : stored
    }

    var isDownloading: Bool {
        if case .downloading = multilingual { return true }
        return false
    }

    func select(_ model: SpeechModel) {
        guard model != selected, models.isAvailable(model) else { return }
        selected = model
        defaults.set(model.rawValue, forKey: AppSettings.speechModelKey)
        let models = models
        Task { try? await models.warmUp(onProgress: nil) }
    }

    func download() async {
        switch multilingual {
        case .downloading, .downloaded: return
        default: break
        }
        let required = Self.multilingualBytes + Self.spaceMarginBytes
        let available = availableBytes()
        guard available >= required else {
            multilingual = .insufficientSpace(requiredBytes: required, availableBytes: available)
            return
        }
        multilingual = .downloading(SpeechModelDownloadProgress(message: "Preparing download…", fraction: nil))
        do {
            try await models.downloadMultilingual { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.isDownloading else { return }
                    self.multilingual = .downloading(progress)
                }
            }
            multilingual = .downloaded
            select(.multilingual)
        } catch is CancellationError {
            multilingual = .notDownloaded
        } catch {
            multilingual = .failed(message: error.localizedDescription)
        }
    }

    func delete() async {
        guard multilingual == .downloaded else { return }
        if selected == .multilingual {
            select(.english)
        }
        do {
            try await models.deleteMultilingual()
            multilingual = .notDownloaded
        } catch {
            multilingual = .failed(message: error.localizedDescription)
        }
    }
}

enum DiskSpace {
    static func availableBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
