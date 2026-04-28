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
                        .contentShape(Rectangle())
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
    @State private var notesMarkdown = ""
    @State private var isLoading = true
    @State private var isRegenerating = false
    @State private var regeneratingStatus = "Processing session..."
    @State private var regenerationErrorMessage: String?
    @State private var selectedTab: DetailTab = .notes
    @StateObject private var meetingQAStore = MeetingQAStore()
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        Group {
            if isRegenerating {
                ProcessingSessionView(
                    title: "Regenerating...",
                    status: regeneratingStatus
                )
            } else {
                normalDetailView
            }
        }
        .background(Color.warmBackground)
        .task(id: session.id) {
            editableTitle = session.metadata.title
            await reloadSessionContent()
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
        .alert(
            "Couldn't Regenerate",
            isPresented: Binding(
                get: { regenerationErrorMessage != nil },
                set: { if !$0 { regenerationErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(regenerationErrorMessage ?? "")
        }
    }

    private var normalDetailView: some View {
        VStack(spacing: 0) {
            // Title + metadata header
            VStack(alignment: .leading, spacing: 6) {
                TextField("Session title", text: $editableTitle, axis: .vertical)
                    .font(.gelatoSerif(size: 28, weight: .semibold))
                    .foregroundStyle(Color.warmTextPrimary)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .fixedSize(horizontal: false, vertical: true)
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
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 14)

            // Tab picker
            HStack {
                DetailTabPicker(selection: $selectedTab)
                Spacer()

                Button {
                    regenerateTranscriptAndNotes()
                } label: {
                    HStack(spacing: 6) {
                        Text("Regenerate")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        Capsule()
                            .fill(Color.warmCardBg)
                    )
                    .foregroundStyle(Color.warmTextMuted)
                    .overlay(
                        Capsule()
                            .stroke(Color.warmTextMuted.opacity(0.75), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canRegenerateCurrentSession)
                .help(regenerateButtonHelp)

                Button {
                    copyCurrentTab()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                        Text("Copy")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        Capsule()
                            .fill(Color.warmCardBg)
                    )
                    .foregroundStyle(Color.warmTextMuted)
                    .overlay(
                        Capsule()
                            .stroke(Color.warmTextMuted.opacity(0.75), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canCopyCurrentTab)
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
            NotesView(
                sessionID: session.id,
                library: library,
                bottomContentInset: 0,
                onTextChange: { notesMarkdown = $0 }
            )
                .padding(.bottom, showsFloatingMeetingQA ? 8 : 0)

        case .transcript:
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading transcript...")
                        .font(.system(size: 12))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if utterances.isEmpty {
                VStack {
                    Spacer()
                    Text("No transcript yet")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.warmTextMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    AudioSessionCard(sessionID: session.id, library: library)
                    Divider()
                        .overlay(Color.warmBorder)
                    TranscriptView(
                        utterances: utterances,
                        volatileYouText: "",
                        volatileThemText: "",
                        bottomContentPadding: floatingChatClearance
                    )
                }
                .padding(.bottom, showsFloatingMeetingQA ? 8 : 0)
            }

        case .chat:
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading transcript...")
                        .font(.system(size: 12))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if utterances.isEmpty {
                VStack {
                    Spacer()
                    Text("No chat yet")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.warmTextMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var floatingChatClearance: CGFloat {
        showsFloatingMeetingQA ? 280 : 0
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

    private var canCopyCurrentTab: Bool {
        switch selectedTab {
        case .notes:
            return true
        case .transcript:
            return !utterances.isEmpty
        case .chat:
            return !meetingQAStore.conversation.messages.isEmpty
        }
    }

    private var canRegenerateCurrentSession: Bool {
        !isRegenerating &&
            !utterances.isEmpty &&
            !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var regenerateButtonHelp: String {
        if openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add an OpenAI API key to regenerate the transcript and notes."
        }
        if utterances.isEmpty {
            return "This session doesn’t have a Parakeet transcript to clean."
        }
        return "Clean the saved Parakeet transcript and regenerate notes."
    }

    private func copyCurrentTab() {
        switch selectedTab {
        case .notes:
            copyToPasteboard(notesMarkdown)
        case .transcript:
            copyTranscript()
        case .chat:
            copyChatConversation()
        }
    }

    private func copyChatConversation() {
        let lines = meetingQAStore.conversation.messages.map { message in
            let speaker = message.role == .user ? "You" : "ChatGPT"
            return "\(speaker): \(message.content)"
        }
        copyToPasteboard(lines.joined(separator: "\n\n"))
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func regenerateTranscriptAndNotes() {
        guard canRegenerateCurrentSession else { return }

        let currentTitle = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTitle = currentTitle.isEmpty ? session.metadata.title : currentTitle
        regenerationErrorMessage = nil
        regeneratingStatus = "Processing transcript..."
        isRegenerating = true

        Task {
            let transcriptResult = await SessionFinalizer.finalizeCleanedTranscript(
                sessionID: session.id,
                sessionURL: session.jsonlURL,
                sessionTitle: sessionTitle,
                apiKey: openAIAPIKey,
                library: library
            )

            guard transcriptResult.didClean else {
                let message = transcriptResult.errorMessage
                    ?? "Gelato couldn’t regenerate a transcript for this session."
                regenerationErrorMessage = message
                isRegenerating = false
                return
            }

            regeneratingStatus = "Generating title and detailed notes..."

            let notesResult = await SessionFinalizer.generateNotesIfPossible(
                sessionID: session.id,
                sessionTitle: sessionTitle,
                apiKey: openAIAPIKey,
                library: library
            )

            if let generatedTitle = notesResult.generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !generatedTitle.isEmpty {
                await library.updateTitle(for: session.id, newTitle: generatedTitle)
            }

            await listModel.refresh()
            await reloadSessionContent()

            if let errorMessage = notesResult.errorMessage {
                regenerationErrorMessage = errorMessage
            }
            isRegenerating = false
        }
    }

    private func reloadSessionContent() async {
        let loadedTranscript = await library.loadTranscript(for: session.id)
        let loadedNotes = await library.loadNotes(for: session.id)
        let refreshedTitle = await refreshedSessionTitle()

        editableTitle = refreshedTitle
        notesMarkdown = loadedNotes
        utterances = loadedTranscript

        await meetingQAStore.prepare(
            sessionID: session.id,
            sessionTitle: refreshedTitle,
            utterances: loadedTranscript,
            library: library,
            apiKey: openAIAPIKey
        )
        isLoading = false
    }

    private func refreshedSessionTitle() async -> String {
        let refreshedSessions = await library.loadSessions()
        return refreshedSessions.first(where: { $0.id == session.id })?.metadata.title ?? session.metadata.title
    }
}
