import MacParakeetCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.saveDictationHistoryKey) private var saveDictationHistory = true
    @AppStorage(AppSettings.idleTimeoutMinutesKey) private var idleTimeoutMinutes = AppSettings.defaultIdleTimeoutMinutes
    @AppStorage(AppPreferences.telemetryEnabledKey) private var telemetryEnabled = true

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
                    Toggle("Anonymous usage stats", isOn: $telemetryEnabled)
                        .onChange(of: telemetryEnabled) { _, enabled in
                            if !enabled { Telemetry.send(.telemetryOptedOut) }
                        }
                } footer: {
                    Text("No audio or text is ever sent. Dictation works fully offline once the model is downloaded.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
