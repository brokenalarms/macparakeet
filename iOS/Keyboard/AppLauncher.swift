import UIKit

protocol AppLaunching {
    /// Returns false when no launch path was found; the keyboard then shows fallback instructions.
    @MainActor func open(_ url: URL, from responder: UIResponder) -> Bool
}

/// Keyboards have no public API to open their containing app. Walk the responder chain to
/// the `UIApplication` and call `open(_:options:completionHandler:)` through the runtime,
/// since the method is marked unavailable to extensions at compile time. This is the only
/// file that relies on it; swap the conformer if iOS ever closes the path.
struct ResponderChainAppLauncher: AppLaunching {
    private typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void

    @MainActor
    func open(_ url: URL, from responder: UIResponder) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var current: UIResponder? = responder
        while let candidate = current {
            if candidate.isKind(of: UIApplication.self), candidate.responds(to: selector) {
                let implementation = unsafeBitCast(candidate.method(for: selector), to: OpenURL.self)
                implementation(candidate, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            current = candidate.next
        }
        return false
    }
}
