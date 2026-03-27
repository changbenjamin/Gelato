import SwiftUI

struct ControlBar: View {
    let isRunning: Bool
    let micAudioLevel: Float
    let systemAudioLevel: Float
    let statusMessage: String?
    let errorMessage: String?
    let onToggle: () -> Void

    private var overallAudioLevel: Float {
        max(micAudioLevel, systemAudioLevel)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(GelatoTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            // Status message (model loading, etc.)
            if let status = statusMessage, status != "Ready" {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warmTextMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            HStack(spacing: 10) {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        // Pulsing dot when live, static when idle
                        Circle()
                            .fill(isRunning ? GelatoTheme.success : Color.warmTextMuted.opacity(0.5))
                            .frame(width: 8, height: 8)
                            .scaleEffect(isRunning ? 1.0 + CGFloat(overallAudioLevel) * 0.5 : 1.0)
                            .animation(.easeOut(duration: 0.1), value: overallAudioLevel)

                        Text(isRunning ? "Live" : "Idle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isRunning ? Color.warmTextPrimary : Color.warmTextMuted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(isRunning ? GelatoTheme.success.opacity(0.14) : Color.warmCardBg)
                    .overlay {
                        Capsule()
                            .stroke(isRunning ? GelatoTheme.success.opacity(0.22) : Color.warmBorder, lineWidth: 1)
                    }
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                // Audio level bars + stop button when running
                if isRunning {
                    DualAudioLevelView(micLevel: micAudioLevel, systemLevel: systemAudioLevel)

                    Button(action: onToggle) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(GelatoTheme.danger)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Stop recording")
                }

                Spacer()

                Text("Parakeet-TDT v2")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.warmTextMuted.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.warmCardBg)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.warmBackground)
    }

}

/// Mini audio level visualizer — a few bars that react to a single input.
struct AudioLevelView: View {
    let level: Float
    let activeColor: Color

    init(level: Float, activeColor: Color = Color.accentTeal) {
        self.level = level
        self.activeColor = activeColor
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let threshold = Float(i) / 5.0
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? activeColor.opacity(0.8) : Color.warmBorder.opacity(0.55))
                    .frame(width: 3)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

struct DualAudioLevelView: View {
    let micLevel: Float
    let systemLevel: Float

    var body: some View {
        HStack(spacing: 8) {
            LabeledAudioLevelView(
                title: "You",
                level: micLevel,
                activeColor: Color.youColor
            )
            LabeledAudioLevelView(
                title: "Them",
                level: systemLevel,
                activeColor: Color.themColor
            )
        }
    }
}

private struct LabeledAudioLevelView: View {
    let title: String
    let level: Float
    let activeColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.warmTextMuted)
            AudioLevelView(level: level, activeColor: activeColor)
                .frame(width: 28, height: 12)
        }
    }
}
