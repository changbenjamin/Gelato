import Foundation

enum SessionFinalizer {
    private static let openAIUploadLimitBytes: Int64 = 25 * 1024 * 1024

    struct DiarizedTranscriptResult: Sendable {
        let didFinalize: Bool
        let errorMessage: String?
    }

    struct NotesResult: Sendable {
        let generatedTitle: String?
        let errorMessage: String?
    }

    static func generateCombinedAudioIfPossible(
        sessionID: String,
        library: SessionLibrary
    ) async {
        guard let audioFiles = await library.audioFiles(for: sessionID) else { return }
        let audioTiming = await library.audioTiming(for: sessionID)
        let outputURL = await library.combinedAudioOutputURL(for: sessionID)

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

    static func finalizeDiarizedTranscript(
        sessionID: String,
        sessionURL: URL,
        sessionTitle: String,
        apiKey: String,
        library: SessionLibrary,
        sessionStore: SessionStore,
        transcriptLogger: TranscriptLogger
    ) async -> DiarizedTranscriptResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(didFinalize: false, errorMessage: nil)
        }

        guard let audioFiles = await library.audioFiles(for: sessionID) else {
            return .init(didFinalize: false, errorMessage: nil)
        }

        let audioTiming = await library.audioTiming(for: sessionID)
        let liveUtterances = await library.loadTranscript(for: sessionID)
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
            guard let uploadURL else {
                return .init(didFinalize: false, errorMessage: nil)
            }

            diagLog("[OPENAI] uploading \(uploadURL.lastPathComponent) for \(sessionID)")
            let response: OpenAIDiarizedTranscriptResponse
            if uploadURL.path.contains("GelatoOpenAIUploads") {
                response = try await { () async throws -> OpenAIDiarizedTranscriptResponse in
                    defer { try? FileManager.default.removeItem(at: uploadURL) }
                    return try await service.transcribe(
                        audioURL: uploadURL,
                        apiKey: apiKey,
                        knownSpeakers: knownSpeakers
                    )
                }()
            } else {
                response = try await service.transcribe(
                    audioURL: uploadURL,
                    apiKey: apiKey,
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
            guard !utterances.isEmpty else {
                return .init(didFinalize: false, errorMessage: nil)
            }

            let records = utterances.map {
                SessionRecord(speaker: $0.speaker, text: $0.text, timestamp: $0.timestamp)
            }
            await sessionStore.replaceRecords(records)
            await transcriptLogger.replaceTranscript(with: utterances)

            let duration = utterances.last?.timestamp.timeIntervalSince(utterances.first?.timestamp ?? Date())
            await library.createMetadata(
                for: sessionURL,
                title: sessionTitle,
                utteranceCount: utterances.count,
                wordCount: utterances.reduce(0) { $0 + $1.text.split(separator: " ").count },
                duration: duration
            )
            return .init(didFinalize: true, errorMessage: nil)
        } catch {
            diagLog("[OPENAI-FAIL] \(sessionID): \(error.localizedDescription)")
            return .init(didFinalize: false, errorMessage: error.localizedDescription)
        }
    }

    static func generateNotesIfPossible(
        sessionID: String,
        sessionTitle: String,
        apiKey: String,
        library: SessionLibrary
    ) async -> NotesResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(generatedTitle: nil, errorMessage: nil)
        }

        let utterances = await library.loadTranscript(for: sessionID)
        guard !utterances.isEmpty else {
            return .init(generatedTitle: nil, errorMessage: nil)
        }

        let transcript = formattedTranscript(from: utterances)
        let userNotes = await library.loadNotes(for: sessionID)
        let service = OpenAINotesService()

        do {
            diagLog("[NOTES] generating notes for \(sessionID)")
            let generated = try await service.generateNotes(
                apiKey: apiKey,
                sessionTitle: sessionTitle,
                userNotes: userNotes,
                transcript: transcript
            )
            await library.upsertGeneratedNotes(for: sessionID, text: generated.notes)
            diagLog("[NOTES] saved notes for \(sessionID)")
            return .init(generatedTitle: generated.shortTitle, errorMessage: nil)
        } catch {
            diagLog("[NOTES-FAIL] \(sessionID): \(error.localizedDescription)")
            return .init(generatedTitle: nil, errorMessage: error.localizedDescription)
        }
    }

    private static func diarizationUploadURL(
        sessionID: String,
        audioFiles: SessionAudioFiles,
        audioTiming: SessionAudioTiming?
    ) async -> URL? {
        let hasSourceStems = audioFiles.micURL != nil || audioFiles.systemURL != nil

        if hasSourceStems {
            do {
                let uploadURL = try await OpenAIDiarizationInputBuilder.buildUploadFile(
                    audioFiles: audioFiles,
                    audioTiming: audioTiming,
                    sessionID: sessionID
                )

                if let uploadURL {
                    let fileSize = (try? uploadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    if fileSize > openAIUploadLimitBytes, let combinedURL = audioFiles.combinedURL {
                        diagLog(
                            "[OPENAI-UPLOAD] upload mix too large for \(sessionID) " +
                            "(\(fileSize) bytes), falling back to \(combinedURL.lastPathComponent)"
                        )
                        try? FileManager.default.removeItem(at: uploadURL)
                        return combinedURL
                    }

                    diagLog("[OPENAI-UPLOAD] built upload mix for \(sessionID): \(uploadURL.lastPathComponent)")
                    return uploadURL
                }

                diagLog("[OPENAI-UPLOAD] upload mix unavailable for \(sessionID)")
            } catch {
                diagLog("[OPENAI-UPLOAD-FAIL] \(sessionID): \(error.localizedDescription)")
            }
        }

        if let combinedURL = audioFiles.combinedURL {
            diagLog("[OPENAI-UPLOAD] falling back to combined audio for \(sessionID): \(combinedURL.lastPathComponent)")
            return combinedURL
        }

        return nil
    }

    private static func diarizedUtterances(
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

    private static func inferredSpeakerMap(
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

    private static func nearestLiveSpeaker(to timestamp: Date, liveUtterances: [Utterance]) -> Speaker? {
        guard let nearest = liveUtterances.min(by: {
            abs($0.timestamp.timeIntervalSince(timestamp)) < abs($1.timestamp.timeIntervalSince(timestamp))
        }) else {
            return nil
        }

        let distance = abs(nearest.timestamp.timeIntervalSince(timestamp))
        return distance <= 4 ? nearest.speaker : nil
    }

    private static func speakerScoreDelta(for label: String, scores: [String: [Speaker: Int]]) -> Int {
        let labelScores = scores[label] ?? [:]
        return labelScores[.you, default: 0] - labelScores[.them, default: 0]
    }

    private static func explicitSpeaker(for normalizedSpeaker: String) -> Speaker? {
        switch normalizedSpeaker {
        case "you":
            return .you
        case "them":
            return .them
        default:
            return nil
        }
    }

    private static func normalizedSpeakerKey(_ rawSpeaker: String) -> String {
        rawSpeaker
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func combinedAudioStartDate(audioTiming: SessionAudioTiming?, sessionID: String) -> Date {
        [audioTiming?.micFirstBufferAt, audioTiming?.systemFirstBufferAt]
            .compactMap { $0 }
            .min() ?? (SessionMetadataIO.parseDate(from: sessionID) ?? Date())
    }

    private static func formattedTranscript(from utterances: [Utterance]) -> String {
        let formatter = ISO8601DateFormatter()
        return utterances.chronologicallySorted.map { utterance in
            "[\(formatter.string(from: utterance.timestamp))] \(utterance.speaker == .you ? "You" : "Them"): \(utterance.text)"
        }
        .joined(separator: "\n")
    }
}
