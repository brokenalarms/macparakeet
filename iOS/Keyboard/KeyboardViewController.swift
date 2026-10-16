import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private let launcher: AppLaunching = ResponderChainAppLauncher()
    private var hostingController: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.insertText = { [weak self] text in self?.textDocumentProxy.insertText(text) }
        model.launchApp = { [weak self] in
            guard let self else { return false }
            return self.launcher.open(SessionIPC.launchURL, from: self)
        }
        installKeyboardView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.hasFullAccess = hasFullAccess
        model.startObserving()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.stopObserving()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        installKeyboardView()
    }

    /// Rebuilt when `needsInputModeSwitchKey` changes, which UIKit only settles during layout.
    private func installKeyboardView() {
        let actions = KeyboardActions(
            nextKeyboard: needsInputModeSwitchKey ? { [weak self] in self?.advanceToNextInputMode() } : nil,
            space: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            delete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            returnKey: { [weak self] in self?.textDocumentProxy.insertText("\n") }
        )
        let view = KeyboardView(model: model, actions: actions)
        if let hostingController {
            hostingController.rootView = view
            return
        }
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }
}
