import Foundation
import Observation
import OSLog

/// An app the keyboard launch can return to: the URL that opens it and its display name.
struct HostApp: Equatable, Sendable {
    let returnURL: URL
    let name: String
}

/// iOS has no API to return to the previous app, so returning means opening the host by
/// its URL scheme. Only apps listed here can be returned to; others get the manual hint.
enum HostAppCatalog {
    private static let entries: [String: (scheme: String, name: String)] = [
        "com.apple.MobileSMS": ("sms://", "Messages"),
        "com.apple.mobilemail": ("message://", "Mail"),
        "com.apple.mobilenotes": ("mobilenotes://", "Notes"),
        "com.apple.reminders": ("x-apple-reminderkit://", "Reminders"),
        "com.whatsapp.WhatsApp": ("whatsapp://send", "WhatsApp"),
        "net.whatsapp.WhatsApp": ("whatsapp://send", "WhatsApp"),
        "net.whatsapp.WhatsAppSMB": ("whatsapp-business://", "WhatsApp Business"),
        "ph.telegra.Telegraph": ("tg://", "Telegram"),
        "org.whispersystems.signal": ("sgnl://", "Signal"),
        "com.facebook.Messenger": ("fb-messenger://", "Messenger"),
        "com.facebook.Facebook": ("fb://", "Facebook"),
        "com.burbn.instagram": ("instagram://", "Instagram"),
        "com.atebits.Tweetie2": ("twitter://", "X"),
        "com.tinyspeck.chatlyio": ("slack://", "Slack"),
        "com.hammerandchisel.discord": ("discord://", "Discord"),
        "com.microsoft.skype.teams": ("msteams://", "Teams"),
        "com.microsoft.Office.Outlook": ("ms-outlook://", "Outlook"),
        "com.google.Gmail": ("googlegmail://", "Gmail"),
        "com.google.Docs": ("googledocs://", "Google Docs"),
        "com.google.chrome.ios": ("googlechrome://", "Chrome"),
        "notion.id": ("notion://", "Notion"),
        "com.linkedin.LinkedIn": ("linkedin://", "LinkedIn"),
        "com.reddit.Reddit": ("reddit://", "Reddit"),
        "jp.naver.line": ("line://", "LINE"),
        "com.viber": ("viber://", "Viber"),
        "com.openai.chat": ("chatgpt://", "ChatGPT"),
        "com.anthropic.claude": ("claude://", "Claude"),
    ]

    private static let lowercased: [String: (scheme: String, name: String)] = {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key.lowercased(), $0.value) })
    }()

    static func lookup(_ bundleID: String?) -> HostApp? {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty,
              let entry = entries[bundleID] ?? lowercased[bundleID.lowercased()],
              let url = URL(string: entry.scheme)
        else { return nil }
        return HostApp(returnURL: url, name: entry.name)
    }

    /// MacParakeet and its extensions host the keyboard in place; never a return target.
    static func isOwnApp(_ bundleID: String, appBundleID: String) -> Bool {
        let host = bundleID.lowercased()
        let app = appBundleID.lowercased()
        return !app.isEmpty && (host == app || host.hasPrefix(app + "."))
    }
}

/// Learns which app the keyboard was in, from the host app's side (iOS 26.4+).
@MainActor
protocol HostAppObserving: AnyObject {
    /// The host seen at or after `since`, waiting up to `timeout` for one to arrive.
    func host(seenSince since: Date, timeout: Duration) async -> String?
}

@MainActor
protocol URLOpening {
    var isAppActive: Bool { get }
    func open(_ url: URL) async -> Bool
}

/// Sends the user back to the app they were typing in after a keyboard launch
/// (REQ-IOS-007). Best effort: there is no public API for this, so every failure ends in
/// `.manual`, where the app shows the swipe-back hint.
@MainActor
@Observable
final class HostReturnController {
    enum Status: Equatable {
        case idle
        case returning
        case returned(hostName: String)
        /// Couldn't return; `hostName` is set when the host is known but wouldn't open.
        case manual(hostName: String?)
    }

    /// How long to wait for the observer: on a cold launch UIKit reports the host about
    /// 650 ms after the app opens.
    static let observerTimeout: Duration = .seconds(2)
    /// An observed host older than this before the launch belongs to an earlier switch.
    static let observerLookBack: TimeInterval = 5
    static let openRetries = 2
    static let retryDelay: Duration = .milliseconds(400)

    private(set) var status: Status = .idle

    @ObservationIgnored private let logger = Logger(subsystem: "com.macparakeet.ios", category: "HostReturn")
    @ObservationIgnored private let observer: HostAppObserving?
    @ObservationIgnored private let opener: URLOpening
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let appBundleID: String
    @ObservationIgnored private let sleep: (Duration) async -> Void

    init(
        observer: HostAppObserving?,
        opener: URLOpening,
        isEnabled: @escaping () -> Bool,
        appBundleID: String = Bundle.main.bundleIdentifier ?? "",
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.observer = observer
        self.opener = opener
        self.isEnabled = isEnabled
        self.appBundleID = appBundleID
        self.sleep = sleep
    }

    /// - Parameters:
    ///   - keyboardHost: The host the keyboard reported in the launch URL, if any. It wins:
    ///     when the keyboard named a host, the observer would only name the same one.
    ///   - launchedAt: When the launch URL arrived.
    func returnToHost(keyboardHost: String?, launchedAt: Date) async {
        guard isEnabled() else {
            status = .idle
            return
        }
        status = .returning
        var bundleID = usable(keyboardHost)
        if bundleID == nil, let observer {
            bundleID = usable(await observer.host(
                seenSince: launchedAt.addingTimeInterval(-Self.observerLookBack),
                timeout: Self.observerTimeout
            ))
        }
        guard let host = HostAppCatalog.lookup(bundleID) else {
            logger.info("no return target host=\(bundleID ?? "nil", privacy: .public)")
            status = .manual(hostName: nil)
            return
        }
        var retriesLeft = Self.openRetries
        while true {
            // A failed open while already active is final (e.g. the user cancelled the
            // "open in …?" prompt); while still launching it is worth retrying.
            let wasActive = opener.isAppActive
            if await opener.open(host.returnURL) {
                status = .returned(hostName: host.name)
                return
            }
            guard !wasActive, retriesLeft > 0 else { break }
            retriesLeft -= 1
            await sleep(Self.retryDelay)
        }
        logger.info("open failed host=\(host.name, privacy: .public)")
        status = .manual(hostName: host.name)
    }

    /// Clears the hint once the user is back or the dictation has finished.
    func reset() {
        status = .idle
    }

    private func usable(_ bundleID: String?) -> String? {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty,
              !HostAppCatalog.isOwnApp(bundleID, appBundleID: appBundleID)
        else { return nil }
        return bundleID
    }
}
