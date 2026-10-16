import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MacParakeetWidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.phase.symbol)
                    .font(.title2)
                    .foregroundStyle(context.state.phase.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.phase.title).font(.headline)
                    if context.state.phase == .ready {
                        Text("Ends \(context.state.idleDeadline, style: .relative) from now if idle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase.symbol).foregroundStyle(context.state.phase.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.phase.title)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbol).foregroundStyle(context.state.phase.tint)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: context.state.phase.symbol).foregroundStyle(context.state.phase.tint)
            }
        }
    }
}

private extension SessionActivityAttributes.Phase {
    var title: String {
        switch self {
        case .ready: return "Mic session on"
        case .recording: return "Listening"
        case .processing: return "Transcribing"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "mic"
        case .recording: return "mic.fill"
        case .processing: return "waveform"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .orange
        case .recording: return .red
        case .processing: return .blue
        }
    }
}
