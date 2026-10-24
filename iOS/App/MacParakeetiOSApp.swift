import MacParakeetCore
import SwiftUI

@main
struct MacParakeetiOSApp: App {
    @State private var root = AppRoot()

    var body: some Scene {
        WindowGroup {
            Group {
                switch root.state {
                case .ready(let environment):
                    RootView(environment: environment)
                case .failed(let message):
                    ContentUnavailableView("MacParakeet couldn't start", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .onOpenURL { url in
                guard case .ready(let environment) = root.state else { return }
                Task { await environment.handleLaunch(url) }
            }
        }
    }
}

@MainActor
@Observable
final class AppRoot {
    enum State {
        case ready(AppEnvironment)
        case failed(String)
    }

    let state: State

    init() {
        do {
            let environment = try AppEnvironment()
            environment.session.startObserving()
            if environment.sttClient.isActiveModelAvailable {
                Task { try? await environment.sttClient.warmUp(onProgress: nil) }
            }
            state = .ready(environment)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
