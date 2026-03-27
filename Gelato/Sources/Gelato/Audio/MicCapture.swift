@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio directly from a Core Audio input device.
///
/// Using AVAudioEngine here caused headset-connected setups to hang or ignore
/// the requested input device, especially with Bluetooth outputs. A direct HAL
/// capture path keeps mic selection independent from the active speaker route.
final class MicCapture: @unchecked Sendable {
    private let stateLock = NSLock()
    private let continuationLock = NSLock()
    private let callbackLock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.gelato.mic.capture")
    private let deliveryQueue = DispatchQueue(label: "com.gelato.mic.delivery")
    private let _audioLevel = AudioLevel()
    private let _error = SyncString()

    private var continuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var onBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?
    private var captureDeviceID: AudioDeviceID?
    private var ioProcID: AudioDeviceIOProcID?
    private var inputFormat: AVAudioFormat?
    private var accumulator: PCMChunkAccumulator?
    private var deliveredChunkCount = 0

    var audioLevel: Float { _audioLevel.value }
    var captureError: String? { _error.value }

    func bufferStream(
        deviceID: AudioDeviceID? = nil,
        onBuffer: (@Sendable (CapturedAudioBuffer) -> Void)? = nil
    ) -> AsyncStream<CapturedAudioBuffer> {
        callbackLock.withLock {
            self.onBuffer = onBuffer
        }

        let stream = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(32)) { continuation in
            self._error.value = nil
            self.continuationLock.withLock {
                self.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                diagLog("[MIC-TERM] stream terminated, stopping capture")
                self?.stopCapture(finishStream: false)
            }
        }

        diagLog("[MIC-1] bufferStream called, deviceID=\(String(describing: deviceID))")

        do {
            try startCapture(deviceID: deviceID ?? Self.defaultInputDeviceID())
        } catch {
            let message = "Mic failed: \(error.localizedDescription)"
            diagLog("[MIC-FAIL] \(message)")
            _error.value = message
            callbackLock.withLock {
                self.onBuffer = nil
            }
            let currentContinuation = continuationLock.withLock { () -> AsyncStream<CapturedAudioBuffer>.Continuation? in
                let current = continuation
                continuation = nil
                return current
            }
            currentContinuation?.finish()
        }

        return stream
    }

    func stop() {
        diagLog("[MIC-STOP] begin")
        stopCapture(finishStream: true)
        diagLog("[MIC-STOP] end")
    }

    private func startCapture(deviceID: AudioDeviceID?) throws {
        guard let deviceID else {
            throw CaptureError.noInputDevice
        }

        let deviceName = Self.deviceName(for: deviceID) ?? "Unknown input device"
        let format = try Self.inputFormat(for: deviceID)
        let accumulator = try PCMChunkAccumulator(format: format, targetFrameCount: 4096)

        diagLog("[MIC-2] selected device id=\(deviceID) name=\(deviceName)")
        diagLog(
            "[MIC-3] input format: sr=\(format.sampleRate) ch=\(format.channelCount) " +
            "interleaved=\(format.isInterleaved) commonFormat=\(format.commonFormat.rawValue)"
        )

        var createdIOProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &createdIOProcID,
            deviceID,
            ioQueue
        ) { [weak self] inNow, inputData, inputTime, _, _ in
            self?.handleInputData(
                inputData,
                inputTime: inputTime,
                fallbackTime: inNow
            )
        }

        guard createStatus == noErr, let createdIOProcID else {
            throw CaptureError.ioProcCreationFailed(status: createStatus)
        }

        let startStatus = AudioDeviceStart(deviceID, createdIOProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(deviceID, createdIOProcID)
            throw CaptureError.startFailed(status: startStatus)
        }

        stateLock.withLock {
            self.captureDeviceID = deviceID
            self.ioProcID = createdIOProcID
            self.inputFormat = format
            self.accumulator = accumulator
            self.deliveredChunkCount = 0
        }

        diagLog("[MIC-4] capture started for \(deviceName)")
    }

    private func stopCapture(finishStream: Bool) {
        let captureState = stateLock.withLock { () -> CaptureState in
            CaptureState(
                deviceID: captureDeviceID,
                ioProcID: ioProcID,
                format: inputFormat
            )
        }

        if let deviceID = captureState.deviceID,
           let ioProcID = captureState.ioProcID {
            let stopStatus = AudioDeviceStop(deviceID, ioProcID)
            if stopStatus != noErr {
                diagLog("[MIC-STOP-FAIL] status=\(stopStatus)")
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

        if let deviceID = captureState.deviceID,
           let ioProcID = captureState.ioProcID {
            let destroyStatus = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            if destroyStatus != noErr {
                diagLog("[MIC-DESTROY-FAIL] status=\(destroyStatus)")
            }
        }

        stateLock.withLock {
            captureDeviceID = nil
            ioProcID = nil
            inputFormat = nil
            accumulator = nil
            deliveredChunkCount = 0
        }

        if finishStream {
            let currentContinuation = continuationLock.withLock { () -> AsyncStream<CapturedAudioBuffer>.Continuation? in
                let current = continuation
                continuation = nil
                return current
            }
            currentContinuation?.finish()
        } else {
            continuationLock.withLock {
                continuation = nil
            }
        }

        callbackLock.withLock {
            onBuffer = nil
        }
        _audioLevel.value = 0
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
            let format = self.stateLock.withLock { self.inputFormat }
            self.deliver(chunk: pendingChunk, format: format)
        }
    }

    private func deliver(chunk: PendingPCMChunk, format: AVAudioFormat?) {
        guard let format, let buffer = chunk.makePCMBuffer(format: format) else { return }

        deliveredChunkCount += 1
        let count = deliveredChunkCount
        let rms = Self.normalizedRMS(from: buffer)
        _audioLevel.value = min(rms * 25, 1.0)
        if count <= 5 || count % 100 == 0 {
            diagLog("[MIC-6] chunk #\(count): frames=\(buffer.frameLength) rms=\(rms) level=\(_audioLevel.value)")
        }

        let capturedBuffer = CapturedAudioBuffer(buffer: buffer, capturedAt: chunk.capturedAt)

        let callback = callbackLock.withLock { onBuffer }
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

    private static func inputFormat(for deviceID: AudioDeviceID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0, nil,
            &size,
            &streamDescription
        )
        guard status == noErr else {
            throw CaptureError.formatQueryFailed(status: status)
        }

        guard streamDescription.mFormatID == kAudioFormatLinearPCM,
              streamDescription.mSampleRate > 0,
              streamDescription.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError.invalidInputFormat
        }

        return format
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

    // MARK: - List available input devices

    static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String)] = []

        for deviceID in deviceIDs {
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize)
            guard status == noErr, bufferListSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPtr)
            guard status == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            guard let name = deviceName(for: deviceID) else { continue }
            result.append((id: deviceID, name: name))
        }

        return result
    }

    /// Resolve the device used when the app is left in automatic mode.
    /// This prefers dedicated microphones over Bluetooth headset mics and
    /// common virtual routing devices.
    static func automaticInputDeviceID() -> AudioDeviceID? {
        let devices = availableInputDevices()
        guard !devices.isEmpty else { return defaultInputDeviceID() }

        let defaultID = defaultInputDeviceID()
        let ranked = devices
            .map { device in
                (
                    device: device,
                    score: deviceSelectionScore(
                        for: device.name,
                        isOSDefault: device.id == defaultID,
                        transportType: deviceTransportType(for: device.id)
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.device.name.localizedCaseInsensitiveCompare(rhs.device.name) == .orderedAscending
            }

        return ranked.first?.device.id ?? defaultID
    }

    static func automaticInputDeviceName() -> String? {
        guard let id = automaticInputDeviceID() else { return nil }
        return deviceName(for: id)
    }

    static func inputDeviceName(for deviceID: AudioDeviceID) -> String? {
        deviceName(for: deviceID)
    }

    /// Convert a CoreAudio AudioDeviceID to the UID string used by ScreenCaptureKit.
    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func deviceTransportType(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        return status == noErr ? transportType : nil
    }

    private static func deviceSelectionScore(
        for deviceName: String,
        isOSDefault: Bool,
        transportType: UInt32?
    ) -> Int {
        let lowered = deviceName.lowercased()

        let strongPositiveKeywords = [
            "microphone",
            "built-in"
        ]
        let weakPositiveKeywords = [
            "mic",
            "input",
            "headset"
        ]
        let negativeKeywords = [
            "background music",
            "ui sounds",
            "zoomaudiodevice",
            "loopback",
            "blackhole",
            "soundflower",
            "virtual",
            "bass"
        ]

        var score = 0

        if isOSDefault {
            score += 20
        }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            score += 140
        case kAudioDeviceTransportTypeUSB:
            score += 100
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            score -= 80
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            score -= 160
        default:
            break
        }

        if strongPositiveKeywords.contains(where: lowered.contains) {
            score += 120
        }

        if weakPositiveKeywords.contains(where: lowered.contains) {
            score += 45
        }

        if negativeKeywords.contains(where: lowered.contains) {
            score -= 120
        }

        if lowered.contains("airpods") || lowered.contains("buds") {
            score -= 60
        }

        return score
    }

    private struct CaptureState {
        let deviceID: AudioDeviceID?
        let ioProcID: AudioDeviceIOProcID?
        let format: AVAudioFormat?
    }

    enum CaptureError: LocalizedError {
        case noInputDevice
        case formatQueryFailed(status: OSStatus)
        case invalidInputFormat
        case ioProcCreationFailed(status: OSStatus)
        case startFailed(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No input device is available for microphone capture."
            case .formatQueryFailed(let status):
                return "macOS could not read the input device format (\(status))."
            case .invalidInputFormat:
                return "macOS returned an unsupported input format for the microphone device."
            case .ioProcCreationFailed(let status):
                return "macOS could not attach an IO callback to the microphone device (\(status))."
            case .startFailed(let status):
                return "macOS could not start the microphone device (\(status))."
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
            throw MicCapture.CaptureError.invalidInputFormat
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

/// Simple thread-safe float holder for audio level.
final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe optional string holder.
final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
