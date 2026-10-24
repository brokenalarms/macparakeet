import UIKit

/// Learns the app a keyboard launch came from, on iOS 26.4+ where the keyboard can no
/// longer see its host. UIKit in this app receives the remote keyboard's source bundle in
/// `_UIRemoteKeyboards.sharedRemoteKeyboards.currentState.sourceBundleIdentifier` shortly
/// after the keyboard opens us; it is transient, so it is observed from launch.
///
/// Private UIKit state, not API, and the only file that touches it. Every hop is checked at
/// runtime; if one is missing the observer stays inert and returns fall back to the hint.
@MainActor
final class RemoteKeyboardHostObserver: NSObject, HostAppObserving {
    private var remoteKeyboards: NSObject?
    private var lastHost: (bundleID: String, seenAt: Date)?
    private var waiters: [UUID: (since: Date, continuation: CheckedContinuation<String?, Never>)] = [:]

    /// Install before the first launch URL is handled (app init).
    func start() {
        guard remoteKeyboards == nil,
              let type = NSClassFromString("_UIRemoteKeyboards") as? NSObject.Type
        else { return }
        let sharedSelector = NSSelectorFromString("sharedRemoteKeyboards")
        guard type.responds(to: sharedSelector),
              let shared = type.perform(sharedSelector)?.takeUnretainedValue() as? NSObject,
              shared.responds(to: NSSelectorFromString("currentState"))
        else { return }
        remoteKeyboards = shared
        shared.addObserver(self, forKeyPath: "currentState", options: [.initial, .new], context: nil)
    }

    func host(seenSince since: Date, timeout: Duration) async -> String? {
        if let lastHost, lastHost.seenAt >= since {
            return lastHost.bundleID
        }
        guard remoteKeyboards != nil else { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = (since, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(id, with: nil)
            }
        }
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        // A cleared state arrives as NSNull, which doesn't respond and reads as nil.
        let state = change?[.newKey] as? NSObject
        let selector = NSSelectorFromString("sourceBundleIdentifier")
        let bundleID = state?.responds(to: selector) == true
            ? state?.perform(selector)?.takeUnretainedValue() as? String
            : nil
        Task { @MainActor [weak self] in self?.record(bundleID) }
    }

    private func record(_ bundleID: String?) {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty,
              !HostAppCatalog.isOwnApp(bundleID, appBundleID: Bundle.main.bundleIdentifier ?? "")
        else { return }
        let seenAt = Date()
        lastHost = (bundleID, seenAt)
        for (id, waiter) in waiters where seenAt >= waiter.since {
            resume(id, with: bundleID)
        }
    }

    private func resume(_ id: UUID, with bundleID: String?) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: bundleID)
    }
}

/// `UIApplication.open` for `HostReturnController`.
struct ApplicationURLOpener: URLOpening {
    var isAppActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}
