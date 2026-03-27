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

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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
        lock.unlock()

        guard let writer,
              let copy = capturedBuffer.buffer.ownedCopy(),
              let preparedBuffer = writer.prepareBufferForWriting(copy) else { return }
        guard preparedBuffer.frameLength > 0 else { return }

        lock.lock()
        micChunks.append(
            SessionAudioChunk(
                capturedAt: capturedBuffer.capturedAt,
                frameCount: Int(preparedBuffer.frameLength)
            )
        )
        lock.unlock()

        writeQueue.async {
            writer.appendPreparedBuffer(preparedBuffer)
        }
    }

    func appendSystemBuffer(_ capturedBuffer: CapturedAudioBuffer) {
        lock.lock()
        let writer = systemWriter
        if systemFirstBufferAt == nil {
            systemFirstBufferAt = capturedBuffer.capturedAt
        }
        lock.unlock()

        guard let writer,
              let copy = capturedBuffer.buffer.ownedCopy(),
              let preparedBuffer = writer.prepareBufferForWriting(copy) else { return }
        guard preparedBuffer.frameLength > 0 else { return }

        lock.lock()
        systemChunks.append(
            SessionAudioChunk(
                capturedAt: capturedBuffer.capturedAt,
                frameCount: Int(preparedBuffer.frameLength)
            )
        )
        lock.unlock()

        writeQueue.async {
            writer.appendPreparedBuffer(preparedBuffer)
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
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(url: URL) {
        self.url = url
    }

    func prepareBufferForWriting(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if targetFormat == nil {
            targetFormat = buffer.format
            converter = nil
            converterInputFormat = nil
            return buffer
        }

        guard let targetFormat else { return nil }
        guard !Self.formatsMatch(buffer.format, targetFormat) else { return buffer }

        if converter == nil || converterInputFormat.map({ !Self.formatsMatch($0, buffer.format) }) != false {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
        }

        guard let activeConverter = converter else {
            diagLog("[AUDIO-WRITE-CONVERT-FAIL] \(url.lastPathComponent): converter unavailable")
            return nil
        }

        if let convertedBuffer = convert(buffer, to: targetFormat, using: activeConverter) {
            return convertedBuffer
        }

        // `AVAudioConverter` treats `.endOfStream` as terminal state. Since we
        // convert one standalone buffer at a time, rebuild once and retry if a
        // reused converter yielded no frames.
        converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        converterInputFormat = buffer.format

        guard let freshConverter = converter,
              let convertedBuffer = convert(buffer, to: targetFormat, using: freshConverter) else {
            diagLog(
                "[AUDIO-WRITE-CONVERT-FAIL] \(url.lastPathComponent): " +
                "conversion produced no output frames"
            )
            return nil
        }
        return convertedBuffer
    }

    func appendPreparedBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        do {
            if audioFile == nil {
                let outputFormat = targetFormat ?? buffer.format
                targetFormat = outputFormat
                audioFile = try AVAudioFile(
                    forWriting: url,
                    settings: outputFormat.settings,
                    commonFormat: outputFormat.commonFormat,
                    interleaved: outputFormat.isInterleaved
                )
            }
            try audioFile?.write(from: buffer)
        } catch {
            diagLog("[AUDIO-WRITE-FAIL] \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat &&
            lhs.channelCount == rhs.channelCount &&
            lhs.isInterleaved == rhs.isInterleaved &&
            abs(lhs.sampleRate - rhs.sampleRate) < 0.5
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let outputCapacity = AVAudioFrameCount(
            max(
                1,
                ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 64
            )
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            diagLog("[AUDIO-WRITE-CONVERT-FAIL] \(url.lastPathComponent): output buffer allocation failed")
            return nil
        }

        converter.reset()

        var error: NSError?
        var didProvideInput = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            diagLog("[AUDIO-WRITE-CONVERT-FAIL] \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }

        guard outputBuffer.frameLength > 0 else { return nil }

        diagLog(
            "[AUDIO-WRITE-CONVERT] \(url.lastPathComponent): " +
            "\(buffer.format.sampleRate)Hz -> \(targetFormat.sampleRate)Hz " +
            "frames=\(outputBuffer.frameLength)"
        )
        return outputBuffer
    }

    func finish() {
        lock.lock()
        audioFile = nil
        targetFormat = nil
        converter = nil
        converterInputFormat = nil
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
