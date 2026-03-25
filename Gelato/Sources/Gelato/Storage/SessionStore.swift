import Foundation

/// Persists session transcripts as JSONL files.
actor SessionStore {
    private let sessionsDirectory: URL
    private var currentFile: URL?
    private var fileHandle: FileHandle?
    private let encoder = JSONEncoder()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDirectory = appSupport.appendingPathComponent("Gelato/sessions", isDirectory: true)

        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        encoder.dateEncodingStrategy = .iso8601
    }

    func startSession() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "session_\(formatter.string(from: Date())).jsonl"
        currentFile = sessionsDirectory.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: currentFile!.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: currentFile!)
    }

    func appendRecord(_ record: SessionRecord) {
        guard let fileHandle else { return }

        do {
            let data = try encoder.encode(record)
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.write("\n".data(using: .utf8)!)
        } catch {
            print("SessionStore: failed to write record: \(error)")
        }
    }

    func replaceRecords(_ records: [SessionRecord]) {
        guard let currentFile else { return }

        do {
            let data = try records.reduce(into: Data()) { partialResult, record in
                partialResult.append(try encoder.encode(record))
                partialResult.append(Data("\n".utf8))
            }
            try data.write(to: currentFile, options: .atomic)
            fileHandle = try? FileHandle(forWritingTo: currentFile)
        } catch {
            print("SessionStore: failed to replace records: \(error)")
        }
    }

    func endSession() {
        try? fileHandle?.close()
        fileHandle = nil
        currentFile = nil
    }

    /// URL of the current session file (nil if no session is active).
    var currentSessionURL: URL? { currentFile }

    var sessionsDirectoryURL: URL { sessionsDirectory }
}
