import SwiftUI

struct ContentView: View {
    @Bindable var settings: AppSettings

    // Transcription state
    @State private var transcriptStore = TranscriptStore()
    @State private var transcriptionEngine: TranscriptionEngine?
    @State private var sessionStore = SessionStore()
    @State private var transcriptLogger = TranscriptLogger()
    @State private var sessionAudioRecorder = SessionAudioRecorder()
    @State private var audioLevel: Float = 0
    @State private var finalizationMessage: String?
    @State private var isProcessingSession = false
    @State private var processingStatus = "Processing session..."
    @State private var processingSessionTitle = ""

    // Session library state
    @State private var sessionLibrary = SessionLibrary()
    @State private var sessionListModel: SessionListModel?
    @State private var selectedSession: SessionSummary?
    @State private var liveSessionTitle: String = ""
    @State private var sessionStartTime: Date?
    @State private var liveSessionID: String?

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
                    sessionID: liveSessionID,
                    library: sessionLibrary,
                    onStop: stopSession
                )
            } else if isProcessingSession {
                ProcessingSessionView(
                    title: processingSessionTitle.isEmpty ? liveSessionTitle : processingSessionTitle,
                    status: processingStatus
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
            if let finalizationMessage {
                Text(finalizationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
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
            if let url = await sessionStore.currentSessionURL {
                liveSessionID = url.deletingPathExtension().lastPathComponent
                let sessionsDirectory = await sessionStore.sessionsDirectoryURL
                sessionAudioRecorder.start(sessionID: liveSessionID ?? "", in: sessionsDirectory)
            }
            await transcriptLogger.startSession()
            await transcriptionEngine?.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID,
                audioRecorder: sessionAudioRecorder
            )
        }
    }

    private func stopSession() {
        transcriptionEngine?.stop()
        let utteranceCount = transcriptStore.utterances.count
        let wordCount = transcriptStore.utterances.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let sessionID = liveSessionID
        var sessionTitle = liveSessionTitle
        let duration: TimeInterval?
        if let start = sessionStartTime {
            duration = Date().timeIntervalSince(start)
        } else {
            duration = nil
        }
        isProcessingSession = true
        processingStatus = "Finalizing transcript..."
        processingSessionTitle = sessionTitle

        Task {
            // Get session URL before ending (which clears it)
            let sessionURL = await sessionStore.currentSessionURL
            var didFinalizeAdvanced = false

            if settings.transcriptionMode == .scribeV2,
               let sessionID,
               let sessionURL {
                processingStatus = "Processing audio with ElevenLabs Scribe v2..."
                didFinalizeAdvanced = await finalizeAdvancedTranscript(
                    sessionID: sessionID,
                    sessionURL: sessionURL,
                    sessionTitle: sessionTitle
                )
            }

            if let sessionID {
                processingStatus = "Creating combined audio..."
                await generateCombinedAudioIfPossible(sessionID: sessionID)

                processingStatus = "Generating title and detailed notes..."
                if let generatedTitle = await generateNotesIfPossible(sessionID: sessionID, sessionTitle: sessionTitle) {
                    sessionTitle = generatedTitle
                    processingSessionTitle = generatedTitle
                }
            }

            await sessionStore.endSession()
            await transcriptLogger.endSession()

            // Create metadata sidecar
            if let url = sessionURL, !didFinalizeAdvanced {
                await sessionLibrary.createMetadata(
                    for: url,
                    title: sessionTitle,
                    utteranceCount: utteranceCount,
                    wordCount: wordCount,
                    duration: duration
                )
            }

            if let sessionID, !sessionTitle.isEmpty {
                await sessionLibrary.updateTitle(for: sessionID, newTitle: sessionTitle)
            }

            // Refresh list and auto-select the new session
            await sessionListModel?.refresh()
            if let first = sessionListModel?.sessions.first {
                selectedSession = first
            }
            isProcessingSession = false
            processingStatus = "Processing session..."
            if didFinalizeAdvanced || settings.transcriptionMode != .scribeV2 {
                finalizationMessage = nil
            }
        }

        sessionStartTime = nil
        liveSessionID = nil
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

    private func generateNotesIfPossible(sessionID: String, sessionTitle: String) async -> String? {
        guard !settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let utterances = await sessionLibrary.loadTranscript(for: sessionID)
        guard !utterances.isEmpty else { return nil }

        let transcript = formattedTranscript(from: utterances)
        let service = OpenAINotesService()

        do {
            diagLog("[NOTES] generating notes for \(sessionID)")
            let generated = try await service.generateNotes(
                apiKey: settings.openAIAPIKey,
                sessionTitle: sessionTitle,
                transcript: transcript
            )
            await sessionLibrary.upsertGeneratedNotes(for: sessionID, text: generated.notes)
            diagLog("[NOTES] saved notes for \(sessionID)")
            return generated.shortTitle
        } catch {
            diagLog("[NOTES-FAIL] \(sessionID): \(error.localizedDescription)")
            finalizationMessage = error.localizedDescription
            return nil
        }
    }

    private func generateCombinedAudioIfPossible(sessionID: String) async {
        guard let audioFiles = await sessionLibrary.audioFiles(for: sessionID) else { return }
        let outputURL = await sessionLibrary.combinedAudioOutputURL(for: sessionID)

        do {
            _ = try await SessionAudioMixer.createCombinedAudio(
                micURL: audioFiles.micURL,
                systemURL: audioFiles.systemURL,
                outputURL: outputURL
            )
            diagLog("[AUDIO] combined audio created for \(sessionID)")
        } catch {
            diagLog("[AUDIO-FAIL] \(sessionID): \(error.localizedDescription)")
        }
    }

    private func finalizeAdvancedTranscript(sessionID: String, sessionURL: URL, sessionTitle: String) async -> Bool {
        let audioFiles = await sessionLibrary.audioFiles(for: sessionID)
        let service = ElevenLabsScribeService()

        do {
            async let micResponse = transcribeIfPresent(audioFiles?.micURL, service: service)
            async let systemResponse = transcribeIfPresent(audioFiles?.systemURL, service: service)

            let utterances = try await mergeAdvancedUtterances(
                sessionID: sessionID,
                micResponse: micResponse,
                systemResponse: systemResponse
            )
            guard !utterances.isEmpty else { return false }

            let records = utterances.map {
                SessionRecord(speaker: $0.speaker, text: $0.text, timestamp: $0.timestamp)
            }
            await sessionStore.replaceRecords(records)
            await transcriptLogger.replaceTranscript(with: utterances)

            let duration = utterances.last?.timestamp.timeIntervalSince(utterances.first?.timestamp ?? Date())
            await sessionLibrary.createMetadata(
                for: sessionURL,
                title: sessionTitle,
                utteranceCount: utterances.count,
                wordCount: utterances.reduce(0) { $0 + $1.text.split(separator: " ").count },
                duration: duration
            )
            return true
        } catch {
            finalizationMessage = error.localizedDescription
            return false
        }
    }

    private func transcribeIfPresent(
        _ url: URL?,
        service: ElevenLabsScribeService
    ) async throws -> ScribeTranscriptResponse? {
        guard let url else { return nil }
        return try await service.transcribe(audioURL: url, apiKey: settings.elevenLabsAPIKey)
    }

    private func mergeAdvancedUtterances(
        sessionID: String,
        micResponse: ScribeTranscriptResponse?,
        systemResponse: ScribeTranscriptResponse?
    ) async throws -> [Utterance] {
        let startDate = SessionMetadataIO.parseDate(from: sessionID) ?? Date()
        let micUtterances = utterances(from: micResponse, speaker: .you, sessionStart: startDate)
        let systemUtterances = utterances(from: systemResponse, speaker: .them, sessionStart: startDate)
        return (micUtterances + systemUtterances).sorted { $0.timestamp < $1.timestamp }
    }

    private func utterances(
        from response: ScribeTranscriptResponse?,
        speaker: Speaker,
        sessionStart: Date
    ) -> [Utterance] {
        guard let words = response?.words, !words.isEmpty else {
            let fallback = response?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !fallback.isEmpty else { return [] }
            return [Utterance(text: fallback, speaker: speaker, timestamp: sessionStart)]
        }

        var results: [Utterance] = []
        var currentText = ""
        var currentStart: Double?
        var previousEnd: Double?

        func flush() {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let timestamp = sessionStart.addingTimeInterval(currentStart ?? 0)
            results.append(Utterance(text: trimmed, speaker: speaker, timestamp: timestamp))
            currentText = ""
            currentStart = nil
            previousEnd = nil
        }

        for word in words {
            if let start = word.start,
               let previousEnd,
               start - previousEnd > 1.2 {
                flush()
            }

            if word.type == "audio_event" {
                continue
            }

            if currentStart == nil {
                currentStart = word.start ?? 0
            }
            currentText.append(word.text)
            previousEnd = word.end ?? previousEnd

            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
                flush()
            }
        }

        flush()
        return results
    }

    private func formattedTranscript(from utterances: [Utterance]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return utterances.map { utterance in
            "[\(formatter.string(from: utterance.timestamp))] \(utterance.speaker == .you ? "You" : "Them"): \(utterance.text)"
        }.joined(separator: "\n")
    }
}
