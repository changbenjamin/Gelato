import Foundation

/// Persisted as a .meta.json sidecar alongside each .jsonl session file.
struct SessionMetadata: Codable, Sendable, Equatable {
    var title: String
    var createdAt: Date
    var utteranceCount: Int
    var wordCount: Int
    var durationSeconds: TimeInterval?
}

/// Lightweight summary for the session list — does NOT load the full transcript.
struct SessionSummary: Identifiable, Hashable, Sendable {
    let id: String              // filename stem, e.g. "session_2024-03-17_14-30-00"
    let jsonlURL: URL
    let metadataURL: URL
    var metadata: SessionMetadata

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(metadata.title)
    }

    static func == (lhs: SessionSummary, rhs: SessionSummary) -> Bool {
        lhs.id == rhs.id && lhs.metadata == rhs.metadata
    }
}

/// Navigation route for the live session view.
struct LiveSessionRoute: Hashable {}

/// Helpers for reading/writing .meta.json sidecar files.
enum SessionMetadataIO {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Derive the .meta.json URL from a .jsonl URL.
    static func metadataURL(for jsonlURL: URL) -> URL {
        jsonlURL.deletingPathExtension().appendingPathExtension("meta.json")
    }

    /// Read metadata from a .meta.json file.
    static func read(from url: URL) throws -> SessionMetadata {
        let data = try Data(contentsOf: url)
        return try decoder.decode(SessionMetadata.self, from: data)
    }

    /// Write metadata to a .meta.json file.
    static func write(_ metadata: SessionMetadata, to url: URL) throws {
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    /// Generate a default title from a date — e.g. "Mar 17, 2:30 PM".
    static func defaultTitle(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mm a"
        return fmt.string(from: date)
    }

    /// Parse the session date from a filename stem like "session_2024-03-17_14-30-00".
    static func parseDate(from filenameStem: String) -> Date? {
        // Extract the date portion after "session_"
        let dateString = String(filenameStem.dropFirst("session_".count))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return fmt.date(from: dateString)
    }
}
