import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case parakeet
    case openAIDiarize

    static let legacyElevenLabsRawValue = "scribeV2"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet:
            return "Parakeet (Local)"
        case .openAIDiarize:
            return "OpenAI Diarized Transcript"
        }
    }

    var description: String {
        switch self {
        case .parakeet:
            return "Live local transcription with Parakeet-TDT v2."
        case .openAIDiarize:
            return "Show a live local transcript while recording, then replace the saved transcript with OpenAI gpt-4o-transcribe-diarize using two-speaker diarization."
        }
    }
}
