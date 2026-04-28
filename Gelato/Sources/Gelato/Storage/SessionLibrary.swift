import Foundation

/// Manages the catalog of all recorded sessions on disk.
actor SessionLibrary {
    private static let generatedNotesHeading = "## AI-Generated Notes"
    private static let generatedNotesStartHeading = "### Executive Summary"
    private let sessionsDirectory: URL
    private let decoder = SessionAudioTiming.makeJSONDecoder()
    private let sessionRecordEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let meetingQAEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let meetingQADecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDirectory = appSupport.appendingPathComponent("Gelato/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    /// Load all sessions from disk, sorted newest-first.
    func loadSessions() -> [SessionSummary] {
        migrateLegacyFlatSessionsIfNeeded()

        let transcriptURLs = sessionTranscriptURLs().sorted { lhs, rhs in
            lhs.lastPathComponent > rhs.lastPathComponent
        }

        return transcriptURLs.compactMap { jsonlURL -> SessionSummary? in
            guard let sessionID = SessionPaths.sessionID(from: jsonlURL.lastPathComponent) else {
                return nil
            }

            let metaURL = SessionPaths.metadataURL(in: sessionsDirectory, sessionID: sessionID)
            guard let metadata = try? SessionMetadataIO.read(from: metaURL) else {
                return nil
            }

            return SessionSummary(
                id: sessionID,
                jsonlURL: jsonlURL,
                metadataURL: metaURL,
                metadata: metadata
            )
        }
    }

    private func sessionTranscriptURLs() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var transcriptURLsBySessionID: [String: URL] = [:]

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])

            if values?.isDirectory == true,
               let sessionID = SessionPaths.sessionID(from: entry.lastPathComponent) {
                let transcriptURL = SessionPaths.transcriptURL(in: sessionsDirectory, sessionID: sessionID)
                if fm.fileExists(atPath: transcriptURL.path) {
                    transcriptURLsBySessionID[sessionID] = transcriptURL
                }
                continue
            }

            guard entry.pathExtension == "jsonl",
                  let sessionID = SessionPaths.sessionID(from: entry.lastPathComponent),
                  transcriptURLsBySessionID[sessionID] == nil else {
                continue
            }

            transcriptURLsBySessionID[sessionID] = entry
        }

        return Array(transcriptURLsBySessionID.values)
    }

    func loadTranscript(for sessionID: String) -> [Utterance] {
        loadTranscript(from: transcriptURL(for: sessionID))
    }

    func loadOriginalTranscript(for sessionID: String) -> [Utterance] {
        loadTranscript(from: originalTranscriptURL(for: sessionID))
    }

    /// Load the full transcript from a JSONL file.
    private func loadTranscript(from jsonlURL: URL) -> [Utterance] {
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
        .chronologicallySorted
    }

    /// Update the title for a session.
    func updateTitle(for sessionID: String, newTitle: String) {
        let metaURL = metadataURL(for: sessionID)

        guard var metadata = try? SessionMetadataIO.read(from: metaURL) else { return }
        metadata.title = newTitle
        try? SessionMetadataIO.write(metadata, to: metaURL)
    }

    /// Create metadata sidecar for a newly completed session.
    func createMetadata(for jsonlURL: URL, title: String, utteranceCount: Int, wordCount: Int, duration: TimeInterval?) {
        let metaURL = SessionMetadataIO.metadataURL(for: jsonlURL)
        let stem = jsonlURL.deletingPathExtension().lastPathComponent
        let createdAt = SessionMetadataIO.parseDate(from: stem) ?? Date()
        try? FileManager.default.createDirectory(at: jsonlURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let metadata = SessionMetadata(
            title: title,
            createdAt: createdAt,
            utteranceCount: utteranceCount,
            wordCount: wordCount,
            durationSeconds: duration
        )
        try? SessionMetadataIO.write(metadata, to: metaURL)
    }

    // MARK: - Notes

    /// Load the notes text for a session (plain .notes.txt sidecar).
    func loadNotes(for sessionID: String) -> String {
        let notesURL = notesURL(for: sessionID)
        guard let data = try? Data(contentsOf: notesURL),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    func userNotes(for sessionID: String) -> String {
        let notes = loadNotes(for: sessionID)
        return splitNotes(notes).userNotes
    }

    /// Save notes text for a session.
    func saveNotes(for sessionID: String, text: String) {
        let notesURL = notesURL(for: sessionID)
        try? FileManager.default.createDirectory(at: notesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: notesURL, atomically: true, encoding: .utf8)
    }

    func loadMeetingQAConversation(for sessionID: String) -> MeetingQAConversation {
        let conversationURL = meetingQAURL(for: sessionID)
        guard let data = try? Data(contentsOf: conversationURL),
              let conversation = try? meetingQADecoder.decode(MeetingQAConversation.self, from: data) else {
            return .empty
        }
        return conversation
    }

    func saveMeetingQAConversation(for sessionID: String, conversation: MeetingQAConversation) {
        let conversationURL = meetingQAURL(for: sessionID)
        try? FileManager.default.createDirectory(at: conversationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? meetingQAEncoder.encode(conversation) else { return }
        try? data.write(to: conversationURL, options: .atomic)
    }

    func upsertGeneratedNotes(for sessionID: String, text: String) {
        let notesURL = notesURL(for: sessionID)
        let existing = loadNotes(for: sessionID)
        let userNotes = splitNotes(existing).userNotes
        let generatedBlock = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\(Self.generatedNotesHeading)\n\n", with: "")
            .replacingOccurrences(of: Self.generatedNotesHeading, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let cleanedUserNotes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let sections = [cleanedUserNotes.isEmpty ? nil : cleanedUserNotes, generatedBlock.isEmpty ? nil : generatedBlock]
            .compactMap { $0 }
        let finalText = sections.joined(separator: "\n\n")

        try? FileManager.default.createDirectory(at: notesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? finalText.trimmingCharacters(in: .whitespacesAndNewlines).write(
            to: notesURL,
            atomically: true,
            encoding: .utf8
        )
    }

    func replaceTranscript(for sessionID: String, utterances: [Utterance]) {
        let jsonlURL = transcriptURL(for: sessionID)
        writeTranscript(utterances, to: jsonlURL, logLabel: "TRANSCRIPT-WRITE")
    }

    func saveOriginalTranscriptIfMissing(for sessionID: String, utterances: [Utterance]) {
        let jsonlURL = originalTranscriptURL(for: sessionID)
        guard !FileManager.default.fileExists(atPath: jsonlURL.path) else { return }
        writeTranscript(utterances, to: jsonlURL, logLabel: "ORIGINAL-TRANSCRIPT-WRITE")
    }

    private func writeTranscript(_ utterances: [Utterance], to jsonlURL: URL, logLabel: String) {
        try? FileManager.default.createDirectory(at: jsonlURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let records = utterances.map {
            SessionRecord(speaker: $0.speaker, text: $0.text, timestamp: $0.timestamp)
        }

        do {
            let data = try records.reduce(into: Data()) { partialResult, record in
                partialResult.append(try sessionRecordEncoder.encode(record))
                partialResult.append(Data("\n".utf8))
            }
            try data.write(to: jsonlURL, options: .atomic)
        } catch {
            diagLog("[\(logLabel)-FAIL] \(jsonlURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func audioFiles(for sessionID: String) -> SessionAudioFiles? {
        let combinedMP4URL = combinedAudioOutputURL(for: sessionID)
        let combinedLegacyM4AURL = SessionPaths.legacyCombinedAudioURL(in: sessionsDirectory, sessionID: sessionID)
        let micURL = SessionPaths.micAudioURL(in: sessionsDirectory, sessionID: sessionID)
        let systemURL = SessionPaths.systemAudioURL(in: sessionsDirectory, sessionID: sessionID)

        let fm = FileManager.default
        let hasCombinedMP4 = fm.fileExists(atPath: combinedMP4URL.path)
        let hasCombinedLegacyM4A = fm.fileExists(atPath: combinedLegacyM4AURL.path)
        let hasMic = fm.fileExists(atPath: micURL.path)
        let hasSystem = fm.fileExists(atPath: systemURL.path)
        guard hasCombinedMP4 || hasCombinedLegacyM4A || hasMic || hasSystem else { return nil }

        return SessionAudioFiles(
            combinedURL: hasCombinedMP4 ? combinedMP4URL : (hasCombinedLegacyM4A ? combinedLegacyM4AURL : nil),
            micURL: hasMic ? micURL : nil,
            systemURL: hasSystem ? systemURL : nil
        )
    }

    func audioTiming(for sessionID: String) -> SessionAudioTiming? {
        let timingURL = SessionPaths.audioTimingURL(in: sessionsDirectory, sessionID: sessionID)
        guard let data = try? Data(contentsOf: timingURL) else { return nil }
        return try? decoder.decode(SessionAudioTiming.self, from: data)
    }

    func combinedAudioOutputURL(for sessionID: String) -> URL {
        SessionPaths.combinedAudioURL(in: sessionsDirectory, sessionID: sessionID)
    }

    /// Generate .meta.json for any existing .jsonl files that lack one (migration).
    /// Also re-generates metadata that is missing the wordCount field.
    func backfillMissingMetadata() {
        migrateLegacyFlatSessionsIfNeeded()
        let jsonlFiles = sessionTranscriptURLs()

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

    private func transcriptURL(for sessionID: String) -> URL {
        SessionPaths.transcriptURL(in: sessionsDirectory, sessionID: sessionID)
    }

    private func originalTranscriptURL(for sessionID: String) -> URL {
        SessionPaths.originalTranscriptURL(in: sessionsDirectory, sessionID: sessionID)
    }

    private func metadataURL(for sessionID: String) -> URL {
        SessionPaths.metadataURL(in: sessionsDirectory, sessionID: sessionID)
    }

    private func notesURL(for sessionID: String) -> URL {
        SessionPaths.notesURL(in: sessionsDirectory, sessionID: sessionID)
    }

    private func meetingQAURL(for sessionID: String) -> URL {
        SessionPaths.meetingQAURL(in: sessionsDirectory, sessionID: sessionID)
    }

    private func splitNotes(_ text: String) -> (userNotes: String, generatedNotes: String?) {
        let headingRange = text.range(of: Self.generatedNotesHeading)
            ?? text.range(of: Self.generatedNotesStartHeading)

        guard let headingRange else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        let userNotes = String(text[..<headingRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedNotes: String
        if text[headingRange].starts(with: Self.generatedNotesStartHeading) {
            generatedNotes = String(text[headingRange.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            generatedNotes = String(text[headingRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (userNotes, generatedNotes.isEmpty ? nil : generatedNotes)
    }

    private func migrateLegacyFlatSessionsIfNeeded() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true,
                  let sessionID = SessionPaths.sessionID(from: entry.lastPathComponent) else {
                continue
            }

            let sessionDirectory = SessionPaths.sessionDirectory(in: sessionsDirectory, sessionID: sessionID)
            let destinationURL = sessionDirectory.appendingPathComponent(entry.lastPathComponent)

            try? fm.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: destinationURL.path) else { continue }

            do {
                try fm.moveItem(at: entry, to: destinationURL)
                diagLog("[SESSION-MIGRATE] moved \(entry.lastPathComponent) to \(sessionID)/")
            } catch {
                diagLog("[SESSION-MIGRATE-FAIL] \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
