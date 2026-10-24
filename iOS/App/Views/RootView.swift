import SwiftUI

struct RootView: View {
    let environment: AppEnvironment
    @State private var onboarding: OnboardingViewModel
    @State private var speechModels: SpeechModelSettingsViewModel
    @State private var showsOnboarding: Bool

    init(environment: AppEnvironment) {
        self.environment = environment
        let onboarding = OnboardingViewModel(
            models: LiveSpeechModelProvider(sttClient: environment.sttClient),
            mic: LiveMicrophonePermission()
        )
        _onboarding = State(initialValue: onboarding)
        _speechModels = State(initialValue: SpeechModelSettingsViewModel(models: environment.sttClient))
        _showsOnboarding = State(initialValue: !onboarding.isFinished)
    }

    var body: some View {
        TabView {
            HomeView(session: environment.session, hostReturn: environment.hostReturn, onboarding: onboarding, showsOnboarding: $showsOnboarding)
                .tabItem { Label("Dictate", systemImage: "mic") }
            HistoryView(viewModel: HistoryViewModel(repo: environment.dictationRepo))
                .tabItem { Label("History", systemImage: "clock") }
            VocabularyView(environment: environment)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            SettingsView(speechModels: speechModels)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .fullScreenCover(isPresented: $showsOnboarding) {
            OnboardingView(viewModel: onboarding, isPresented: $showsOnboarding)
        }
    }
}
