import AppKit
import Combine
import SwiftUI

struct RecordingHUDView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if appState.phase.isRecording {
                    LiveAudioBars(level: appState.audioLevel)
                } else if appState.phase.isWorking {
                    ProcessingDots()
                } else {
                    Image(systemName: appState.phase.menuBarSymbol)
                        .foregroundStyle(indicatorColor)
                }
            }
            .frame(width: 44, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(appState.phase.title).fontWeight(.medium).lineLimit(1)
                    if case .recording(let startedAt) = appState.phase {
                        RecordingDuration(startedAt: startedAt)
                    }
                }
                if appState.phase.isWorking {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 250)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if appState.phase.isRecording {
                Button {
                    appState.cancelRecording()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }

    private var indicatorColor: Color {
        switch appState.phase {
        case .failure: .red
        case .copied: .blue
        default: .orange
        }
    }
}

private struct LiveAudioBars: View {
    let level: Float
    private let shape: [CGFloat] = [0.48, 0.78, 1, 0.64, 0.88, 0.58, 0.74]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(shape.indices, id: \.self) { index in
                Capsule()
                    .fill(.blue.gradient)
                    .frame(
                        width: 3,
                        height: 5 + max(0.08, CGFloat(level)) * 19 * shape[index]
                    )
            }
        }
        .animation(.smooth(duration: 0.1), value: level)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(level > 0.08 ? "Receiving audio" : "Very quiet")
    }
}

private struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    let wave = (sin(time * 5 - Double(index) * 0.8) + 1) / 2
                    Circle()
                        .fill(.blue.gradient)
                        .frame(width: 6, height: 6)
                        .offset(y: -3 * wave)
                        .opacity(0.45 + 0.55 * wave)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RecordingDuration: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(Self.formatted(timeline.date.timeIntervalSince(startedAt)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private static func formatted(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
final class RecordingHUDController {
    private let panel: NSPanel
    private var cancellable: AnyCancellable?

    init(appState: AppState) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 68),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: RecordingHUDView(appState: appState))

        cancellable = appState.$phase.sink { [weak self] phase in
            guard let self else { return }
            if phase == .idle {
                self.panel.orderOut(nil)
            } else {
                self.positionPanel()
                self.panel.orderFrontRegardless()
            }
        }
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.minY + 42
        ))
    }
}

private extension AppState.Phase {
    var isWorking: Bool {
        switch self {
        case .transcribing, .polishing, .inserting: true
        default: false
        }
    }

    var isRecording: Bool {
        if case .recording = self { true } else { false }
    }
}
