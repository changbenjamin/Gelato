import Foundation

private struct TranscriptCleanupChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

private struct TranscriptCleanupChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

enum OpenAITranscriptCleanupError: LocalizedError {
    case missingAPIKey
    case emptyTranscript
    case invalidResponse
    case emptyResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI API key to enable transcript cleanup."
        case .emptyTranscript:
            return "This session does not have a Parakeet transcript to clean."
        case .invalidResponse:
            return "OpenAI returned an unexpected transcript cleanup response."
        case .emptyResponse:
            return "OpenAI returned an empty cleaned transcript."
        case .requestFailed(let message):
            return message
        }
    }
}

struct OpenAITranscriptCleanupService {
    private static let model = "gpt-5-mini-2025-08-07"
    private static let requestTimeout: TimeInterval = 300
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession
    }

    func cleanTranscript(
        apiKey: String,
        utterances: [Utterance]
    ) async throws -> [Utterance] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAITranscriptCleanupError.missingAPIKey
        }

        let sourceTurns = Self.mergeConsecutiveTurns(utterances.chronologicallySorted)
        guard !sourceTurns.isEmpty else {
            throw OpenAITranscriptCleanupError.emptyTranscript
        }

        let rawTranscript = sourceTurns
            .map { "\($0.speaker == .you ? "You" : "Them"): \($0.text)" }
            .joined(separator: "\n")

        let systemPrompt = """
        You are a professional transcript editor. Your job is to take a raw ASR transcript and produce a clean, polished version that reads like a professionally published transcript.
        Preserve the speaker's meaning and every meaningful spoken idea. Do not summarize, shorten, editorialize, or change what the speaker was trying to say. This is not a raw-ASR preservation task: when the recognizer produced the wrong words, spellings, capitalization, or malformed phrases, correct them to the obvious intended wording.
        Remove filler words and verbal stumbles: "um," "uh," "like" (when used as filler), "you know" (when used as filler), false starts, and repeated words or phrases where the speaker restarted a sentence. Use your judgment — if "like" or "you know" is part of the actual meaning of the sentence, keep it.
        Aggressively correct obvious speech-recognition errors when the intended words are clear from context. This includes homophones, misheard short words, broken idioms, malformed grammar caused by ASR, book titles, character names, faction names, place names, product names, company names, people names, technical terms, and common proper nouns. Use surrounding context to normalize repeated variants of the same term to the correct spelling and capitalization. If a term appears multiple ways, choose the canonical form and use it consistently.
        You are expected to know and correct widely known domain terms. For example, if the transcript says "Zero two one by Peter Teal" or "Zero to zero to one by Peter Teal" and context clearly indicates the book, correct it to "Zero to One by Peter Thiel." If the transcript is discussing Dune and says "Doom" for the planet/title, correct it to "Dune"; "House Arconin" to "House Harkonnen"; "Beni Jesseret" or "Ben Jessereth" to "Bene Gesserit"; "our racket" or "a racket" to "Arrakis"; "Dom Jabar" to "gom jabbar"; "Shai Halud" to "Shai-Hulud"; "men taug" to "Mentat"; and "ecopography" to "topography" if that is the intended word. In a sleep study context, correct "Pulling the old-niter" to "pulling an all-nighter", "keep them away" to "keep them awake", "Them try and learn" to "then try and learn", and "brain action activity" to "brain activity" when context supports it.
        If a phrase is garbled but the intended common phrase is obvious, replace the garbled words with the intended phrase. If the intended wording is not clear, leave it as close to the original as possible rather than inventing.
        When the same speaker appears across multiple consecutive short lines, you may merge them when they are part of the same thought. When a single speaker has a long uninterrupted monologue, split it into natural readable paragraphs at topic shifts, scene changes, or major idea boundaries. Each paragraph must keep the same speaker label.
        Fix capitalization, punctuation, spelling, and grammar formatting so sentences read naturally. Add commas, periods, question marks, and other punctuation where appropriate. Capitalize the start of sentences and all proper nouns. Correct obvious singular/plural and tense errors introduced by transcription, such as "a six years book saga" to "a six-book saga", when the intended phrase is clear.
        Never use ellipses, brackets, editorial notes, or any notation that wasn't in the original speech. Do not add timestamps unless they were in the original.

        Output requirements:
        - Return only the cleaned transcript.
        - Before returning, do a final correction pass for proper nouns, capitalization, misspellings, malformed common phrases, and repeated inconsistent spellings.
        - Use one line per natural transcript paragraph.
        - Start every line with exactly "You: " or "Them: ".
        - If one speaker continues across multiple paragraphs, repeat the same speaker label at the start of each paragraph.
        - Prefer multiple readable paragraphs over one giant text block when a turn runs longer than about 5 sentences.
        - Preserve the original speaker labels. Do not invent names.
        - Do not use markdown, bullets, code fences, timestamps, comments, or explanations.
        """

        let userPrompt = """
        Clean this Parakeet transcript:

        \(rawTranscript)
        """

        let body = TranscriptCleanupChatCompletionRequest(
            model: Self.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ]
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptCleanupError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw OpenAITranscriptCleanupError.requestFailed("OpenAI transcript cleanup failed: \(message)")
        }

        let parsed = try JSONDecoder().decode(TranscriptCleanupChatCompletionResponse.self, from: data)
        guard let content = parsed.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw OpenAITranscriptCleanupError.emptyResponse
        }

        let cleanedTurns = Self.parseCleanedTranscript(content)
        guard !cleanedTurns.isEmpty else {
            throw OpenAITranscriptCleanupError.emptyResponse
        }

        return Self.attachTimestamps(cleanedTurns, toSourceTurns: sourceTurns)
    }

    private struct SourceTurn {
        let speaker: Speaker
        var text: String
        let timestamp: Date
    }

    private static func mergeConsecutiveTurns(_ utterances: [Utterance]) -> [SourceTurn] {
        utterances.reduce(into: [SourceTurn]()) { turns, utterance in
            let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            if let last = turns.last, last.speaker == utterance.speaker {
                turns[turns.count - 1].text = "\(last.text) \(text)"
            } else {
                turns.append(SourceTurn(speaker: utterance.speaker, text: text, timestamp: utterance.timestamp))
            }
        }
    }

    private static func parseCleanedTranscript(_ content: String) -> [SourceTurn] {
        var turns: [SourceTurn] = []
        let cleaned = content
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for rawLine in cleaned.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("- ") {
                line.removeFirst(2)
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            line = line.replacingOccurrences(of: "**", with: "")

            if let parsed = parseSpeakerLine(line) {
                turns.append(SourceTurn(speaker: parsed.speaker, text: parsed.text, timestamp: Date()))
            } else if !turns.isEmpty {
                turns[turns.count - 1].text += "\n\n\(line)"
            }
        }

        return turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func parseSpeakerLine(_ line: String) -> (speaker: Speaker, text: String)? {
        let lowered = line.lowercased()
        let prefixes: [(String, Speaker)] = [
            ("you:", .you),
            ("them:", .them)
        ]

        for (prefix, speaker) in prefixes where lowered.hasPrefix(prefix) {
            let start = line.index(line.startIndex, offsetBy: prefix.count)
            let text = String(line[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (speaker, text)
        }

        return nil
    }

    private static func attachTimestamps(
        _ cleanedTurns: [SourceTurn],
        toSourceTurns sourceTurns: [SourceTurn]
    ) -> [Utterance] {
        var searchStart = sourceTurns.startIndex
        var fallbackTimestamp = sourceTurns.first?.timestamp ?? Date()

        return cleanedTurns.map { cleanedTurn in
            let matchIndex = sourceTurns[searchStart...].firstIndex {
                $0.speaker == cleanedTurn.speaker
            }
            let timestamp: Date
            if let matchIndex {
                timestamp = sourceTurns[matchIndex].timestamp
                searchStart = sourceTurns.index(after: matchIndex)
                fallbackTimestamp = timestamp
            } else {
                fallbackTimestamp = fallbackTimestamp.addingTimeInterval(1)
                timestamp = fallbackTimestamp
            }

            return Utterance(
                text: cleanedTurn.text.trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: cleanedTurn.speaker,
                timestamp: timestamp
            )
        }
    }
}
