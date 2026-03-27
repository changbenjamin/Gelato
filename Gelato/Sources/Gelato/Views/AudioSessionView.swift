import SwiftUI

struct AudioSessionCard: View {
    let sessionID: String
    let library: SessionLibrary

    @State private var audioFiles: SessionAudioFiles?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let audioFiles {
                AudioFileCard(
                    title: "Session Audio",
                    subtitle: "Play or reveal the session audio.",
                    fileURL: audioFiles.combinedURL ?? audioFiles.systemURL ?? audioFiles.micURL
                )
            } else {
                Text("Audio will appear here once the session recording is available.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmTextMuted)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color.warmBackground)
        .task {
            audioFiles = await library.audioFiles(for: sessionID)
        }
    }
}

private struct AudioFileCard: View {
    let title: String
    let subtitle: String?
    let fileURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.warmTextPrimary)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmTextMuted)
            }

            if let fileURL {
                HStack(spacing: 10) {
                    Button("Open") {
                        NSWorkspace.shared.open(fileURL)
                    }

                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Text("Not available")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmTextMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warmCardBg)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.warmBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
