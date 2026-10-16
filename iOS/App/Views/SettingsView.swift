import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.saveDictationHistoryKey) private var saveDictationHistory = true
    @AppStorage(AppSettings.idleTimeoutMinutesKey) private var idleTimeoutMinutes = AppSettings.defaultIdleTimeoutMinutes

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("End mic session after", selection: $idleTimeoutMinutes) {
                        ForEach(AppSettings.idleTimeoutChoices, id: \.self) { minutes in
                            Text("\(minutes) min idle").tag(minutes)
                        }
                    }
                } header: {
                    Text("Keyboard session")
                } footer: {
                    Text("While the mic session is active, the keyboard dictates without opening MacParakeet. A Live Activity shows when it's on.")
                }

                Section {
                    Toggle("Save dictation history", isOn: $saveDictationHistory)
                } footer: {
                    Text("When off, dictations are private: the text is inserted but not kept in History.")
                }

                Section {
                    Text("Audio, text, and usage never leave this iPhone. The only network access is the one-time speech model download.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Privacy")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
