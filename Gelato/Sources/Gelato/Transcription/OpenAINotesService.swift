import Foundation

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

enum OpenAINotesError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case emptyResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI API key to enable automatic notes."
        case .invalidResponse:
            return "OpenAI returned an unexpected response."
        case .emptyResponse:
            return "OpenAI returned an empty notes response."
        case .requestFailed(let message):
            return message
        }
    }
}

struct OpenAINotesService {
    private let session: URLSession

    struct GeneratedNotes: Sendable {
        let shortTitle: String
        let notes: String
    }

    private struct NotesPayload: Decodable {
        let short_title: String
        let notes: String
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateNotes(
        apiKey: String,
        sessionTitle: String,
        transcript: String
    ) async throws -> GeneratedNotes {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAINotesError.missingAPIKey
        }

        let systemPrompt = """
        You turn meeting transcripts into dense, highly detailed working notes and a short title.
        Write meaty notes with concrete facts, numbers, names, dates, decisions, open questions, risks, dependencies, and action items.
        Preserve uncertainty instead of inventing details.
        Use markdown headings and bullets.
        If a number, metric, date, or quote appears in the transcript, include it.
        Return plain text using exactly this format:
        <title>short title here</title>
        <notes>
        detailed notes here
        </notes>
        The title must be 5 to 6 words maximum.
        """

        let userPrompt = """
        Session title: \(sessionTitle)

        Create detailed meeting notes from this transcript. Include:
        - Executive summary
        - Detailed discussion notes
        - Numbers, metrics, timelines, dates, and named entities
        - Decisions made
        - Open questions / risks
        - Action items with owners when inferable
        - A short title of 5 to 6 words maximum

        Transcript:
        \(transcript)
        """

        let body = ChatCompletionRequest(
            model: "gpt-5.4-nano",
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.2
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAINotesError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw OpenAINotesError.requestFailed("OpenAI notes generation failed: \(message)")
        }

        let parsed = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = parsed.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw OpenAINotesError.emptyResponse
        }

        let (title, notes) = try parseTaggedResponse(content)
        guard !title.isEmpty, !notes.isEmpty else {
            throw OpenAINotesError.emptyResponse
        }

        return GeneratedNotes(shortTitle: title, notes: notes)
    }

    private func parseTaggedResponse(_ content: String) throws -> (String, String) {
        let cleaned = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let title = extractTag("title", from: cleaned),
              let notes = extractTag("notes", from: cleaned) else {
            throw OpenAINotesError.requestFailed("OpenAI notes payload did not include <title> and <notes> tags.")
        }

        return (
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func extractTag(_ tag: String, from text: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        guard let startRange = text.range(of: openTag),
              let endRange = text.range(of: closeTag) else {
            return nil
        }
        return String(text[startRange.upperBound..<endRange.lowerBound])
    }
}
