import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case parakeet
    case scribeV2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet:
            return "Parakeet (Local)"
        case .scribeV2:
            return "ElevenLabs Scribe v2"
        }
    }

    var description: String {
        switch self {
        case .parakeet:
            return "Live local transcription with Parakeet-TDT v2."
        case .scribeV2:
            return "Show a live local transcript while recording, then replace the saved transcript with ElevenLabs Scribe v2."
        }
    }
}
