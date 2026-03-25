import SwiftUI

// MARK: - Shared tab enum & picker

enum DetailTab: String, CaseIterable {
    case notes = "Notes"
    case transcript = "Transcript"
}

/// Rounded-capsule toggle picker matching the Cowork/Code style.
struct DetailTabPicker: View {
    @Binding var selection: DetailTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            Group {
                                if selection == tab {
                                    Capsule()
                                        .fill(.background)
                                        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
    }
}

/// Detail panel showing the full transcript for a completed session with an editable title.
struct SessionDetailView: View {
    let session: SessionSummary
    let library: SessionLibrary
    let listModel: SessionListModel

    @State private var editableTitle: String = ""
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var utterances: [Utterance] = []
    @State private var isLoading = true
    @State private var selectedTab: DetailTab = .notes
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Title + metadata header
            VStack(alignment: .leading, spacing: 6) {
                TextField("Session title", text: $editableTitle)
                    .font(.system(size: 22, weight: .bold))
                    .textFieldStyle(.plain)
                    .focused($isTitleFocused)
                    .onSubmit {
                        isTitleFocused = false
                        titleSaveTask?.cancel()
                        Task {
                            let trimmed = editableTitle.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            await listModel.updateTitle(sessionID: session.id, newTitle: trimmed)
                        }
                    }

                HStack(spacing: 8) {
                    Text(formattedDate)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)

                    if let duration = session.metadata.durationSeconds, duration > 0 {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundStyle(.quaternary)
                        Text(formattedDuration(duration))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }

                    if !isLoading {
                        let wc = utterances.reduce(0) { $0 + $1.text.split(separator: " ").count }
                        if wc > 0 {
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundStyle(.quaternary)
                            Text(formatWordCount(wc))
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    if !utterances.isEmpty {
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
                NotesView(sessionID: session.id, library: library)

            case .transcript:
                if isLoading {
                    Spacer()
                    ProgressView("Loading transcript...")
                        .font(.system(size: 12))
                    Spacer()
                } else if utterances.isEmpty {
                    Spacer()
                    Text("No transcript data")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Spacer()
                } else {
                    VStack(spacing: 0) {
                        AudioSessionCard(sessionID: session.id, library: library)
                        Divider()
                        TranscriptView(
                            utterances: utterances,
                            volatileYouText: "",
                            volatileThemText: ""
                        )
                    }
                }
            }
        }
        .task {
            editableTitle = session.metadata.title
            let loaded = await library.loadTranscript(for: session.id)
            utterances = loaded
            isLoading = false
        }
        .onChange(of: editableTitle) {
            // Auto-save title on every change (debounced)
            titleSaveTask?.cancel()
            titleSaveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let trimmed = editableTitle.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                await listModel.updateTitle(sessionID: session.id, newTitle: trimmed)
            }
        }
    }

    // MARK: - Helpers

    private var formattedDate: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: session.metadata.createdAt)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        if mins < 1 { return "<1 min" }
        if mins < 60 { return "\(mins) min" }
        let hrs = mins / 60
        let remainMins = mins % 60
        if remainMins == 0 { return "\(hrs)h" }
        return "\(hrs)h \(remainMins)m"
    }

    private func copyTranscript() {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = utterances.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker == .you ? "You" : "Them"): \(u.text)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
