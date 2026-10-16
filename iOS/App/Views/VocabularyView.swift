import MacParakeetCore
import SwiftUI

struct VocabularyView: View {
    let environment: AppEnvironment
    @AppStorage(AppSettings.processingModeKey) private var processingMode = Dictation.ProcessingMode.raw.rawValue
    @AppStorage(AppSettings.voiceReturnEnabledKey) private var voiceReturnEnabled = false
    @AppStorage(AppSettings.voiceReturnTriggerKey) private var voiceReturnTrigger = AppSettings.defaultVoiceReturnTrigger

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Processing mode", selection: $processingMode) {
                        Text("Raw").tag(Dictation.ProcessingMode.raw.rawValue)
                        Text("Clean").tag(Dictation.ProcessingMode.clean.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("Processing mode")
                } footer: {
                    Text(processingMode == Dictation.ProcessingMode.clean.rawValue
                         ? "Clean removes filler words and applies your custom words and snippets."
                         : "Raw inserts exactly what Parakeet heard.")
                }

                Section {
                    NavigationLink("Custom words") {
                        CustomWordsView(repo: environment.customWordRepo)
                    }
                    NavigationLink("Text snippets") {
                        TextSnippetsView(repo: environment.snippetRepo)
                    }
                } footer: {
                    Text("Custom words and snippets apply in Clean mode.")
                }

                Section {
                    Toggle("Voice Return", isOn: $voiceReturnEnabled)
                    if voiceReturnEnabled {
                        TextField("Trigger phrase", text: $voiceReturnTrigger)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("End a dictation with “\(voiceReturnTrigger)” to press Return after the text is inserted.")
                }
            }
            .navigationTitle("Vocabulary")
        }
    }
}
