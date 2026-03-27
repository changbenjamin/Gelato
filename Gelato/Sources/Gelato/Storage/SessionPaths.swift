import Foundation

enum SessionPaths {
    private static let sessionIDLength = "session_2026-03-26_21-50-57".count

    static func sessionID(from filename: String) -> String? {
        guard filename.count >= sessionIDLength else { return nil }

        let candidate = String(filename.prefix(sessionIDLength))
        guard SessionMetadataIO.parseDate(from: candidate) != nil else { return nil }
        return candidate
    }

    static func sessionDirectory(in sessionsDirectory: URL, sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
    }

    static func transcriptURL(in sessionsDirectory: URL, sessionID: String) -> URL {
        sessionDirectory(in: sessionsDirectory, sessionID: sessionID)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    static func metadataURL(in sessionsDirectory: URL, sessionID: String) -> URL {
        SessionMetadataIO.metadataURL(for: transcriptURL(in: sessionsDirectory, sessionID: sessionID))
    }

    static func notesURL(in sessionsDirectory: URL, sessionID: String) -> URL {
        sessionDirectory(in: sessionsDirectory, sessionID: sessionID)
            .appendingPathComponent("\(sessionID).notes.txt")
    }

    static func meetingQAURL(in sessionsDirectory: URL, sessionID: String) -> URL {
        sessionDirectory(in: sessionsDirectory, sessionID: sessionID)
            .appendingPathComponent("\(sessionID).qa-chat.json")
    }

    static func audioTimingURL(in sessionsDirectory: URL, sessionID: String) -> URL {
        sessionDirectory(in: sessionsDirectory, sessionID: sessionID)
            .appendingPathComponent("\(sessionID).audio-timing.json")
    }

    static func combinedAudioURL(in sessionsDirectory: URL, sessionID: String) -> URL {
        sessionDirectory(in: sessionsDirectory, sessionID: sessionID)
            .appendingPathComponent("\(sessionID)_combined.mp4")
    }

    static func legacyCombinedAudioURL(in sessionsDirectory: URL, sessionID: String) -> URL {
        sessionDirectory(in: sessionsDirectory, sessionID: sessionID)
            .appendingPathComponent("\(sessionID)_combined.m4a")
    }

    static func micAudioURL(in sessionsDirectory: URL, sessionID: String) -> URL {
        sessionDirectory(in: sessionsDirectory, sessionID: sessionID)
            .appendingPathComponent("\(sessionID)_you.caf")
    }

    static func systemAudioURL(in sessionsDirectory: URL, sessionID: String) -> URL {
        sessionDirectory(in: sessionsDirectory, sessionID: sessionID)
            .appendingPathComponent("\(sessionID)_them.caf")
    }
}
