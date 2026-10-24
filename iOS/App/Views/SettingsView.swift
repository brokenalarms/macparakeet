import MacParakeetCore
import SwiftUI

struct SettingsView: View {
    let speechModels: SpeechModelSettingsViewModel
    @AppStorage(AppSettings.saveDictationHistoryKey) private var saveDictationHistory = true
    @AppStorage(AppSettings.idleTimeoutMinutesKey) private var idleTimeoutMinutes = AppSettings.defaultIdleTimeoutMinutes
    @AppStorage(AppSettings.autoReturnKey) private var autoReturn = true

    var body: some View {
        NavigationStack {
            Form {
                SpeechModelSection(viewModel: speechModels)

                Section {
                    Toggle("Return to your app automatically", isOn: $autoReturn)
                    Picker("End mic session after", selection: $idleTimeoutMinutes) {
                        ForEach(AppSettings.idleTimeoutChoices, id: \.self) { minutes in
                            Text("\(minutes) min idle").tag(minutes)
                        }
                    }
                } header: {
                    Text("Keyboard session")
                } footer: {
                    Text("Tapping the keyboard mic opens MacParakeet, starts listening, and goes back to the app you were typing in. While the mic session is active, the keyboard dictates without opening MacParakeet. A Live Activity shows when it's on.")
                }

                Section {
                    Toggle("Save dictation history", isOn: $saveDictationHistory)
                } footer: {
                    Text("When off, dictations are private: the text is inserted but not kept in History.")
                }

                Section {
                    Text("Audio, text, and usage never leave this iPhone. The only network access is the optional multilingual model download.")
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

private struct SpeechModelSection: View {
    let viewModel: SpeechModelSettingsViewModel

    var body: some View {
        Section {
            ModelRow(
                title: "English",
                detail: "Built in",
                isSelected: viewModel.selected == .english
            ) { viewModel.select(.english) }

            switch viewModel.multilingual {
            case .downloaded:
                ModelRow(
                    title: "Multilingual",
                    detail: "25 European languages",
                    isSelected: viewModel.selected == .multilingual
                ) { viewModel.select(.multilingual) }
                Button("Delete multilingual model", role: .destructive) {
                    Task { await viewModel.delete() }
                }
            case .notDownloaded:
                downloadButton
            case .downloading(let progress):
                if let fraction = progress.fraction {
                    ProgressView(value: fraction) { Text(progress.message).font(.footnote) }
                } else {
                    ProgressView { Text(progress.message).font(.footnote) }
                }
            case .insufficientSpace(let required, let available):
                Text("Not enough free space: needs \(Self.bytes(required)), \(Self.bytes(available)) available.")
                    .foregroundStyle(.red)
                downloadButton
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                downloadButton
            }
        } header: {
            Text("Speech model")
        } footer: {
            Text("English works out of the box. The multilingual model adds 24 more European languages and is downloaded once, about 480 MB; Wi-Fi recommended.")
        }
    }

    private var downloadButton: some View {
        Button("Download multilingual model") {
            Task { await viewModel.download() }
        }
    }

    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

private struct ModelRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
