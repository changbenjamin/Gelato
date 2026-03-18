import SwiftUI

struct ContentView: View {
    @Bindable var settings: AppSettings

    // Transcription state
    @State private var transcriptStore = TranscriptStore()
    @State private var transcriptionEngine: TranscriptionEngine?
    @State private var sessionStore = SessionStore()
    @State private var transcriptLogger = TranscriptLogger()
    @State private var audioLevel: Float = 0

    // Session library state
    @State private var sessionLibrary = SessionLibrary()
    @State private var sessionListModel: SessionListModel?
    @State private var selectedSession: SessionSummary?
    @State private var liveSessionTitle: String = ""
    @State private var sessionStartTime: Date?

    // Onboarding
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            // Sidebar
            SessionListView(
                listModel: sessionListModel ?? SessionListModel(library: sessionLibrary),
                selectedSession: $selectedSession,
                isRunning: isRunning,
                liveTitle: liveSessionTitle,
                liveWordCount: transcriptStore.utterances.reduce(0) { $0 + $1.text.split(separator: " ").count },
                onStartSession: startSession
            )
        } detail: {
            // Detail panel
            if isRunning {
                LiveSessionView(
                    transcriptStore: transcriptStore,
                    transcriptionEngine: transcriptionEngine,
                    settings: settings,
                    liveTitle: $liveSessionTitle,
                    audioLevel: audioLevel,
                    onStop: stopSession
                )
            } else if let session = selectedSession {
                SessionDetailView(
                    session: session,
                    library: sessionLibrary,
                    listModel: sessionListModel ?? SessionListModel(library: sessionLibrary)
                )
                .id(session.id) // force recreate when selection changes
            } else {
                emptyDetailView
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .overlay {
            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .transition(.opacity)
            }
        }
        .onChange(of: showOnboarding) {
            if !showOnboarding {
                hasCompletedOnboarding = true
            }
        }
        .task {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
            if transcriptionEngine == nil {
                transcriptionEngine = TranscriptionEngine(transcriptStore: transcriptStore)
            }
            // Initialize session list
            let model = SessionListModel(library: sessionLibrary)
            sessionListModel = model
            await sessionLibrary.backfillMissingMetadata()
            await model.load()
            // Auto-select first session
            if let first = model.sessions.first {
                selectedSession = first
            }
        }
        .onChange(of: settings.inputDeviceID) {
            if isRunning {
                transcriptionEngine?.restartMic(inputDeviceID: settings.inputDeviceID)
            }
        }
        .onChange(of: transcriptStore.utterances.count) {
            handleNewUtterance()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            guard let engine = transcriptionEngine else {
                if audioLevel != 0 { audioLevel = 0 }
                return
            }
            if engine.isRunning {
                audioLevel = engine.audioLevel
            } else if audioLevel != 0 {
                audioLevel = 0
            }
        }
    }

    // MARK: - Empty Detail

    private var emptyDetailView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.quaternary)
            Text("Select a session")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Or tap New Note to start recording.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isRunning: Bool {
        transcriptionEngine?.isRunning ?? false
    }

    // MARK: - Actions

    private func startSession() {
        liveSessionTitle = SessionMetadataIO.defaultTitle(for: Date())
        sessionStartTime = Date()
        transcriptStore.clear()
        selectedSession = nil // detail panel will show live view since isRunning is true

        Task {
            await sessionStore.startSession()
            await transcriptLogger.startSession()
            await transcriptionEngine?.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID
            )
        }
    }

    private func stopSession() {
        transcriptionEngine?.stop()
        let utteranceCount = transcriptStore.utterances.count
        let wordCount = transcriptStore.utterances.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let duration: TimeInterval?
        if let start = sessionStartTime {
            duration = Date().timeIntervalSince(start)
        } else {
            duration = nil
        }

        Task {
            // Get session URL before ending (which clears it)
            let sessionURL = await sessionStore.currentSessionURL
            await sessionStore.endSession()
            await transcriptLogger.endSession()

            // Create metadata sidecar
            if let url = sessionURL {
                await sessionLibrary.createMetadata(
                    for: url,
                    title: liveSessionTitle,
                    utteranceCount: utteranceCount,
                    wordCount: wordCount,
                    duration: duration
                )
            }

            // Refresh list and auto-select the new session
            await sessionListModel?.refresh()
            if let first = sessionListModel?.sessions.first {
                selectedSession = first
            }
        }

        sessionStartTime = nil
    }

    private func handleNewUtterance() {
        let utterances = transcriptStore.utterances
        guard let last = utterances.last else { return }

        // Persist to transcript log
        Task {
            await transcriptLogger.append(
                speaker: last.speaker == .you ? "You" : "Them",
                text: last.text,
                timestamp: last.timestamp
            )
        }

        // Log session record
        Task {
            await sessionStore.appendRecord(SessionRecord(
                speaker: last.speaker,
                text: last.text,
                timestamp: last.timestamp
            ))
        }
    }
}
