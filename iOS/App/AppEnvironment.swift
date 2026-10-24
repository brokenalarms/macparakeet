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
    let hostObserver: RemoteKeyboardHostObserver
    let hostReturn: HostReturnController

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

        let hostObserver = RemoteKeyboardHostObserver()
        hostObserver.start()
        self.hostObserver = hostObserver
        hostReturn = HostReturnController(
            observer: hostObserver,
            opener: ApplicationURLOpener(),
            isEnabled: { AppSettings.autoReturn() }
        )
    }

    /// A keyboard launch: start the keyboard's request, then send the user back to the app
    /// they were typing in (REQ-IOS-007).
    func handleLaunch(_ url: URL) async {
        let launchedAt = Date()
        guard let launch = await session.handle(url: url),
              let requestID = launch.requestID,
              session.isRecording(requestID: requestID)
        else { return }
        await hostReturn.returnToHost(keyboardHost: launch.hostBundleID, launchedAt: launchedAt)
    }
}
