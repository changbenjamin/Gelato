import AppKit
import SwiftUI

enum MeetingQAPresentation {
    case floating
    case fullPage
}

@MainActor
final class MeetingQAStore: ObservableObject {
    @Published var conversation: MeetingQAConversation = .empty
    @Published var draft = ""
    @Published var isLoaded = false
    @Published var isSubmitting = false

    private let qaService = OpenAIMeetingQAService()
    private var sessionID: String?
    private var sessionTitle = ""
    private var utterances: [Utterance] = []
    private var library: SessionLibrary?
    private var apiKey = ""

    var isAPIKeyMissing: Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSubmitQuestion: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
            && !utterances.isEmpty
            && !isAPIKeyMissing
    }

    func prepare(
        sessionID: String,
        sessionTitle: String,
        utterances: [Utterance],
        library: SessionLibrary,
        apiKey: String
    ) async {
        updateContext(
            sessionTitle: sessionTitle,
            utterances: utterances,
            library: library,
            apiKey: apiKey
        )

        guard self.sessionID != sessionID || !isLoaded else { return }

        if self.sessionID != sessionID {
            self.sessionID = sessionID
            conversation = .empty
            draft = ""
            isLoaded = false
            isSubmitting = false
        }

        let loadedConversation = await library.loadMeetingQAConversation(for: sessionID)

        if conversation.messages.isEmpty {
            conversation = loadedConversation
        } else {
            let loadedIDs = Set(loadedConversation.messages.map(\.id))
            let unsavedMessages = conversation.messages.filter { !loadedIDs.contains($0.id) }
            conversation = MeetingQAConversation(messages: loadedConversation.messages + unsavedMessages)
        }

        isLoaded = true
        persistConversation()
    }

    func updateContext(
        sessionTitle: String,
        utterances: [Utterance],
        library: SessionLibrary,
        apiKey: String
    ) {
        self.sessionTitle = sessionTitle
        self.utterances = utterances
        self.library = library
        self.apiKey = apiKey
    }

    func submitQuestion() {
        let trimmedQuestion = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !isSubmitting else { return }

        draft = ""
        isSubmitting = true

        let userMessage = MeetingQAMessage(role: .user, content: trimmedQuestion)
        conversation.messages.append(userMessage)
        persistConversation()

        guard let sessionID else {
            isSubmitting = false
            return
        }

        let snapshotTranscript = formattedTranscript(from: utterances)
        let snapshotTitle = sessionTitle
        let snapshotHistory = Array(conversation.messages.dropLast())
        let snapshotAPIKey = apiKey

        Task {
            let reply: String
            do {
                reply = try await qaService.answerQuestion(
                    apiKey: snapshotAPIKey,
                    sessionTitle: snapshotTitle,
                    transcript: snapshotTranscript,
                    history: snapshotHistory,
                    question: trimmedQuestion
                )
            } catch {
                reply = error.localizedDescription
            }

            await MainActor.run {
                guard self.sessionID == sessionID else { return }
                conversation.messages.append(MeetingQAMessage(role: .assistant, content: reply))
                isSubmitting = false
                persistConversation()
            }
        }
    }

    private func persistConversation() {
        guard isLoaded, let sessionID, let library else { return }
        let snapshot = conversation
        Task {
            await library.saveMeetingQAConversation(for: sessionID, conversation: snapshot)
        }
    }

    private func formattedTranscript(from utterances: [Utterance]) -> String {
        let formatter = ISO8601DateFormatter()
        return utterances.chronologicallySorted.map { utterance in
            "[\(formatter.string(from: utterance.timestamp))] \(utterance.speaker == .you ? "You" : "Them"): \(utterance.text)"
        }
        .joined(separator: "\n")
    }
}

struct MeetingQAContainerView: View {
    let presentation: MeetingQAPresentation
    @ObservedObject var store: MeetingQAStore

    @State private var isExpanded = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        Group {
            switch presentation {
            case .floating:
                floatingOverlay
            case .fullPage:
                fullPageView
            }
        }
    }

    private var floatingOverlay: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: Color.warmBackground.opacity(0), location: 0),
                    .init(color: Color.warmBackground.opacity(0.22), location: 0.34),
                    .init(color: Color.warmBackground, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: isExpanded ? 460 : 210)
            .allowsHitTesting(false)

            Group {
                if isExpanded {
                    expandedPanel(showsWindowControls: true, fillsHeight: false)
                        .frame(maxWidth: 860)
                } else {
                    collapsedPanel
                        .frame(maxWidth: 860)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var collapsedPanel: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                isExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                isComposerFocused = true
            }
        } label: {
            collapsedComposerBar
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.warmCardBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.warmBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
        }
        .buttonStyle(StaticButtonStyle())
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var collapsedComposerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Ask anything here")
                .font(.system(size: 15))
                .foregroundStyle(Color(nsColor: .placeholderTextColor))
                .lineSpacing(0)
            Spacer()

            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .placeholderTextColor))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.warmHover))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.warmBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.warmBorder, lineWidth: 1)
                )
        )
    }

    private func expandedPanel(showsWindowControls: Bool, fillsHeight: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("Chat about this meeting")
                    .font(.gelatoSerif(size: fillsHeight ? 24 : 22, weight: .semibold))
                    .foregroundStyle(Color.warmTextPrimary)

                Spacer()

                if showsWindowControls {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded = false
                            isComposerFocused = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.warmTextMuted)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.warmBackground))
                            .overlay(Circle().stroke(Color.warmBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()
                .overlay(Color.warmBorder)

            MeetingQAMessageList(
                messages: store.conversation.messages,
                isSubmitting: store.isSubmitting
            )
            .frame(
                minHeight: fillsHeight ? 0 : 220,
                maxHeight: fillsHeight ? .infinity : 360
            )
            .background(Color.warmCanvasBg)

            Divider()
                .overlay(Color.warmBorder)

            composer
                .padding(16)
                .background(Color.warmCardBg)
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil)
        .background(Color.warmCardBg)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.warmBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }

    private var fullPageView: some View {
        VStack(spacing: 0) {
            MeetingQAMessageList(
                messages: store.conversation.messages,
                isSubmitting: store.isSubmitting
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.warmBackground)

            Divider()
                .overlay(Color.warmBorder)

            composer
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .background(Color.warmBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.warmBackground)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isAPIKeyMissing {
                Text("Add `OPENAI_API_KEY` in `.env` to ask questions about this meeting.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmTextMuted)
            }

            HStack(alignment: .center, spacing: 10) {
                TextField("Ask anything here", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.warmTextPrimary)
                    .lineSpacing(0)
                    .lineLimit(1...3)
                    .focused($isComposerFocused)
                    .disabled(store.isSubmitting || store.isAPIKeyMissing)
                    .onSubmit {
                        submitQuestion()
                    }

                Button {
                    submitQuestion()
                } label: {
                    if store.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                }
                .buttonStyle(.plain)
                .background(Circle().fill(store.canSubmitQuestion ? Color.warmThemTint : Color.warmHover))
                .foregroundStyle(store.canSubmitQuestion ? Color.warmTextPrimary : Color.warmTextMuted)
                .clipShape(Circle())
                .disabled(!store.canSubmitQuestion)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.warmBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.warmBorder, lineWidth: 1)
                    )
            )
        }
    }

    private func submitQuestion() {
        guard store.canSubmitQuestion else { return }
        if presentation == .floating {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded = true
            }
        }
        store.submitQuestion()
    }
}

private struct StaticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct MeetingQAMessageList: View {
    let messages: [MeetingQAMessage]
    let isSubmitting: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ask about owners, deadlines, commitments, or decisions.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.warmTextSecondary)
                            Text("The answer will be grounded in the transcript for this meeting.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.warmTextMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }

                    ForEach(messages) { message in
                        MeetingQAMessageRow(message: message)
                            .id(message.id)
                    }

                    if isSubmitting {
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Looking through the meeting transcript...")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.warmTextMuted)
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(Color.warmCardBg)
                            )
                            Spacer(minLength: 50)
                        }
                        .id("meeting-qa-loading")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .onAppear {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: isSubmitting) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if isSubmitting {
                proxy.scrollTo("meeting-qa-loading", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct MeetingQAMessageRow: View {
    let message: MeetingQAMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.content)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.warmTextPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.warmHover)
                    )
                    .textSelection(.enabled)
            }

        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text(renderedContent)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.readingText)
                        .textSelection(.enabled)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.warmCardBg)
                )
                Spacer(minLength: 50)
            }
        }
    }

    private var renderedContent: AttributedString {
        if let attributed = try? AttributedString(
            markdown: message.content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attributed
        }

        return AttributedString(message.content)
    }
}
