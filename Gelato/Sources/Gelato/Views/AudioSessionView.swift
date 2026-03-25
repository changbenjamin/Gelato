import SwiftUI

struct AudioSessionCard: View {
    let sessionID: String
    let library: SessionLibrary

    @State private var audioFiles: SessionAudioFiles?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session Audio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            if let audioFiles {
                AudioFileCard(
                    title: "Combined Session Audio",
                    subtitle: "Play, reveal, or export the mixed session audio.",
                    fileURL: audioFiles.combinedURL ?? audioFiles.micURL ?? audioFiles.systemURL
                )
            } else {
                Text("Audio will appear here once the session recording is available.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
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

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let fileURL {
                HStack(spacing: 10) {
                    Button("Open") {
                        NSWorkspace.shared.open(fileURL)
                    }

                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }

                    Button("Export...") {
                        export(fileURL: fileURL)
                    }
                }
                .buttonStyle(.bordered)

                Text(fileURL.lastPathComponent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("Not available")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func export(fileURL: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: fileURL, to: destination)
            } catch {
                diagLog("[AUDIO-EXPORT-FAIL] \(error.localizedDescription)")
            }
        }
    }
}
