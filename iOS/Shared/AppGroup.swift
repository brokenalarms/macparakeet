import Foundation

enum AppGroup {
    /// Injected from the `APP_GROUP_ID` build setting so device builds can use another team's group.
    static var identifier: String {
        Bundle.main.object(forInfoDictionaryKey: "MacParakeetAppGroup") as? String ?? "group.com.macparakeet"
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var ipcDirectory: URL? {
        containerURL?.appendingPathComponent("ipc", isDirectory: true)
    }
}
