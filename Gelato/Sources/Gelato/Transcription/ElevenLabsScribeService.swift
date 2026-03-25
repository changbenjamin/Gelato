import Foundation

struct ScribeWord: Decodable, Sendable {
    let text: String
    let start: Double?
    let end: Double?
    let type: String?
}

struct ScribeTranscriptResponse: Decodable, Sendable {
    let text: String
    let words: [ScribeWord]?
}

enum ElevenLabsScribeError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an ElevenLabs API key in Settings to use Scribe v2."
        case .invalidResponse:
            return "ElevenLabs returned an unexpected response."
        case .requestFailed(let message):
            return message
        }
    }
}

struct ElevenLabsScribeService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(audioURL: URL, apiKey: String) async throws -> ScribeTranscriptResponse {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ElevenLabsScribeError.missingAPIKey
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        request.httpBody = makeBody(audioData: audioData, filename: audioURL.lastPathComponent, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsScribeError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw ElevenLabsScribeError.requestFailed("ElevenLabs Scribe v2 failed: \(message)")
        }

        do {
            return try JSONDecoder().decode(ScribeTranscriptResponse.self, from: data)
        } catch {
            throw ElevenLabsScribeError.requestFailed("Failed to decode ElevenLabs response: \(error.localizedDescription)")
        }
    }

    private func makeBody(audioData: Data, filename: String, boundary: String) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n")
        append("scribe_v2\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"diarize\"\r\n\r\n")
        append("false\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"tag_audio_events\"\r\n\r\n")
        append("true\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: audio/x-caf\r\n\r\n")
        body.append(audioData)
        append("\r\n")

        append("--\(boundary)--\r\n")
        return body
    }
}
