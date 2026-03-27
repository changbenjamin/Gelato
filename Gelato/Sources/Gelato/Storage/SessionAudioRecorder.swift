@preconcurrency import AVFoundation
import Foundation

final class SessionAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.gelato.session-audio-recorder")
    private static let drainTimeoutSeconds: TimeInterval = 5
    private let encoder = SessionAudioTiming.makeJSONEncoder()
    private var micWriter: PCMFileWriter?
    private var systemWriter: PCMFileWriter?
    private var timingURL: URL?
    private var micFirstBufferAt: Date?
    private var systemFirstBufferAt: Date?
    private var micChunks: [SessionAudioChunk] = []
    private var systemChunks: [SessionAudioChunk] = []

    func start(sessionID: String, in directory: URL) {
        lock.lock()
        defer { lock.unlock() }

        let micURL = directory.appendingPathComponent("\(sessionID)_you.caf")
        let systemURL = directory.appendingPathComponent("\(sessionID)_them.caf")
        let timingURL = directory.appendingPathComponent("\(sessionID).audio-timing.json")

        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)
        try? FileManager.default.removeItem(at: timingURL)

        micWriter = PCMFileWriter(url: micURL)
        systemWriter = PCMFileWriter(url: systemURL)
        self.timingURL = timingURL
        micFirstBufferAt = nil
        systemFirstBufferAt = nil
        micChunks = []
        systemChunks = []
    }

    func appendMicBuffer(_ capturedBuffer: CapturedAudioBuffer) {
        lock.lock()
        let writer = micWriter
        if micFirstBufferAt == nil {
            micFirstBufferAt = capturedBuffer.capturedAt
        }
        micChunks.append(
            SessionAudioChunk(
                capturedAt: capturedBuffer.capturedAt,
                frameCount: Int(capturedBuffer.buffer.frameLength)
            )
        )
        lock.unlock()
        guard let writer, let copy = capturedBuffer.buffer.ownedCopy() else { return }
        writeQueue.async {
            writer.append(copy)
        }
    }

    func appendSystemBuffer(_ capturedBuffer: CapturedAudioBuffer) {
        lock.lock()
        let writer = systemWriter
        if systemFirstBufferAt == nil {
            systemFirstBufferAt = capturedBuffer.capturedAt
        }
        systemChunks.append(
            SessionAudioChunk(
                capturedAt: capturedBuffer.capturedAt,
                frameCount: Int(capturedBuffer.buffer.frameLength)
            )
        )
        lock.unlock()
        guard let writer, let copy = capturedBuffer.buffer.ownedCopy() else { return }
        writeQueue.async {
            writer.append(copy)
        }
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        let micWriter = self.micWriter
        let systemWriter = self.systemWriter
        let timingURL = self.timingURL
        let timing = SessionAudioTiming(
            micFirstBufferAt: micFirstBufferAt,
            systemFirstBufferAt: systemFirstBufferAt,
            micChunks: micChunks,
            systemChunks: systemChunks
        )
        self.micWriter = nil
        self.systemWriter = nil
        self.timingURL = nil
        self.micFirstBufferAt = nil
        self.systemFirstBufferAt = nil
        self.micChunks = []
        self.systemChunks = []
        lock.unlock()

        diagLog(
            "[AUDIO-RECORDER-FINISH] micChunks=\(timing.micChunks?.count ?? 0) " +
            "systemChunks=\(timing.systemChunks?.count ?? 0)"
        )

        let drainSignal = DispatchSemaphore(value: 0)
        writeQueue.async {
            micWriter?.finish()
            systemWriter?.finish()
            drainSignal.signal()
        }

        let drained = drainSignal.wait(timeout: .now() + Self.drainTimeoutSeconds) == .success
        if drained {
            diagLog("[AUDIO-RECORDER-FINISH] drained queued writes")
        } else {
            diagLog("[AUDIO-RECORDER-FINISH-TIMEOUT] continuing after \(Self.drainTimeoutSeconds)s")
        }

        guard let timingURL else { return drained }
        guard timing.micFirstBufferAt != nil || timing.systemFirstBufferAt != nil else { return drained }

        if let data = try? encoder.encode(timing) {
            try? data.write(to: timingURL, options: .atomic)
        }
        return drained
    }
}

private final class PCMFileWriter: @unchecked Sendable {
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

    func finish() {
        lock.lock()
        audioFile = nil
        lock.unlock()
    }
}

private extension AVAudioPCMBuffer {
    func ownedCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }

        copy.frameLength = frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            let byteCount = Int(source.mDataByteSize)

            guard let sourceData = source.mData,
                  let destinationData = destinationBuffers[index].mData,
                  byteCount <= Int(destinationBuffers[index].mDataByteSize) else {
                return nil
            }

            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = source.mDataByteSize
            destinationBuffers[index].mNumberChannels = source.mNumberChannels
        }

        return copy
    }
}
