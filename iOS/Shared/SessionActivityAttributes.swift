import ActivityKit
import Foundation

/// Live Activity shown for the whole time the host app holds the mic session (REQ-IOS-002).
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        var idleDeadline: Date
    }

    enum Phase: String, Codable, Hashable {
        case ready
        case recording
        case processing
    }
}
