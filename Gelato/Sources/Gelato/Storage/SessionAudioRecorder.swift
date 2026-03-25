import AVFoundation
import Foundation

final class SessionAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var micWriter: PCMFileWriter?
    private var systemWriter: PCMFileWriter?

    func start(sessionID: String, in directory: URL) {
        lock.lock()
        defer { lock.unlock() }

        let micURL = directory.appendingPathComponent("\(sessionID)_you.caf")
        let systemURL = directory.appendingPathComponent("\(sessionID)_them.caf")

        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)

        micWriter = PCMFileWriter(url: micURL)
        systemWriter = PCMFileWriter(url: systemURL)
    }

    func appendMicBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let writer = micWriter
        lock.unlock()
        writer?.append(buffer)
    }

    func appendSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let writer = systemWriter
        lock.unlock()
        writer?.append(buffer)
    }

    func finish() {
        lock.lock()
        micWriter = nil
        systemWriter = nil
        lock.unlock()
    }
}

private final class PCMFileWriter {
    private let lock = NSLock()
    private let url: URL
    private var audioFile: AVAudioFile?

    init(url: URL) {
        self.url = url
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(
                    forWriting: url,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            }
            try audioFile?.write(from: buffer)
        } catch {
            diagLog("[AUDIO-WRITE-FAIL] \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
