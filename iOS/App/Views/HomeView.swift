import SwiftUI
import UIKit

struct HomeView: View {
    let session: DictationSessionController
    let onboarding: OnboardingViewModel
    @Binding var showsOnboarding: Bool

    var body: some View {
        NavigationStack {
            List {
                if !onboarding.isFinished {
                    Section {
                        Button("Finish setup") { showsOnboarding = true }
                    } footer: {
                        Text("Download the speech model, allow the microphone, and add the keyboard.")
                    }
                }

                Section {
                    VStack(spacing: 16) {
                        RecordButton(phase: session.phase) {
                            Task { await toggleRecording() }
                        }
                        .disabled(!onboarding.isComplete(.model) || session.phase == .processing || session.phase == .activating)
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                if let result = session.lastResult, !result.text.isEmpty {
                    Section("Last dictation") {
                        Text(result.text)
                            .textSelection(.enabled)
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = result.text
                        }
                    }
                }

                if session.phase.holdsAudioSession {
                    Section {
                        Button("End mic session", role: .destructive) {
                            Task { await session.endSession() }
                        }
                        .disabled(session.phase != .ready)
                    } footer: {
                        Text("The keyboard can dictate without reopening MacParakeet while the session is active.")
                    }
                }
            }
            .navigationTitle("MacParakeet")
            .onAppear { onboarding.refresh() }
        }
    }

    private var statusText: String {
        if let error = session.lastError {
            return ErrorText.message(for: error.code)
        }
        switch session.phase {
        case .inactive, .ended: return "Tap to dictate"
        case .activating: return "Starting microphone…"
        case .ready: return "Mic session active — tap to dictate"
        case .recording: return "Listening… tap to stop"
        case .processing: return "Transcribing…"
        }
    }

    private func toggleRecording() async {
        if session.phase == .recording {
            await session.stopInApp()
        } else {
            await session.startInApp()
        }
    }
}

private struct RecordButton: View {
    let phase: DictationSessionPhase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: phase == .recording ? "stop.fill" : "mic.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(phase == .recording ? Color.red : Color.accentColor, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(phase == .recording ? "Stop dictation" : "Start dictation")
    }
}

enum ErrorText {
    static func message(for code: SessionErrorCode) -> String {
        switch code {
        case .microphoneDenied: return "Microphone access is off. Enable it in Settings."
        case .modelNotReady: return "The speech model isn't downloaded yet."
        case .audioSessionFailed: return "Couldn't start the microphone."
        case .sttFailed: return "Transcription failed. Try again."
        case .staleCommand: return "That request expired. Try again."
        case .fullAccessRequired: return "Allow Full Access for the keyboard."
        case .appLaunchFailed: return "Couldn't open MacParakeet."
        }
    }
}
