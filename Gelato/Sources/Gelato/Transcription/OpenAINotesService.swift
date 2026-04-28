import Foundation

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
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
    private static let model = "gpt-5-mini-2025-08-07"
    private static let requestTimeout: TimeInterval = 300
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    struct GeneratedNotes: Sendable {
        let shortTitle: String
        let notes: String
    }

    init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession
    }

    func generateNotes(
        apiKey: String,
        sessionTitle: String,
        userNotes: String,
        transcript: String
    ) async throws -> GeneratedNotes {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAINotesError.missingAPIKey
        }

        let systemPrompt = """
        You are a world-class meeting note-taker. Your job is to produce clear, thorough, and trustworthy notes from a meeting transcript combined with any notes the user typed during the meeting.

        ## Core principles

        1. Accuracy over completeness. Never invent, infer, or hallucinate details. If something was unclear, partially stated, or ambiguous in the transcript, say so explicitly — use language like "mentioned but not specified," "[transcription unclear but sounded like X]," "exact figure not stated," or "to be confirmed." A gap in the notes is always better than a fabricated detail.

        2. Concrete over vague. Whenever a name, number, date, dollar amount, metric, deadline, percentage, or proper noun was spoken, include it. Prefer "Q3 revenue was $4.2M, up 18% YoY" over "revenue was up." Prefer "Lisa will send the revised deck by Thursday" over "someone will follow up."

        3. The user's notes are a priority signal. The user typed notes during the meeting to mark what they found important. Treat these as a guide for emphasis — the topics they noted should receive more detail and prominence in the final output. Weave the user's notes and the transcript together; do not treat them as separate sections.

        4. Preserve nuance, disagreement, and open questions. Meetings are messy. If two people disagreed, capture both positions and who held them. If a question was raised but not answered, flag it as an open question. If a decision was tentative or conditional, say so. Do not flatten complexity into false consensus.

        5. Write for someone who wasn't in the room. The notes should allow a colleague who missed the meeting to understand what happened, what was decided, what's still open, and what they need to do — without needing to ask follow-up questions.

        6. Treat speaker labels as roles, not names. The transcript may use labels like "You" and "Them" to distinguish the user from the other participant. These are not literal names and should never be written as quoted character names. If no real name is known, refer to the speakers naturally as "you" and "they," or "the other caller/participant" where needed for clarity. Never write phrases like "You's statement" or "Them's response"; write "your statement" or "the other participant's response."

        ## Output structure

        Use the following structure. Omit any section that has no relevant content — do not include empty sections or placeholder text.

        Start the notes directly with this heading. Do not add a wrapper heading like "## AI-Generated Notes".

        ### Executive Summary
        2–4 sentences. What was this meeting about, what were the most important outcomes, and is anything time-sensitive? This should be useful on its own for someone skimming.

        The main body. Create new headers by topic, not by chronology — group related discussion threads even if they were spread across the meeting. Use short descriptive headings for each topic cluster.

        Within each topic:
        - Lead with the substance: what was said, proposed, or debated.
        - Attribute claims, opinions, and commitments to specific people by name.
        - Include specific numbers, dates, examples, and quotes when they add value.
        - Note where there was disagreement or uncertainty.
        - Keep it dense but readable — favor concise paragraphs and short bullets over walls of text.

        ### Action Items (ONLY ADD THIS SECTION IF RELEVANT/NECESSARY)
        Bulleted list. Each entry includes: what needs to be done, who owns it, and the deadline if one was stated. If no deadline was given, write "[no deadline stated]." If the owner is ambiguous, write "[owner TBD]."

        ## Formatting rules

        - Use **bold** very sparingly. Only bold a small number of genuinely important words or phrases that need to pop for a skimmer. Most paragraphs and bullets should contain no bolding at all.
        - Do not bold speaker labels like "You" or "Them", and do not write them as quoted names.
        - Use exact quotes sparingly — only when the specific wording matters (e.g., a commitment, a contentious statement, a memorable framing).
        - Keep quoted material in quotation marks. Quoted text does not need to be bold unless the wording is exceptionally important.
        - Do not editorialize or add your own opinions.
        - Do not pad with filler language. Every sentence should carry information.
        - If the audio quality was poor or a section of transcript is garbled, note it: "[inaudible/unclear ~2 min mark]" rather than guessing.
        - Refer to participants by their first name after the first full-name mention, or matching how they were addressed in the meeting. If no name is known, use natural role language like "you" and "they" instead of invented names.
        - Headings must be clean, human-readable topic names. Do not use parenthetical keyword dumps in headings, such as "(socialism / 1979 / Soviet Union / California)". Avoid parentheses in headings unless they are part of an actual proper noun or title.
        - Do not make headings possessive from transcript role labels. Use "Your Political Statement" instead of "You's Political Statement"; use "Other Participant's Point" instead of "Them's Point".

        Also produce a short descriptive title, 5 to 6 words maximum.
        Do not include any date, day of week, or time in the title.

        Return plain text using exactly this format:
        <title>short title here</title>
        <notes>
        detailed notes here
        </notes>
        """

        let userPrompt = """
        Here are my meeting notes and the transcript. Please produce detailed, structured meeting notes following your instructions.

        Meeting context:
        - Meeting title: \(sessionTitle)
        - Transcript speaker labels: "You" means the user. "Them" means the other caller or participant. These are role labels, not names.

        User notes typed during the meeting:
        \(userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "[none]" : userNotes)

        Transcript:
        \(transcript)
        """

        let body = ChatCompletionRequest(
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
