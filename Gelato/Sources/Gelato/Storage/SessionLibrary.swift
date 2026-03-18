import Foundation

/// Manages the catalog of all recorded sessions on disk.
actor SessionLibrary {
    private let sessionsDirectory: URL
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDirectory = appSupport.appendingPathComponent("Gelato/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    /// Load all sessions from disk, sorted newest-first.
    func loadSessions() -> [SessionSummary] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }

        return jsonlFiles.compactMap { jsonlURL -> SessionSummary? in
            let stem = jsonlURL.deletingPathExtension().lastPathComponent
            let metaURL = SessionMetadataIO.metadataURL(for: jsonlURL)

            guard let metadata = try? SessionMetadataIO.read(from: metaURL) else {
                return nil
            }

            return SessionSummary(
                id: stem,
                jsonlURL: jsonlURL,
                metadataURL: metaURL,
                metadata: metadata
            )
        }
    }

    /// Load the full transcript from a JSONL file.
    func loadTranscript(for sessionID: String) -> [Utterance] {
        let jsonlURL = sessionsDirectory.appendingPathComponent("\(sessionID).jsonl")
        guard let data = try? Data(contentsOf: jsonlURL) else { return [] }
        guard let content = String(data: data, encoding: .utf8) else { return [] }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.compactMap { line -> Utterance? in
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(SessionRecord.self, from: lineData) else {
                return nil
            }
            return Utterance(text: record.text, speaker: record.speaker, timestamp: record.timestamp)
        }
    }

    /// Update the title for a session.
    func updateTitle(for sessionID: String, newTitle: String) {
        let jsonlURL = sessionsDirectory.appendingPathComponent("\(sessionID).jsonl")
        let metaURL = SessionMetadataIO.metadataURL(for: jsonlURL)

        guard var metadata = try? SessionMetadataIO.read(from: metaURL) else { return }
        metadata.title = newTitle
        try? SessionMetadataIO.write(metadata, to: metaURL)
    }

    /// Create metadata sidecar for a newly completed session.
    func createMetadata(for jsonlURL: URL, title: String, utteranceCount: Int, wordCount: Int, duration: TimeInterval?) {
        let metaURL = SessionMetadataIO.metadataURL(for: jsonlURL)
        let stem = jsonlURL.deletingPathExtension().lastPathComponent
        let createdAt = SessionMetadataIO.parseDate(from: stem) ?? Date()

        let metadata = SessionMetadata(
            title: title,
            createdAt: createdAt,
            utteranceCount: utteranceCount,
            wordCount: wordCount,
            durationSeconds: duration
        )
        try? SessionMetadataIO.write(metadata, to: metaURL)
    }

    /// Generate .meta.json for any existing .jsonl files that lack one (migration).
    /// Also re-generates metadata that is missing the wordCount field.
    func backfillMissingMetadata() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }

        for jsonlURL in jsonlFiles {
            let metaURL = SessionMetadataIO.metadataURL(for: jsonlURL)

            // Check if metadata exists and has wordCount > 0
            if let existing = try? SessionMetadataIO.read(from: metaURL), existing.wordCount > 0 {
                continue
            }

            let stem = jsonlURL.deletingPathExtension().lastPathComponent
            let createdAt = SessionMetadataIO.parseDate(from: stem) ?? Date()

            // Parse all records
            var lineCount = 0
            var totalWords = 0
            var duration: TimeInterval? = nil
            var firstTimestamp: Date?
            var lastTimestamp: Date?

            if let data = try? Data(contentsOf: jsonlURL),
               let content = String(data: data, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
                lineCount = lines.count

                for line in lines {
                    if let lineData = line.data(using: .utf8),
                       let record = try? decoder.decode(SessionRecord.self, from: lineData) {
                        totalWords += record.text.split(separator: " ").count
                        if firstTimestamp == nil { firstTimestamp = record.timestamp }
                        lastTimestamp = record.timestamp
                    }
                }

                if let first = firstTimestamp, let last = lastTimestamp {
                    duration = last.timeIntervalSince(first)
                }
            }

            // Preserve existing title if metadata already exists
            let title: String
            if let existing = try? SessionMetadataIO.read(from: metaURL) {
                title = existing.title
            } else {
                title = SessionMetadataIO.defaultTitle(for: createdAt)
            }

            let metadata = SessionMetadata(
                title: title,
                createdAt: createdAt,
                utteranceCount: lineCount,
                wordCount: totalWords,
                durationSeconds: duration
            )
            try? SessionMetadataIO.write(metadata, to: metaURL)
        }
    }
}
