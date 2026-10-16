import SwiftUI
import UIKit

struct OnboardingView: View {
    let viewModel: OnboardingViewModel
    @Binding var isPresented: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Dictate into any app with Parakeet running on your iPhone. Audio never leaves the device.")
                        .foregroundStyle(.secondary)
                }
                StepSection(title: "1. Download the speech model", done: viewModel.isComplete(.model)) {
                    modelStep
                }
                StepSection(title: "2. Allow the microphone", done: viewModel.isComplete(.microphone)) {
                    microphoneStep
                }
                StepSection(title: "3. Add the keyboard", done: viewModel.isComplete(.keyboard)) {
                    Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → MacParakeet.")
                    Button("Open Settings") { openSettings() }
                    Button("I've added it") { viewModel.markKeyboardAdded() }
                }
                StepSection(title: "4. Allow Full Access", done: viewModel.isComplete(.fullAccess)) {
                    Text("""
                    The MacParakeet keyboard needs Full Access only to talk to this app through a shared \
                    folder on your iPhone. iOS will warn that a keyboard with Full Access can transmit what \
                    you type. MacParakeet's keyboard has no network code, never sees your audio, and only \
                    inserts the text this app transcribed.
                    """)
                    .font(.callout)
                    Button("Got it — open Settings") {
                        viewModel.markFullAccessExplained()
                        openSettings()
                    }
                    Text("Tap MacParakeet in Keyboards, then turn on Allow Full Access.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set up MacParakeet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isFinished ? "Done" : "Later") { isPresented = false }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { viewModel.refresh() }
            }
        }
    }

    @ViewBuilder
    private var modelStep: some View {
        switch viewModel.modelStatus {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notDownloaded:
            Text("About 650 MB. Wi-Fi recommended.")
            Button("Download") { Task { await viewModel.downloadModel() } }
        case .downloading(let message, let progress):
            if let progress {
                ProgressView(value: progress) { Text(message).font(.footnote) }
            } else {
                ProgressView { Text(message).font(.footnote) }
            }
        case .insufficientSpace(let required, let available):
            Text("Not enough free space: needs \(Self.bytes(required)), \(Self.bytes(available)) available.")
                .foregroundStyle(.red)
            Button("Try again") { Task { await viewModel.downloadModel() } }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Resume download") { Task { await viewModel.downloadModel() } }
        }
    }

    @ViewBuilder
    private var microphoneStep: some View {
        switch viewModel.microphone {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .undetermined:
            Button("Allow microphone") { Task { await viewModel.requestMicrophone() } }
        case .denied:
            Text("Microphone access is off.")
            Button("Open Settings") { openSettings() }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

private struct StepSection<Content: View>: View {
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            content
        } header: {
            HStack {
                Text(title)
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
    }
}
