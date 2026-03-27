import SwiftUI

/// Detail panel for the live transcription session.
struct LiveSessionView: View {
    let transcriptStore: TranscriptStore
    let transcriptionEngine: TranscriptionEngine?
    @Bindable var settings: AppSettings
    @Binding var liveTitle: String
    let micAudioLevel: Float
    let systemAudioLevel: Float
    let sessionID: String?
    let library: SessionLibrary
    let onStop: () -> Void

    @State private var selectedTab: DetailTab = .transcript

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

                    Spacer()

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
                DetailTabPicker(selection: $selectedTab)
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
}
