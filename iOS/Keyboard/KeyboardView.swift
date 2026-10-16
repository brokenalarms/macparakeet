import SwiftUI

struct KeyboardActions {
    var nextKeyboard: (() -> Void)?
    var space: () -> Void
    var delete: () -> Void
    var returnKey: () -> Void
}

struct KeyboardView: View {
    let model: KeyboardModel
    let actions: KeyboardActions

    var body: some View {
        VStack(spacing: 10) {
            if model.viewState == .fullAccessRequired {
                fullAccessPrompt
            } else {
                Spacer(minLength: 0)
                micArea
                Spacer(minLength: 0)
                utilityRow
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(height: 216)
        .frame(maxWidth: .infinity)
    }

    private var fullAccessPrompt: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Text("Enable Full Access in Settings")
                .font(.headline)
            Text("Settings → General → Keyboard → Keyboards → MacParakeet → Allow Full Access")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                globeKey
                Spacer()
            }
        }
    }

    private var micArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                if model.viewState == .recording {
                    KeyButton(systemImage: "xmark", label: "Cancel dictation", action: model.cancelTapped)
                        .frame(width: 44)
                }
                Button(action: model.micTapped) {
                    ZStack {
                        Circle().fill(micColor)
                        if model.viewState == .processing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: micSymbol)
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 72, height: 72)
                }
                .buttonStyle(.plain)
                .disabled(model.viewState == .processing || model.viewState == .busyElsewhere)
                .accessibilityLabel(model.viewState == .recording ? "Stop dictation" : "Start dictation")
            }
            Text(model.notice ?? statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private var utilityRow: some View {
        HStack(spacing: 6) {
            if actions.nextKeyboard != nil {
                globeKey
            }
            KeyButton(title: "space", label: "Space", action: actions.space)
            KeyButton(systemImage: "delete.left", label: "Delete", action: actions.delete)
                .frame(width: 56)
            KeyButton(systemImage: "return", label: "Return", action: actions.returnKey)
                .frame(width: 72)
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private var globeKey: some View {
        if let nextKeyboard = actions.nextKeyboard {
            KeyButton(systemImage: "globe", label: "Next keyboard", action: nextKeyboard)
                .frame(width: 44)
        }
    }

    private var micSymbol: String {
        model.viewState == .recording ? "stop.fill" : "mic.fill"
    }

    private var micColor: Color {
        switch model.viewState {
        case .recording: return .red
        case .busyElsewhere: return .gray
        default: return .accentColor
        }
    }

    private var statusText: String {
        switch model.viewState {
        case .fullAccessRequired: return ""
        case .noSession: return "Tap to open MacParakeet and start the mic"
        case .idle: return "Tap to dictate"
        case .recording: return "Listening… tap to insert"
        case .processing: return "Transcribing…"
        case .busyElsewhere: return "MacParakeet is busy"
        }
    }
}

private struct KeyButton: View {
    var title: String?
    var systemImage: String?
    let label: String
    let action: () -> Void

    init(title: String, label: String, action: @escaping () -> Void) {
        self.title = title
        self.label = label
        self.action = action
    }

    init(systemImage: String, label: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else if let title {
                    Text(title)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
