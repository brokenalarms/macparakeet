import Foundation

/// The keyboard request a launch started, kept across keyboard instances: iOS often tears
/// the keyboard down while the host app is in front, and the instance the user returns to
/// must still recognize (and insert) that request's result. Used by the keyboard only;
/// in `Shared/` so the test target covers it.
struct PendingLaunchStore {
    private static let idKey = "pendingLaunchRequestID"
    private static let dateKey = "pendingLaunchRequestDate"
    /// Long enough to cover a long dictation started from the launch.
    static let lifetime: TimeInterval = 30 * 60

    var defaults: UserDefaults = .standard

    func load(now: Date = Date()) -> UUID? {
        guard let raw = defaults.string(forKey: Self.idKey), let id = UUID(uuidString: raw),
              let date = defaults.object(forKey: Self.dateKey) as? Date,
              now.timeIntervalSince(date) <= Self.lifetime
        else { return nil }
        return id
    }

    func save(_ id: UUID, now: Date = Date()) {
        defaults.set(id.uuidString, forKey: Self.idKey)
        defaults.set(now, forKey: Self.dateKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.idKey)
        defaults.removeObject(forKey: Self.dateKey)
    }
}
