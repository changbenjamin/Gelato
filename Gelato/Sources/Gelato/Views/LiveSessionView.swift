import SwiftUI
import CoreAudio

/// Detail panel for the live transcription session.
struct LiveSessionView: View {
    let transcriptStore: TranscriptStore
    let transcriptionEngine: TranscriptionEngine?
    @Bindable var settings: AppSettings
    @Binding var liveTitle: String
    let sessionStartTime: Date?
    let micAudioLevel: Float
    let systemAudioLevel: Float
    let sessionID: String?
    let library: SessionLibrary
    let onStop: () -> Void

    @State private var selectedTab: DetailTab = .transcript
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []

    var body: some View {
        VStack(spacing: 0) {
            // Title + live indicator header
            VStack(alignment: .leading, spacing: 6) {
                TextField("Session title", text: $liveTitle)
                    .font(.gelatoSerif(size: 28, weight: .semibold))
                    .foregroundStyle(Color.warmTextPrimary)
                    .textFieldStyle(.plain)

                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Live")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.green)
                    }

                    if let sessionStartTime {
                        RecordingElapsedBadge(startedAt: sessionStartTime)
                    }

                    Spacer()

                    microphoneMenu

                    if !transcriptStore.utterances.isEmpty {
                        Button {
                            copyTranscript()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                Text("Copy")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(Color.warmTextMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 14)

            // Tab picker
            HStack {
                DetailTabPicker(selection: $selectedTab, tabs: [.notes, .transcript])
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()
                .overlay(Color.warmBorder)

            // Content based on selected tab
            switch selectedTab {
            case .notes:
                if let sessionID {
                    NotesView(sessionID: sessionID, library: library)
                } else {
                    Spacer()
                    Text("Notes will be available once recording begins...")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

            case .transcript:
                VStack(spacing: 0) {
                    if let sessionID {
                        AudioSessionCard(sessionID: sessionID, library: library)
                    }
                    Divider()
                    TranscriptView(
                        utterances: transcriptStore.utterances,
                        volatileYouText: transcriptStore.volatileYouText,
                        volatileThemText: transcriptStore.volatileThemText
                    )
                }

            case .chat:
                Spacer()
                Text("Chat becomes available after the meeting is finished.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.warmTextMuted)
                Spacer()
            }

            Divider()
                .overlay(Color.warmBorder)

            // Control bar
            ControlBar(
                isRunning: transcriptionEngine?.isRunning ?? false,
                micAudioLevel: micAudioLevel,
                systemAudioLevel: systemAudioLevel,
                statusMessage: transcriptionEngine?.assetStatus,
                errorMessage: transcriptionEngine?.lastError,
                onToggle: onStop
            )
        }
        .background(Color.warmBackground)
        .onAppear(perform: refreshInputDevices)
    }

    private func copyTranscript() {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = transcriptStore.utterances.chronologicallySorted.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker == .you ? "You" : "Them"): \(u.text)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private var microphoneMenu: some View {
        Menu {
            Button {
                refreshInputDevices()
            } label: {
                Label("Refresh Microphones", systemImage: "arrow.clockwise")
            }

            Divider()

            Button {
                settings.inputDeviceID = 0
            } label: {
                microphoneMenuOptionLabel(
                    title: "Automatic",
                    subtitle: automaticMicrophoneName ?? "No microphone available",
                    isSelected: settings.inputDeviceID == 0
                )
            }

            ForEach(inputDevices, id: \.id) { device in
                Button {
                    settings.inputDeviceID = device.id
                } label: {
                    microphoneMenuOptionLabel(
                        title: device.name,
                        subtitle: nil,
                        isSelected: settings.inputDeviceID == device.id
                    )
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))

                VStack(alignment: .leading, spacing: 1) {
                    Text(resolvedMicrophoneName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.warmTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(settings.inputDeviceID == 0 ? "Automatic microphone" : "Selected microphone")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.warmTextMuted)
                }
                .frame(maxWidth: 180, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.warmTextMuted)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.warmCardBg)
            .overlay {
                Capsule()
                    .stroke(Color.warmBorder, lineWidth: 1)
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(microphoneHelpText)
    }

    @ViewBuilder
    private func microphoneMenuOptionLabel(
        title: String,
        subtitle: String?,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark" : "circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentTeal : Color.clear)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var automaticMicrophoneName: String? {
        MicCapture.automaticInputDeviceName()
    }

    private var resolvedMicrophoneName: String {
        if settings.inputDeviceID == 0 {
            return automaticMicrophoneName ?? "No microphone"
        }

        return MicCapture.inputDeviceName(for: settings.inputDeviceID)
            ?? inputDevices.first(where: { $0.id == settings.inputDeviceID })?.name
            ?? "Unavailable microphone"
    }

    private var microphoneHelpText: String {
        if settings.inputDeviceID == 0 {
            return "Currently recording from \(resolvedMicrophoneName) via automatic microphone selection."
        }

        return "Currently recording from \(resolvedMicrophoneName)."
    }

    private func refreshInputDevices() {
        inputDevices = MicCapture.availableInputDevices()
    }
}

private struct RecordingElapsedBadge: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.warmTextMuted)

                Text(elapsedText(at: context.date))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.warmTextPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.warmCardBg)
            .overlay {
                Capsule()
                    .stroke(Color.warmBorder, lineWidth: 1)
            }
            .clipShape(Capsule())
        }
    }

    private func elapsedText(at now: Date) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
