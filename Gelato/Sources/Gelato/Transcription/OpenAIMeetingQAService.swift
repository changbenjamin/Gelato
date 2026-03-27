import Foundation

private struct MeetingQAChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
}

private struct MeetingQAChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

enum OpenAIMeetingQAError: LocalizedError {
    case missingAPIKey
    case emptyTranscript
    case invalidResponse
    case emptyResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI API key to ask questions about meetings."
        case .emptyTranscript:
            return "This meeting does not have a transcript yet."
        case .invalidResponse:
            return "OpenAI returned an unexpected response."
        case .emptyResponse:
            return "OpenAI returned an empty answer."
        case .requestFailed(let message):
            return message
        }
    }
}

struct OpenAIMeetingQAService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func answerQuestion(
        apiKey: String,
        sessionTitle: String,
        transcript: String,
        history: [MeetingQAMessage],
        question: String
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIMeetingQAError.missingAPIKey
        }

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw OpenAIMeetingQAError.emptyTranscript
        }

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            throw OpenAIMeetingQAError.emptyResponse
        }

        let systemPrompt = """
        You answer questions about a meeting transcript.

        Rules:
        - Use the transcript as the source of truth.
        - Answer the user's question as clearly and simply as possible.
        - If the answer is not stated in the transcript, say that plainly.
        - If the user asks about ownership or timing, answer with the owner and deadline directly when they are present.
        - Keep the answer concise unless the user asks for more detail.
        - When you use a direct quote from the transcript, wrap only the quoted words in markdown bold, like **this exact quote**.
        - Do not use markdown other than bold direct quotes.
        - Do not invent facts, names, dates, or deadlines.
        """

        var messages: [MeetingQAChatCompletionRequest.Message] = [
            .init(role: "system", content: systemPrompt),
            .init(
                role: "user",
                content: """
                Meeting title: \(sessionTitle)

                Full transcript:
                \(trimmedTranscript)
                """
            )
        ]

        for message in history {
            messages.append(
                .init(
                    role: message.role == .user ? "user" : "assistant",
                    content: message.content
                )
            )
        }

        messages.append(
            .init(
                role: "user",
                content: "Find the answer to this question and answer as clearly and simply as possible: \(trimmedQuestion)"
            )
        )

        let body = MeetingQAChatCompletionRequest(
            model: "gpt-5.4-nano",
            messages: messages,
            temperature: 0.3
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIMeetingQAError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw OpenAIMeetingQAError.requestFailed("OpenAI meeting Q&A failed: \(message)")
        }

        let parsed = try JSONDecoder().decode(MeetingQAChatCompletionResponse.self, from: data)
        guard let content = parsed.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw OpenAIMeetingQAError.emptyResponse
        }

        return content
    }
}
