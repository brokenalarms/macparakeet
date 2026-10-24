import Foundation
import MacParakeetCore

/// Composition root for the host app. Only the host app opens the database; it lives in
/// the app's private container (not the App Group) so no shared-container file lock can be
/// held across suspension, which would get the app killed with `0xdead10cc`.
@MainActor
final class AppEnvironment {
    let database: DatabaseManager
    let dictationRepo: DictationRepository
    let customWordRepo: CustomWordRepository
    let snippetRepo: TextSnippetRepository
    let sttClient: MobileSTTClient
    let audioProcessor: MobileAudioProcessor
    let dictationService: DictationService
    let session: DictationSessionController

    init() throws {
        try AppPaths.ensureDirectories()
        database = try DatabaseManager(path: AppPaths.databasePath)
        dictationRepo = DictationRepository(dbQueue: database.dbQueue)
        customWordRepo = CustomWordRepository(dbQueue: database.dbQueue)
        snippetRepo = TextSnippetRepository(dbQueue: database.dbQueue)
        let sttClient = MobileSTTClient(
            bundledModelDirectory: Bundle.main.url(forResource: MobileSTTClient.bundledModelFolder, withExtension: nil),
            selectedModel: { AppSettings.speechModel() }
        )
        self.sttClient = sttClient
        audioProcessor = MobileAudioProcessor()

        dictationService = DictationService(
            audioProcessor: audioProcessor,
            sttClient: sttClient,
            dictationRepo: dictationRepo,
            shouldSaveAudio: { false },
            shouldSaveDictationHistory: { AppSettings.saveDictationHistory() },
            customWordRepo: customWordRepo,
            snippetRepo: snippetRepo,
            voiceReturnTrigger: { AppSettings.voiceReturnTrigger() },
            processingMode: { AppSettings.processingMode() }
        )

        session = DictationSessionController(
            audio: audioProcessor,
            dictation: dictationService,
            store: SessionFileStore.appGroup,
            activity: SessionActivityPresenter(),
            isModelReady: { sttClient.isActiveModelAvailable },
            idleTimeout: { .seconds(AppSettings.idleTimeoutMinutes() * 60) }
        )
    }
}
