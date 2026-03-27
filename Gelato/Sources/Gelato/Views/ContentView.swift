import SwiftUI

struct ContentView: View {
    @Bindable var settings: AppSettings

    // Transcription state
    @State private var transcriptStore = TranscriptStore()
    @State private var transcriptionEngine: TranscriptionEngine?
    @State private var sessionStore = SessionStore()
    @State private var transcriptLogger = TranscriptLogger()
    @State private var sessionAudioRecorder = SessionAudioRecorder()
    @State private var micAudioLevel: Float = 0
    @State private var systemAudioLevel: Float = 0
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
                liveStartTime: sessionStartTime,
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
                    micAudioLevel: micAudioLevel,
                    systemAudioLevel: systemAudioLevel,
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
                if micAudioLevel != 0 { micAudioLevel = 0 }
                if systemAudioLevel != 0 { systemAudioLevel = 0 }
                return
            }
            if engine.isRunning {
                micAudioLevel = engine.micAudioLevel
                systemAudioLevel = engine.systemAudioLevel
            } else {
                if micAudioLevel != 0 { micAudioLevel = 0 }
                if systemAudioLevel != 0 { systemAudioLevel = 0 }
            }
        }
    }

    // MARK: - Empty Detail

    private var emptyDetailView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.warmTextMuted.opacity(0.3))
            Text("Select a session")
                .font(.gelatoSerif(size: 22, weight: .semibold))
                .foregroundStyle(Color.warmTextSecondary)
            Text("Or tap New Note to start recording.")
                .font(.system(size: 13))
                .foregroundStyle(Color.warmTextMuted)
            if let finalizationMessage {
                Text(finalizationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmTextMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.warmBackground)
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
                sessionStart: sessionStartTime ?? Date(),
                audioRecorder: sessionAudioRecorder
            )
        }
    }

    private func stopSession() {
        let utteranceCount = transcriptStore.utterances.count
        let wordCount = transcriptStore.utterances.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let sessionID = liveSessionID
        var sessionTitle = liveSessionTitle
        let transcriptionMode = settings.transcriptionMode
        let openAIAPIKey = settings.openAIAPIKey
        let sessionLibrary = self.sessionLibrary
        let sessionStore = self.sessionStore
        let transcriptLogger = self.transcriptLogger
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
            diagLog("[SESSION-STOP] requested for \(sessionID ?? "unknown-session")")
            await transcriptionEngine?.stop()
            diagLog("[SESSION-STOP] engine stopped for \(sessionID ?? "unknown-session")")

            // Get session URL before ending (which clears it)
            let sessionURL = await sessionStore.currentSessionURL
            var didFinalizeAdvanced = false

            if let sessionID {
                processingStatus = "Creating combined audio..."
                await Task.detached(priority: .userInitiated) {
                    await SessionFinalizer.generateCombinedAudioIfPossible(
                        sessionID: sessionID,
                        library: sessionLibrary
                    )
                }.value
            }

            if transcriptionMode == .openAIDiarize,
               let sessionID,
               let sessionURL {
                processingStatus = "Processing audio with OpenAI gpt-4o-transcribe-diarize..."
                let sessionTitleForFinalization = sessionTitle
                let result = await Task.detached(priority: .userInitiated) {
                    await SessionFinalizer.finalizeDiarizedTranscript(
                        sessionID: sessionID,
                        sessionURL: sessionURL,
                        sessionTitle: sessionTitleForFinalization,
                        apiKey: openAIAPIKey,
                        library: sessionLibrary,
                        sessionStore: sessionStore,
                        transcriptLogger: transcriptLogger
                    )
                }.value
                didFinalizeAdvanced = result.didFinalize
                if let errorMessage = result.errorMessage {
                    finalizationMessage = errorMessage
                }
            }

            if let sessionID {
                processingStatus = "Generating title and detailed notes..."
                let sessionTitleForNotes = sessionTitle
                let notesResult = await Task.detached(priority: .userInitiated) {
                    await SessionFinalizer.generateNotesIfPossible(
                        sessionID: sessionID,
                        sessionTitle: sessionTitleForNotes,
                        apiKey: openAIAPIKey,
                        library: sessionLibrary
                    )
                }.value
                if let errorMessage = notesResult.errorMessage {
                    finalizationMessage = errorMessage
                }
                if let generatedTitle = notesResult.generatedTitle {
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
            if didFinalizeAdvanced || transcriptionMode != .openAIDiarize {
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
        let userNotes = await sessionLibrary.loadNotes(for: sessionID)
        let service = OpenAINotesService()

        do {
            diagLog("[NOTES] generating notes for \(sessionID)")
            let generated = try await service.generateNotes(
                apiKey: settings.openAIAPIKey,
                sessionTitle: sessionTitle,
                userNotes: userNotes,
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
        let audioTiming = await sessionLibrary.audioTiming(for: sessionID)
        let outputURL = await sessionLibrary.combinedAudioOutputURL(for: sessionID)

        do {
            diagLog(
                "[AUDIO] creating combined audio for \(sessionID) " +
                "mic=\(audioFiles.micURL != nil) system=\(audioFiles.systemURL != nil)"
            )
            _ = try await SessionAudioMixer.createCombinedAudio(
                micURL: audioFiles.micURL,
                systemURL: audioFiles.systemURL,
                outputURL: outputURL,
                audioTiming: audioTiming
            )
            diagLog("[AUDIO] combined audio created for \(sessionID)")
        } catch {
            diagLog("[AUDIO-FAIL] \(sessionID): \(error.localizedDescription)")
        }
    }

    private func finalizeDiarizedTranscript(sessionID: String, sessionURL: URL, sessionTitle: String) async -> Bool {
        guard let audioFiles = await sessionLibrary.audioFiles(for: sessionID) else {
            return false
        }

        let audioTiming = await sessionLibrary.audioTiming(for: sessionID)
        let liveUtterances = await sessionLibrary.loadTranscript(for: sessionID)
        let combinedStart = combinedAudioStartDate(audioTiming: audioTiming, sessionID: sessionID)
        let knownSpeakers = await OpenAISpeakerReferenceBuilder.buildReferences(
            audioFiles: audioFiles,
            audioTiming: audioTiming,
            liveUtterances: liveUtterances
        )
        let service = OpenAIDiarizedTranscriptionService()

        do {
            let uploadURL = await diarizationUploadURL(
                sessionID: sessionID,
                audioFiles: audioFiles,
                audioTiming: audioTiming
            )
            guard let uploadURL else { return false }

            diagLog("[OPENAI] uploading \(uploadURL.lastPathComponent) for \(sessionID)")
            let response: OpenAIDiarizedTranscriptResponse
            if uploadURL.path.contains("GelatoOpenAIUploads") {
                response = try await { () async throws -> OpenAIDiarizedTranscriptResponse in
                    defer { try? FileManager.default.removeItem(at: uploadURL) }
                    return try await service.transcribe(
                        audioURL: uploadURL,
                        apiKey: settings.openAIAPIKey,
                        knownSpeakers: knownSpeakers
                    )
                }()
            } else {
                response = try await service.transcribe(
                    audioURL: uploadURL,
                    apiKey: settings.openAIAPIKey,
                    knownSpeakers: knownSpeakers
                )
            }

            let speakerSummary = Set((response.segments ?? []).map(\.speaker)).sorted().joined(separator: ",")
            diagLog("[OPENAI] \(sessionID) textLength=\(response.text.count) segments=\(response.segments?.count ?? 0) speakers=[\(speakerSummary)]")
            let utterances = diarizedUtterances(
                from: response,
                sessionStart: combinedStart,
                liveUtterances: liveUtterances
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
            diagLog("[OPENAI-FAIL] \(sessionID): \(error.localizedDescription)")
            finalizationMessage = error.localizedDescription
            return false
        }
    }

    private func diarizationUploadURL(
        sessionID: String,
        audioFiles: SessionAudioFiles,
        audioTiming: SessionAudioTiming?
    ) async -> URL? {
        if let combinedURL = audioFiles.combinedURL {
            return combinedURL
        }

        do {
            let uploadURL = try await OpenAIDiarizationInputBuilder.buildUploadFile(
                audioFiles: audioFiles,
                audioTiming: audioTiming,
                sessionID: sessionID
            )

            if let uploadURL {
                diagLog("[OPENAI-UPLOAD] built fallback upload file for \(sessionID): \(uploadURL.lastPathComponent)")
            } else {
                diagLog("[OPENAI-UPLOAD] no upload file available for \(sessionID)")
            }

            return uploadURL
        } catch {
            diagLog("[OPENAI-UPLOAD-FAIL] \(sessionID): \(error.localizedDescription)")
            return nil
        }
    }

    private func diarizedUtterances(
        from response: OpenAIDiarizedTranscriptResponse,
        sessionStart: Date,
        liveUtterances: [Utterance]
    ) -> [Utterance] {
        guard let segments = response.segments, !segments.isEmpty else { return [] }

        let inferredSpeakers = inferredSpeakerMap(
            for: segments,
            sessionStart: sessionStart,
            liveUtterances: liveUtterances
        )

        return segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let speakerKey = normalizedSpeakerKey(segment.speaker)
            let speaker = explicitSpeaker(for: speakerKey)
                ?? inferredSpeakers[speakerKey]
                ?? nearestLiveSpeaker(
                    to: sessionStart.addingTimeInterval((segment.start + segment.end) / 2),
                    liveUtterances: liveUtterances
                )
                ?? .them

            return Utterance(
                text: text,
                speaker: speaker,
                timestamp: sessionStart.addingTimeInterval(max(0, segment.start))
            )
        }
        .chronologicallySorted
    }

    private func inferredSpeakerMap(
        for segments: [OpenAIDiarizedSegment],
        sessionStart: Date,
        liveUtterances: [Utterance]
    ) -> [String: Speaker] {
        let explicitSpeakers = Set(segments.compactMap { explicitSpeaker(for: normalizedSpeakerKey($0.speaker)) })
        let genericLabels = Array(Set(segments.map { normalizedSpeakerKey($0.speaker) }.filter {
            explicitSpeaker(for: $0) == nil
        }))

        guard !genericLabels.isEmpty else { return [:] }

        var scores: [String: [Speaker: Int]] = [:]
        for segment in segments {
            let label = normalizedSpeakerKey(segment.speaker)
            guard explicitSpeaker(for: label) == nil else { continue }
            guard let liveSpeaker = nearestLiveSpeaker(
                to: sessionStart.addingTimeInterval((segment.start + segment.end) / 2),
                liveUtterances: liveUtterances
            ) else {
                continue
            }
            scores[label, default: [:]][liveSpeaker, default: 0] += 1
        }

        if genericLabels.count == 1,
           let label = genericLabels.first {
            if explicitSpeakers.count == 1, let explicitSpeaker = explicitSpeakers.first {
                return [label: explicitSpeaker == .you ? .them : .you]
            }

            let labelScores = scores[label] ?? [:]
            let youScore = labelScores[.you, default: 0]
            let themScore = labelScores[.them, default: 0]
            return [label: youScore >= themScore ? .you : .them]
        }

        let sortedLabels = genericLabels.sorted { lhs, rhs in
            speakerScoreDelta(for: lhs, scores: scores) > speakerScoreDelta(for: rhs, scores: scores)
        }

        var mapping: [String: Speaker] = [:]
        for (index, label) in sortedLabels.enumerated() {
            mapping[label] = index == 0 ? .you : .them
        }
        return mapping
    }

    private func nearestLiveSpeaker(to timestamp: Date, liveUtterances: [Utterance]) -> Speaker? {
        guard let nearest = liveUtterances.min(by: {
            abs($0.timestamp.timeIntervalSince(timestamp)) < abs($1.timestamp.timeIntervalSince(timestamp))
        }) else {
            return nil
        }

        let distance = abs(nearest.timestamp.timeIntervalSince(timestamp))
        return distance <= 4 ? nearest.speaker : nil
    }

    private func speakerScoreDelta(for label: String, scores: [String: [Speaker: Int]]) -> Int {
        let labelScores = scores[label] ?? [:]
        return labelScores[.you, default: 0] - labelScores[.them, default: 0]
    }

    private func explicitSpeaker(for normalizedSpeaker: String) -> Speaker? {
        switch normalizedSpeaker {
        case "you":
            return .you
        case "them":
            return .them
        default:
            return nil
        }
    }

    private func normalizedSpeakerKey(_ rawSpeaker: String) -> String {
        rawSpeaker
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func combinedAudioStartDate(audioTiming: SessionAudioTiming?, sessionID: String) -> Date {
        [audioTiming?.micFirstBufferAt, audioTiming?.systemFirstBufferAt]
            .compactMap { $0 }
            .min() ?? (SessionMetadataIO.parseDate(from: sessionID) ?? Date())
    }

    private func formattedTranscript(from utterances: [Utterance]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return utterances.map { utterance in
            "[\(formatter.string(from: utterance.timestamp))] \(utterance.speaker == .you ? "You" : "Them"): \(utterance.text)"
        }.joined(separator: "\n")
    }
}
