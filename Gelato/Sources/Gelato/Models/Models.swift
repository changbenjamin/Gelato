import Foundation

enum Speaker: String, Codable, Sendable {
    case you
    case them
}

struct Utterance: Identifiable, Codable, Sendable {
    let id: UUID
    let text: String
    let speaker: Speaker
    let timestamp: Date

    init(text: String, speaker: Speaker, timestamp: Date = .now) {
        self.id = UUID()
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
    }
}

extension Array where Element == Utterance {
    var chronologicallySorted: [Utterance] {
        sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

// MARK: - Session Record

/// Codable record for JSONL session persistence
struct SessionRecord: Codable, Sendable {
    let speaker: Speaker
    let text: String
    let timestamp: Date
}
