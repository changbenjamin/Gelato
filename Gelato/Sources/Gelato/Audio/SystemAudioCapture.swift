@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Captures system audio using a Core Audio process tap instead of ScreenCaptureKit.
final class SystemAudioCapture: @unchecked Sendable {
    private let stateLock = NSLock()
    private let continuationLock = NSLock()
    private let callbackLock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.gelato.system-audio.tap")
    private let deliveryQueue = DispatchQueue(label: "com.gelato.system-audio.delivery")
    private let _audioLevel = AudioLevel()

    private var continuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var onSystemBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?

    private var processTap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var accumulator: PCMChunkAccumulator?
    private var deliveredChunkCount = 0

    var audioLevel: Float { _audioLevel.value }

    struct CaptureStreams {
        let systemAudio: AsyncStream<CapturedAudioBuffer>
    }

    func bufferStream(
        onSystemBuffer: (@Sendable (CapturedAudioBuffer) -> Void)? = nil
    ) async throws -> CaptureStreams {
        callbackLock.withLock {
            self.onSystemBuffer = onSystemBuffer
        }

        let stream = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(32)) { continuation in
            self.continuationLock.withLock {
                self.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.continuationLock.withLock {
                    self?.continuation = nil
                }
            }
        }

        do {
            try startCapture()
            return CaptureStreams(systemAudio: stream)
        } catch {
            continuationLock.withLock {
                continuation?.finish()
                continuation = nil
            }
            callbackLock.withLock {
                self.onSystemBuffer = nil
            }
            throw error
        }
    }

    func stop() async {
        let captureState = stateLock.withLock { () -> CaptureState in
            CaptureState(
                processTap: processTap,
                aggregateDevice: aggregateDevice,
                ioProcID: ioProcID,
                format: tapFormat
            )
        }

        if let aggregateDevice = captureState.aggregateDevice,
           let ioProcID = captureState.ioProcID {
            let stopStatus = AudioDeviceStop(aggregateDevice.id, ioProcID)
            if stopStatus != noErr {
                diagLog("[SYS-TAP-STOP-FAIL] status=\(stopStatus)")
            }
        }

        let pendingChunk = ioQueue.sync { () -> PendingPCMChunk? in
            let chunk = accumulator?.flush()
            accumulator = nil
            return chunk
        }

        if let pendingChunk {
            deliveryQueue.sync {
                deliver(chunk: pendingChunk, format: captureState.format)
            }
        }
        deliveryQueue.sync {}

        if let aggregateDevice = captureState.aggregateDevice,
           let ioProcID = captureState.ioProcID {
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
            if destroyStatus != noErr {
                diagLog("[SYS-TAP-IOPROC-DESTROY-FAIL] status=\(destroyStatus)")
            }
        }

        if let aggregateDevice = captureState.aggregateDevice {
            do {
                try AudioHardwareSystem.shared.destroyAggregateDevice(aggregateDevice)
            } catch {
                diagLog("[SYS-TAP-AGG-DESTROY-FAIL] \(error.localizedDescription)")
            }
        }

        if let processTap = captureState.processTap {
            do {
                try AudioHardwareSystem.shared.destroyProcessTap(processTap)
            } catch {
                diagLog("[SYS-TAP-DESTROY-FAIL] \(error.localizedDescription)")
            }
        }

        stateLock.withLock {
            processTap = nil
            aggregateDevice = nil
            ioProcID = nil
            tapFormat = nil
            accumulator = nil
            deliveredChunkCount = 0
        }

        let continuation = continuationLock.withLock { () -> AsyncStream<CapturedAudioBuffer>.Continuation? in
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.finish()

        callbackLock.withLock {
            onSystemBuffer = nil
        }
        _audioLevel.value = 0
    }

    private func startCapture() throws {
        let system = AudioHardwareSystem.shared

        guard let outputDevice = try system.defaultOutputDevice else {
            throw CaptureError.noDefaultOutputDevice
        }

        let outputUID = try outputDevice.uid
        let outputStreamIndex = try Self.firstOutputStreamIndex(for: outputDevice)
        let excludedProcessIDs = Self.excludedProcessIDs(system: system)

        let tapDescription = CATapDescription(
            excludingProcesses: excludedProcessIDs,
            deviceUID: outputUID,
            stream: outputStreamIndex
        )
        tapDescription.name = "Gelato System Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        guard let processTap = try system.makeProcessTap(description: tapDescription) else {
            throw CaptureError.tapCreationFailed
        }

        let tapUID = try processTap.uid
        var tapStreamDescription = try processTap.format
        guard let tapFormat = AVAudioFormat(streamDescription: &tapStreamDescription) else {
            try? system.destroyProcessTap(processTap)
            throw CaptureError.invalidTapFormat
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "com.gelato.system-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Gelato System Audio",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]

        guard let aggregateDevice = try system.makeAggregateDevice(description: aggregateDescription) else {
            try? system.destroyProcessTap(processTap)
            throw CaptureError.aggregateDeviceCreationFailed
        }

        let accumulator = try PCMChunkAccumulator(format: tapFormat, targetFrameCount: 4096)
        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDevice.id,
            ioQueue
        ) { [weak self] inNow, inputData, inputTime, _, _ in
            self?.handleInputData(
                inputData,
                inputTime: inputTime,
                fallbackTime: inNow
            )
        }

        guard createStatus == noErr, let ioProcID else {
            try? system.destroyAggregateDevice(aggregateDevice)
            try? system.destroyProcessTap(processTap)
            throw CaptureError.ioProcCreationFailed(status: createStatus)
        }

        let startStatus = AudioDeviceStart(aggregateDevice.id, ioProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
            try? system.destroyAggregateDevice(aggregateDevice)
            try? system.destroyProcessTap(processTap)
            throw CaptureError.startFailed(status: startStatus)
        }

        stateLock.withLock {
            self.processTap = processTap
            self.aggregateDevice = aggregateDevice
            self.ioProcID = ioProcID
            self.tapFormat = tapFormat
            self.accumulator = accumulator
            self.deliveredChunkCount = 0
        }

        diagLog(
            "[SYS-TAP-START] output=\(outputUID) stream=\(outputStreamIndex) " +
            "sr=\(tapFormat.sampleRate) ch=\(tapFormat.channelCount) interleaved=\(tapFormat.isInterleaved)"
        )
    }

    private func handleInputData(
        _ inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>?,
        fallbackTime: UnsafePointer<AudioTimeStamp>?
    ) {
        let capturedAt = Self.captureDate(inputTime: inputTime, fallbackTime: fallbackTime)
        let pendingChunk = stateLock.withLock { accumulator?.append(inputData, capturedAt: capturedAt) }
        guard let pendingChunk else { return }

        deliveryQueue.async { [weak self] in
            guard let self else { return }
            let format = self.stateLock.withLock { self.tapFormat }
            self.deliver(chunk: pendingChunk, format: format)
        }
    }

    private func deliver(chunk: PendingPCMChunk, format: AVAudioFormat?) {
        guard let format, let buffer = chunk.makePCMBuffer(format: format) else { return }

        deliveredChunkCount += 1
        let count = deliveredChunkCount
        let rms = Self.normalizedRMS(from: buffer)
        _audioLevel.value = min(rms * 8, 1.0)
        if count <= 5 || count % 50 == 0 {
            diagLog("[SYS-TAP] #\(count) frames=\(buffer.frameLength) rms=\(rms)")
        }

        let capturedBuffer = CapturedAudioBuffer(buffer: buffer, capturedAt: chunk.capturedAt)

        let callback = callbackLock.withLock { onSystemBuffer }
        callback?(capturedBuffer)

        let continuation = continuationLock.withLock { self.continuation }
        _ = continuation?.yield(capturedBuffer)
    }

    private static func captureDate(
        inputTime: UnsafePointer<AudioTimeStamp>?,
        fallbackTime: UnsafePointer<AudioTimeStamp>?
    ) -> Date {
        let hostTimeValidFlag: UInt32 = 1 << 1

        if let inputTime,
           (inputTime.pointee.mFlags.rawValue & hostTimeValidFlag) != 0 {
            return CaptureClock.date(forHostTime: inputTime.pointee.mHostTime)
        }

        if let fallbackTime,
           (fallbackTime.pointee.mFlags.rawValue & hostTimeValidFlag) != 0 {
            return CaptureClock.date(forHostTime: fallbackTime.pointee.mHostTime)
        }

        return Date()
    }

    private static func excludedProcessIDs(system: AudioHardwareSystem) -> [AudioObjectID] {
        if let process = try? system.process(for: getpid()) {
            return [process.id]
        }
        return []
    }

    private static func firstOutputStreamIndex(for device: AudioHardwareDevice) throws -> UInt {
        let streams = try device.streams
        for (index, stream) in streams.enumerated() where try stream.direction == .output {
            return UInt(index)
        }
        throw CaptureError.noOutputStream
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return channelData[0][(frame * stride) + channel]
                }
                return channelData[channel][frame]
            }
        }

        if let channelData = buffer.int16ChannelData {
            let scale: Float = 1 / Float(Int16.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        return 0
    }

    private static func rms(
        frameLength: Int,
        channelCount: Int,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> Float {
        var sum: Float = 0

        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let sample = sampleAt(frame, channel)
                sum += sample * sample
            }
        }

        let sampleCount = Float(frameLength * channelCount)
        return sampleCount > 0 ? sqrt(sum / sampleCount) : 0
    }

    private struct CaptureState {
        let processTap: AudioHardwareTap?
        let aggregateDevice: AudioHardwareAggregateDevice?
        let ioProcID: AudioDeviceIOProcID?
        let format: AVAudioFormat?
    }

    enum CaptureError: LocalizedError {
        case noDefaultOutputDevice
        case noOutputStream
        case tapCreationFailed
        case invalidTapFormat
        case aggregateDeviceCreationFailed
        case ioProcCreationFailed(status: OSStatus)
        case startFailed(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .noDefaultOutputDevice:
                return "No default output device is available for system audio capture."
            case .noOutputStream:
                return "The default output device has no output stream to tap."
            case .tapCreationFailed:
                return "macOS could not create the system-audio process tap."
            case .invalidTapFormat:
                return "macOS returned an invalid format for the system-audio tap."
            case .aggregateDeviceCreationFailed:
                return "macOS could not create the private aggregate device for system audio capture."
            case .ioProcCreationFailed(let status):
                return "macOS could not attach an IO callback to the system-audio device (\(status))."
            case .startFailed(let status):
                return "macOS could not start the system-audio device (\(status))."
            }
        }
    }
}

private struct PendingPCMChunk: Sendable {
    let frameCount: Int
    let bufferData: [Data]
    let capturedAt: Date

    func makePCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destinationBuffers.count == bufferData.count else { return nil }

        for index in destinationBuffers.indices {
            let byteCount = bufferData[index].count
            guard let destination = destinationBuffers[index].mData,
                  byteCount <= Int(destinationBuffers[index].mDataByteSize) else {
                return nil
            }

            bufferData[index].withUnsafeBytes { source in
                if let sourceBaseAddress = source.baseAddress {
                    memcpy(destination, sourceBaseAddress, byteCount)
                }
            }
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }

        return buffer
    }
}

private final class PCMChunkAccumulator {
    private let targetFrameCount: Int
    private let bytesPerFrame: Int
    private let bufferCount: Int

    private var bufferData: [Data]
    private var accumulatedFrameCount = 0
    private var chunkCapturedAt: Date?

    init(format: AVAudioFormat, targetFrameCount: Int) throws {
        let streamDescription = format.streamDescription.pointee
        guard streamDescription.mBytesPerFrame > 0 else {
            throw SystemAudioCapture.CaptureError.invalidTapFormat
        }

        self.targetFrameCount = targetFrameCount
        self.bytesPerFrame = Int(streamDescription.mBytesPerFrame)
        self.bufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        self.bufferData = Array(repeating: Data(), count: bufferCount)
    }

    func append(_ inputData: UnsafePointer<AudioBufferList>, capturedAt: Date) -> PendingPCMChunk? {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard sourceBuffers.count == bufferCount else {
            reset()
            return nil
        }

        guard let frameCount = frameCount(for: sourceBuffers),
              frameCount > 0 else {
            return nil
        }

        if chunkCapturedAt == nil {
            chunkCapturedAt = capturedAt
        }

        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            let byteCount = Int(source.mDataByteSize)
            guard let sourceData = source.mData, byteCount > 0 else { continue }
            bufferData[index].append(sourceData.assumingMemoryBound(to: UInt8.self), count: byteCount)
        }

        accumulatedFrameCount += frameCount
        guard accumulatedFrameCount >= targetFrameCount else { return nil }
        return flush()
    }

    func flush() -> PendingPCMChunk? {
        guard accumulatedFrameCount > 0, let chunkCapturedAt else { return nil }
        let chunk = PendingPCMChunk(
            frameCount: accumulatedFrameCount,
            bufferData: bufferData,
            capturedAt: chunkCapturedAt
        )
        reset()
        return chunk
    }

    private func frameCount(for buffers: UnsafeMutableAudioBufferListPointer) -> Int? {
        guard let first = buffers.first else { return nil }
        guard Int(first.mDataByteSize) % bytesPerFrame == 0 else { return nil }
        return Int(first.mDataByteSize) / bytesPerFrame
    }

    private func reset() {
        accumulatedFrameCount = 0
        bufferData = Array(repeating: Data(), count: bufferCount)
        chunkCapturedAt = nil
    }
}
