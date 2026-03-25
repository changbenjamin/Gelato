import SwiftUI

/// Detail panel for the live transcription session.
struct LiveSessionView: View {
    let transcriptStore: TranscriptStore
    let transcriptionEngine: TranscriptionEngine?
    @Bindable var settings: AppSettings
    @Binding var liveTitle: String
    let audioLevel: Float
    let sessionID: String?
    let library: SessionLibrary
    let onStop: () -> Void

    @State private var selectedTab: DetailTab = .transcript

    var body: some View {
        VStack(spacing: 0) {
            // Title + live indicator header
            VStack(alignment: .leading, spacing: 6) {
                TextField("Session title", text: $liveTitle)
                    .font(.system(size: 22, weight: .bold))
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
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Tab picker
            HStack {
                DetailTabPicker(selection: $selectedTab)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

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

            // Control bar
            ControlBar(
                isRunning: transcriptionEngine?.isRunning ?? false,
                audioLevel: audioLevel,
                statusMessage: transcriptionEngine?.assetStatus,
                errorMessage: transcriptionEngine?.lastError,
                onToggle: onStop
            )
        }
    }

    private func copyTranscript() {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = transcriptStore.utterances.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker == .you ? "You" : "Them"): \(u.text)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
