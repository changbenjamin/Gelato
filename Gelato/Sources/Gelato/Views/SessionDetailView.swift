import SwiftUI

// MARK: - Shared tab enum & picker

enum DetailTab: String, CaseIterable {
    case notes = "Notes"
    case transcript = "Transcript"
    case chat = "Chat"
}

/// Rounded-capsule toggle picker matching the Cowork/Code style.
struct DetailTabPicker: View {
    let tabs: [DetailTab]
    @Binding var selection: DetailTab

    init(selection: Binding<DetailTab>, tabs: [DetailTab] = DetailTab.allCases) {
        self.tabs = tabs
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == tab ? Color.warmTextPrimary : Color.warmTextMuted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            Group {
                                if selection == tab {
                                    Capsule()
                                        .fill(Color.warmCardBg)
                                        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.warmHover))
    }
}

/// Detail panel showing the full transcript for a completed session with an editable title.
struct SessionDetailView: View {
    let session: SessionSummary
    let library: SessionLibrary
    let listModel: SessionListModel
    let openAIAPIKey: String

    @State private var editableTitle: String = ""
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var utterances: [Utterance] = []
    @State private var isLoading = true
    @State private var selectedTab: DetailTab = .notes
    @StateObject private var meetingQAStore = MeetingQAStore()
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Title + metadata header
            VStack(alignment: .leading, spacing: 6) {
                TextField("Session title", text: $editableTitle)
                    .font(.gelatoSerif(size: 28, weight: .semibold))
                    .foregroundStyle(Color.warmTextPrimary)
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
                        .foregroundStyle(Color.warmTextMuted)

                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmTextMuted.opacity(0.5))
                    Text(formatTime(session.metadata.createdAt))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warmTextMuted)

                    if let duration = session.metadata.durationSeconds, duration > 0 {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.warmTextMuted.opacity(0.5))
                        Text(formattedDuration(duration))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.warmTextMuted)
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

            ZStack(alignment: .bottom) {
                contentView

                if showsFloatingMeetingQA {
                    MeetingQAContainerView(
                        presentation: .floating,
                        store: meetingQAStore
                    )
                }
            }
        }
        .background(Color.warmBackground)
        .task(id: session.id) {
            editableTitle = session.metadata.title
            let loaded = await library.loadTranscript(for: session.id)
            utterances = loaded
            await meetingQAStore.prepare(
                sessionID: session.id,
                sessionTitle: editableTitle,
                utterances: loaded,
                library: library,
                apiKey: openAIAPIKey
            )
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
            meetingQAStore.updateContext(
                sessionTitle: editableTitle,
                utterances: utterances,
                library: library,
                apiKey: openAIAPIKey
            )
        }
    }

    // MARK: - Helpers

    private var formattedDate: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy"
        return fmt.string(from: session.metadata.createdAt)
    }

    private var showsFloatingMeetingQA: Bool {
        !isLoading && !utterances.isEmpty && selectedTab != .chat
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .notes:
            NotesView(sessionID: session.id, library: library)
                .padding(.bottom, showsFloatingMeetingQA ? 24 : 0)

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
                    .foregroundStyle(Color.warmTextMuted)
                Spacer()
            } else {
                VStack(spacing: 0) {
                    AudioSessionCard(sessionID: session.id, library: library)
                    Divider()
                        .overlay(Color.warmBorder)
                    TranscriptView(
                        utterances: utterances,
                        volatileYouText: "",
                        volatileThemText: ""
                    )
                }
                .padding(.bottom, showsFloatingMeetingQA ? 24 : 0)
            }

        case .chat:
            if isLoading {
                Spacer()
                ProgressView("Loading transcript...")
                    .font(.system(size: 12))
                Spacer()
            } else if utterances.isEmpty {
                Spacer()
                Text("No transcript data")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.warmTextMuted)
                Spacer()
            } else {
                MeetingQAContainerView(
                    presentation: .fullPage,
                    store: meetingQAStore
                )
            }
        }
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
        let lines = utterances.chronologicallySorted.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker == .you ? "You" : "Them"): \(u.text)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
