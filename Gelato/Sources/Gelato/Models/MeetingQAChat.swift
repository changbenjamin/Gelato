import Foundation

enum MeetingQARole: String, Codable, Sendable {
    case user
    case assistant
}

struct MeetingQAMessage: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let role: MeetingQARole
    let content: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: MeetingQARole,
        content: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

struct MeetingQAConversation: Codable, Sendable, Equatable {
    var messages: [MeetingQAMessage]

    static let empty = MeetingQAConversation(messages: [])
}
