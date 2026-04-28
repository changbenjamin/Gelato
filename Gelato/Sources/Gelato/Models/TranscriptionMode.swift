import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case parakeet
    case openAICleanup

    static let legacyElevenLabsRawValue = "scribeV2"
    static let legacyOpenAIDiarizeRawValue = "openAIDiarize"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet:
            return "Parakeet (Local)"
        case .openAICleanup:
            return "Parakeet + OpenAI Cleanup"
        }
    }

    var description: String {
        switch self {
        case .parakeet:
            return "Live local transcription with Parakeet-TDT v2."
        case .openAICleanup:
            return "Use Parakeet-TDT v2 for transcription, then send the transcript text to OpenAI for cleanup. No audio is sent for diarization."
        }
    }
}
