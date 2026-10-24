import FluidAudio
import Foundation

/// Speech models the iOS app can run. English ships inside the app bundle; multilingual is
/// an optional download from Settings.
public enum SpeechModel: String, CaseIterable, Sendable {
    /// Parakeet TDT-CTC 110M, English only, bundled.
    case english
    /// Parakeet TDT 0.6B v3, 25 European languages, downloaded on request.
    case multilingual

    var version: AsrModelVersion {
        switch self {
        case .english: return .tdtCtc110m
        case .multilingual: return .v3
        }
    }
}

/// Progress of the optional multilingual model download.
public struct SpeechModelDownloadProgress: Sendable, Equatable {
    public var message: String
    public var fraction: Double?

    public init(message: String, fraction: Double?) {
        self.message = message
        self.fraction = fraction
    }
}

/// iOS replacement for the Mac `STTClient` (excluded in `project.yml`): the iOS build pins a
/// newer FluidAudio than the Mac app, whose API the shared client doesn't compile against,
/// and iOS loads a bundled model instead of downloading one.
public actor MobileSTTClient: STTClientProtocol {
    /// Folder copied into the app bundle by `scripts/fetch-bundled-model.sh`.
    public static let bundledModelFolder = "parakeet-tdt-ctc-110m-coreml"

    private let bundledModelDirectory: URL?
    private let selectedModel: @Sendable () -> SpeechModel
    private var manager: AsrManager?
    private var loadedModel: SpeechModel?
    private var loading: (model: SpeechModel, task: Task<AsrManager, Error>)?

    /// - Parameters:
    ///   - bundledModelDirectory: The bundled `parakeet-tdt-ctc-110m-coreml` folder.
    ///   - selectedModel: The user's choice; falls back to English when multilingual isn't downloaded.
    public init(bundledModelDirectory: URL?, selectedModel: @escaping @Sendable () -> SpeechModel) {
        self.bundledModelDirectory = bundledModelDirectory
        self.selectedModel = selectedModel
    }

    // MARK: - Availability

    public nonisolated static var multilingualDirectory: URL {
        AsrModels.defaultCacheDirectory(for: SpeechModel.multilingual.version)
    }

    public nonisolated func isAvailable(_ model: SpeechModel) -> Bool {
        switch model {
        case .english:
            guard let bundledModelDirectory else { return false }
            return AsrModels.modelsExist(at: bundledModelDirectory, version: model.version)
        case .multilingual:
            return AsrModels.modelsExist(at: Self.multilingualDirectory, version: model.version)
        }
    }

    /// The model dictation will use right now.
    public nonisolated var activeModel: SpeechModel {
        let selected = selectedModel()
        return selected == .multilingual && !isAvailable(.multilingual) ? .english : selected
    }

    public nonisolated var isActiveModelAvailable: Bool {
        isAvailable(activeModel)
    }

    // MARK: - Multilingual download

    public func downloadMultilingual(onProgress: @escaping @Sendable (SpeechModelDownloadProgress) -> Void) async throws {
        let directory = Self.multilingualDirectory
        Self.excludeFromBackup(directory.deletingLastPathComponent())
        do {
            _ = try await AsrModels.download(version: SpeechModel.multilingual.version) { progress in
                onProgress(Self.downloadProgress(from: progress))
            }
        } catch {
            throw try Self.mapError(error, fallback: STTError.engineStartFailed)
        }
        Self.excludeFromBackup(directory.deletingLastPathComponent())
    }

    public func deleteMultilingual() async throws {
        if loadedModel == .multilingual {
            await unload()
        }
        let directory = Self.multilingualDirectory
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - STTClientProtocol

    public func transcribe(audioPath: String, onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> STTResult {
        let model = activeModel
        let manager = try await loadedManager(for: model)
        onProgress?(0, 100)
        do {
            try Task.checkCancellation()
            var decoderState = try TdtDecoderState(decoderLayers: model.version.decoderLayers)
            let result = try await manager.transcribe(URL(fileURLWithPath: audioPath), decoderState: &decoderState)
            onProgress?(100, 100)
            return STTResult(text: result.text, words: Self.mergeTokenTimingsIntoWords(result.tokenTimings))
        } catch {
            throw try Self.mapError(error, fallback: STTError.transcriptionFailed)
        }
    }

    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        onProgress?("Loading model into memory...")
        _ = try await loadedManager(for: activeModel)
        onProgress?("Ready")
    }

    public func isReady() async -> Bool {
        guard let manager, loadedModel == activeModel else { return false }
        return await manager.isAvailable
    }

    public func clearModelCache() async {
        try? await deleteMultilingual()
        await unload()
    }

    public func shutdown() async {
        await unload()
    }

    // MARK: - Loading

    private func loadedManager(for model: SpeechModel) async throws -> AsrManager {
        if let manager, loadedModel == model {
            return manager
        }
        if let loading, loading.model == model {
            return try await loading.task.value
        }
        guard isAvailable(model), let directory = directory(for: model) else {
            throw model == .english
                ? STTError.engineStartFailed("The built-in speech model is missing from this build.")
                : STTError.modelDownloadFailed
        }
        let version = model.version
        let task = Task.detached(priority: .userInitiated) {
            let models = try AsrModels.loadLocal(from: directory, version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = (model, task)
        do {
            let newManager = try await task.value
            if loading?.model == model { loading = nil }
            if let manager { await manager.cleanup() }
            manager = newManager
            loadedModel = model
            return newManager
        } catch {
            if loading?.model == model { loading = nil }
            throw try Self.mapError(error, fallback: STTError.engineStartFailed)
        }
    }

    private func unload() async {
        loading?.task.cancel()
        loading = nil
        if let manager { await manager.cleanup() }
        manager = nil
        loadedModel = nil
    }

    private func directory(for model: SpeechModel) -> URL? {
        switch model {
        case .english: return bundledModelDirectory
        case .multilingual: return Self.multilingualDirectory
        }
    }

    // MARK: - Helpers

    private static func excludeFromBackup(_ directory: URL) {
        var directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private static func downloadProgress(from progress: DownloadProgress) -> SpeechModelDownloadProgress {
        let fraction = max(0, min(1, progress.fractionCompleted))
        switch progress.phase {
        case .listing:
            return SpeechModelDownloadProgress(message: "Preparing download…", fraction: nil)
        case .downloading:
            return SpeechModelDownloadProgress(message: "Downloading… \(Int(fraction * 100))%", fraction: fraction)
        case .compiling:
            return SpeechModelDownloadProgress(message: "Optimizing for this iPhone…", fraction: nil)
        }
    }

    private static func mapError(_ error: Error, fallback: (String) -> STTError) throws -> STTError {
        if error is CancellationError {
            throw error
        }
        if let sttError = error as? STTError {
            return sttError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .modelDownloadFailed
            default:
                break
            }
        }
        if let asrError = error as? ASRError, case .notInitialized = asrError {
            return .modelNotLoaded
        }
        return fallback(error.localizedDescription)
    }

    private static func mergeTokenTimingsIntoWords(_ tokenTimings: [TokenTiming]?) -> [TimestampedWord] {
        guard let tokenTimings, !tokenTimings.isEmpty else { return [] }

        var words: [TimestampedWord] = []
        var currentWord = ""
        var currentStartTime: TimeInterval?
        var currentEndTime: TimeInterval = 0
        var currentConfidences: [Float] = []

        func flushCurrentWord() {
            guard !currentWord.isEmpty, let startTime = currentStartTime else { return }
            let averageConfidence = currentConfidences.isEmpty
                ? 0.0
                : (currentConfidences.reduce(0, +) / Float(currentConfidences.count))
            words.append(
                TimestampedWord(
                    word: currentWord,
                    startMs: Int((startTime * 1_000).rounded()),
                    endMs: Int((currentEndTime * 1_000).rounded()),
                    confidence: Double(averageConfidence)
                ))
            currentWord = ""
            currentStartTime = nil
            currentEndTime = 0
            currentConfidences.removeAll(keepingCapacity: true)
        }

        for timing in tokenTimings {
            let normalizedToken = timing.token.replacingOccurrences(of: "▁", with: " ")
            let trimmedToken = normalizedToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else { continue }

            if normalizedToken.hasPrefix(" ") || normalizedToken.hasPrefix("\n") || normalizedToken.hasPrefix("\t") {
                flushCurrentWord()
                currentWord = trimmedToken
                currentStartTime = timing.startTime
                currentEndTime = timing.endTime
                currentConfidences = [timing.confidence]
            } else {
                if currentStartTime == nil {
                    currentStartTime = timing.startTime
                }
                currentWord += trimmedToken
                currentEndTime = timing.endTime
                currentConfidences.append(timing.confidence)
            }
        }

        flushCurrentWord()
        return words
    }
}
