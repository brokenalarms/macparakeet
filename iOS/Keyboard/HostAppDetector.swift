import ObjectiveC
import UIKit

/// Reads the bundle ID of the app the keyboard is typing in, through private
/// `_hostBundleID` state on the keyboard's parent view controller. Works through iOS 26.3;
/// on 26.4+ it reads nil and the host app observes the host instead
/// (`RemoteKeyboardHostObserver`). Only this file relies on it.
enum HostAppDetector {
    private static let key = "_hostBundleID"

    @MainActor
    static func hostBundleID(of controller: UIInputViewController) -> String? {
        guard let parent = controller.parent else { return nil }
        // value(forKey:) raises an Objective-C exception (a crash) for an unknown key, so
        // only ask when there is an accessor or ivar for it.
        let hasAccessor = parent.responds(to: NSSelectorFromString(key))
        let hasIvar = class_getInstanceVariable(type(of: parent), key) != nil
        guard hasAccessor || hasIvar,
              let bundleID = parent.value(forKey: key) as? String,
              !bundleID.isEmpty, bundleID != "<null>"
        else { return nil }
        return bundleID
    }
}
