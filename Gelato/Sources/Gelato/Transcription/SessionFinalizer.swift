import Foundation

enum SessionFinalizer {
    struct TranscriptCleanupResult: Sendable {
        let didClean: Bool
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

    static func finalizeCleanedTranscript(
        sessionID: String,
        sessionURL: URL,
        sessionTitle: String,
        apiKey: String,
        library: SessionLibrary,
        transcriptLogger: TranscriptLogger? = nil,
        parakeetSourceUtterances: [Utterance]? = nil
    ) async -> TranscriptCleanupResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(didClean: false, errorMessage: nil)
        }

        if let parakeetSourceUtterances, !parakeetSourceUtterances.isEmpty {
            await library.saveOriginalTranscriptIfMissing(for: sessionID, utterances: parakeetSourceUtterances)
        }

        let originalUtterances = await library.loadOriginalTranscript(for: sessionID)
        let sourceUtterances = originalUtterances.isEmpty
            ? await library.loadTranscript(for: sessionID)
            : originalUtterances

        guard !sourceUtterances.isEmpty else {
            return .init(didClean: false, errorMessage: nil)
        }

        do {
            diagLog("[OPENAI-CLEANUP] cleaning Parakeet transcript for \(sessionID)")
            let service = OpenAITranscriptCleanupService()
            let utterances = try await service.cleanTranscript(
                apiKey: apiKey,
                utterances: sourceUtterances
            )
            guard !utterances.isEmpty else {
                return .init(didClean: false, errorMessage: nil)
            }

            await library.replaceTranscript(for: sessionID, utterances: utterances)
            await transcriptLogger?.replaceTranscript(with: utterances)

            let duration = utterances.last?.timestamp.timeIntervalSince(utterances.first?.timestamp ?? Date())
            await library.createMetadata(
                for: sessionURL,
                title: sessionTitle,
                utteranceCount: utterances.count,
                wordCount: utterances.reduce(0) { $0 + $1.text.split(separator: " ").count },
                duration: duration
            )
            return .init(didClean: true, errorMessage: nil)
        } catch {
            diagLog("[OPENAI-CLEANUP-FAIL] \(sessionID): \(error.localizedDescription)")
            return .init(didClean: false, errorMessage: error.localizedDescription)
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
        let userNotes = await library.userNotes(for: sessionID)
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

    private static func formattedTranscript(from utterances: [Utterance]) -> String {
        let formatter = ISO8601DateFormatter()
        return utterances.chronologicallySorted.map { utterance in
            "[\(formatter.string(from: utterance.timestamp))] \(utterance.speaker == .you ? "You" : "Them"): \(utterance.text)"
        }
        .joined(separator: "\n")
    }
}
