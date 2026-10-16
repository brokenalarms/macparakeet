import Foundation

/// iOS replacement for the `Telemetry` facade in the excluded `Services/TelemetryService.swift`.
/// Shared code keeps calling `Telemetry.send`; on iOS nothing is recorded or sent, and no
/// telemetry transport is compiled into the app.
public enum Telemetry {
    public static func send(_ event: TelemetryEventSpec) {}
    public static func flush() async {}
    public static func flushForTermination() {}
}
