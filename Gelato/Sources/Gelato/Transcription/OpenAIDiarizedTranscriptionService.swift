import Foundation

struct OpenAIDiarizedSegment: Decodable, Sendable {
    let speaker: String
    let start: Double
    let end: Double
    let text: String
}

struct OpenAIDiarizedTranscriptResponse: Decodable, Sendable {
    let text: String
    let segments: [OpenAIDiarizedSegment]?
}

struct OpenAIKnownSpeakerReference: Sendable {
    let name: String
    let dataURL: String
}

enum OpenAIDiarizedTranscriptionError: LocalizedError {
    case missingAPIKey
    case audioTooLarge(fileSizeBytes: Int64)
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI API key to enable diarized transcript replacement."
        case .audioTooLarge(let fileSizeBytes):
            return "The mixed recording is \(ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)), which exceeds OpenAI's 25 MB transcription upload limit."
        case .invalidResponse:
            return "OpenAI returned an unexpected transcription response."
        case .requestFailed(let message):
            return message
        }
    }
}

struct OpenAIDiarizedTranscriptionService {
    private static let uploadLimitBytes: Int64 = 25 * 1024 * 1024

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        audioURL: URL,
        apiKey: String,
        knownSpeakers: [OpenAIKnownSpeakerReference]
    ) async throws -> OpenAIDiarizedTranscriptResponse {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIDiarizedTranscriptionError.missingAPIKey
        }

        let fileValues = try audioURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = fileValues.fileSize.map(Int64.init),
           fileSize > Self.uploadLimitBytes {
            throw OpenAIDiarizedTranscriptionError.audioTooLarge(fileSizeBytes: fileSize)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        request.httpBody = makeBody(
            audioData: audioData,
            filename: audioURL.lastPathComponent,
            mimeType: mimeType(for: audioURL),
            knownSpeakers: knownSpeakers,
            boundary: boundary
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIDiarizedTranscriptionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw OpenAIDiarizedTranscriptionError.requestFailed("OpenAI diarized transcription failed: \(message)")
        }

        do {
            return try JSONDecoder().decode(OpenAIDiarizedTranscriptResponse.self, from: data)
        } catch {
            throw OpenAIDiarizedTranscriptionError.requestFailed("Failed to decode OpenAI diarized transcript: \(error.localizedDescription)")
        }
    }

    private func makeBody(
        audioData: Data,
        filename: String,
        mimeType: String,
        knownSpeakers: [OpenAIKnownSpeakerReference],
        boundary: String
    ) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }

        appendField(name: "model", value: "gpt-4o-transcribe-diarize")
        appendField(name: "response_format", value: "diarized_json")
        appendField(name: "chunking_strategy", value: "auto")

        for speaker in knownSpeakers {
            appendField(name: "known_speaker_names[]", value: speaker.name)
            appendField(name: "known_speaker_references[]", value: speaker.dataURL)
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        append("\r\n")

        append("--\(boundary)--\r\n")
        return body
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4":
            return "audio/mp4"
        case "mp3", "mpeg", "mpga":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "webm":
            return "audio/webm"
        default:
            return "application/octet-stream"
        }
    }
}
