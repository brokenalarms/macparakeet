import Foundation

/// Keyboard ↔ host app IPC (`iOS/spec/kernel/contracts/keyboard_session_ipc.yaml`).
enum SessionIPC {
    static let schemaVersion = 1
    static let commandPosted = "com.macparakeet.ios.command"
    static let sessionChanged = "com.macparakeet.ios.session"
    static let launchURL = URL(string: "macparakeet://session/start")!
    static let livenessWindow: TimeInterval = 5
    static let commandStaleAfter: TimeInterval = 10
    static let heartbeatInterval: Duration = .seconds(2)
}

/// The keyboard's launch of the host app: `macparakeet://session/start?request=<uuid>&host=<bundle id>`.
/// `request` names the start command the keyboard wrote just before launching, so the app
/// can start recording without a second tap. `host` is the app the keyboard was typing in,
/// when iOS still exposes it to the keyboard (iOS 26.3 and earlier).
struct SessionLaunch: Equatable, Sendable {
    var requestID: UUID?
    var hostBundleID: String?

    init(requestID: UUID? = nil, hostBundleID: String? = nil) {
        self.requestID = requestID
        self.hostBundleID = hostBundleID
    }

    init?(url: URL) {
        let base = SessionIPC.launchURL
        guard url.scheme == base.scheme, url.host() == base.host(), url.path() == base.path() else {
            return nil
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        requestID = items.first { $0.name == "request" }?.value.flatMap(UUID.init(uuidString:))
        hostBundleID = items.first { $0.name == "host" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    var url: URL {
        var components = URLComponents(url: SessionIPC.launchURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let requestID { items.append(URLQueryItem(name: "request", value: requestID.uuidString)) }
        if let hostBundleID { items.append(URLQueryItem(name: "host", value: hostBundleID)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }
}

enum CommandAction: String, Codable, Sendable {
    case start
    case stop
    case cancel
}

struct SessionCommand: Codable, Equatable, Sendable {
    var schemaVersion = SessionIPC.schemaVersion
    var requestID: UUID
    var action: CommandAction
    var issuedAt: Date
}

enum SessionState: String, Codable, Sendable {
    case ready
    case recording
    case processing
    case ended
}

/// Mirrors `KeyAction` raw values; the keyboard does not link MacParakeetCore.
enum PostAction: String, Codable, Sendable {
    case returnKey = "return"
}

struct SessionResult: Codable, Equatable, Sendable {
    var requestID: UUID
    var text: String
    var postAction: PostAction?
    var completedAt: Date
}

enum SessionErrorCode: String, Codable, Sendable {
    case fullAccessRequired = "full_access_required"
    case appLaunchFailed = "app_launch_failed"
    case microphoneDenied = "microphone_denied"
    case modelNotReady = "model_not_ready"
    case audioSessionFailed = "audio_session_failed"
    case sttFailed = "stt_failed"
    case staleCommand = "stale_command"
}

struct SessionError: Codable, Equatable, Sendable {
    var requestID: UUID?
    var code: SessionErrorCode
}

struct SessionSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = SessionIPC.schemaVersion
    var sessionID: UUID
    var state: SessionState
    var heartbeatAt: Date
    var activeRequestID: UUID?
    var result: SessionResult?
    var error: SessionError?

    func isLive(at now: Date) -> Bool {
        state != .ended && now.timeIntervalSince(heartbeatAt) <= SessionIPC.livenessWindow
    }
}

enum CommandDecision: Equatable {
    case accept
    case ignore
    case reject(SessionErrorCode)

    /// Host-app gate for a command read from command.json (contract invariants).
    static func evaluate(_ command: SessionCommand, state: SessionState, activeRequestID: UUID?, now: Date) -> CommandDecision {
        guard now.timeIntervalSince(command.issuedAt) <= SessionIPC.commandStaleAfter else {
            return .reject(.staleCommand)
        }
        switch command.action {
        case .start:
            return state == .ready ? .accept : .ignore
        case .stop, .cancel:
            return command.requestID == activeRequestID ? .accept : .ignore
        }
    }
}

/// Single-writer JSON files in the App Group `ipc/` directory.
struct SessionFileStore: Sendable {
    let directory: URL

    var commandURL: URL { directory.appendingPathComponent("command.json") }
    var sessionURL: URL { directory.appendingPathComponent("session.json") }

    static var appGroup: SessionFileStore? {
        AppGroup.ipcDirectory.map(SessionFileStore.init(directory:))
    }

    func readCommand() -> SessionCommand? { read(SessionCommand.self, from: commandURL) }
    func readSession() -> SessionSnapshot? { read(SessionSnapshot.self, from: sessionURL) }

    func write(_ command: SessionCommand) throws { try write(command, to: commandURL) }
    func write(_ session: SessionSnapshot) throws { try write(session, to: sessionURL) }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
                return date
            }
            return try Date(string, strategy: .iso8601)
        }
        return decoder
    }()
}

/// Payload-free cross-process signals via the Darwin notify center.
final class DarwinNotifier: @unchecked Sendable {
    private let name: String
    private let handler: @Sendable () -> Void

    private init(name: String, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Observation lasts until the returned object is released.
    static func observe(_ name: String, handler: @escaping @Sendable () -> Void) -> DarwinNotifier {
        let observer = DarwinNotifier(name: name, handler: handler)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(observer).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinNotifier>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
        return observer
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }
}
