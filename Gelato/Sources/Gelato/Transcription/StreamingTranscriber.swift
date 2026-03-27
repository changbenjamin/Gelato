@preconcurrency import AVFoundation
import FluidAudio
import os

/// Consumes an audio buffer stream, detects speech via Silero VAD,
/// and transcribes completed speech segments via Parakeet-TDT.
final class StreamingTranscriber: @unchecked Sendable {
    private static let multichannelMicGain: Float = 24
    private let asrManager: AsrManager
    private let vadManager: VadManager
    private let speaker: Speaker
    private let sessionStart: Date
    private let segmentationConfig: VadSegmentationConfig
    private let inputGain: Float
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String, Date) -> Void
    private let log = Logger(subsystem: "com.opengranola", category: "StreamingTranscriber")

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    init(
        asrManager: AsrManager,
        vadManager: VadManager,
        speaker: Speaker,
        sessionStart: Date,
        segmentationConfig: VadSegmentationConfig = .default,
        inputGain: Float = 1.0,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String, Date) -> Void
    ) {
        self.asrManager = asrManager
        self.vadManager = vadManager
        self.speaker = speaker
        self.sessionStart = sessionStart
        self.segmentationConfig = segmentationConfig
        self.inputGain = inputGain
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    /// Silero VAD expects chunks of 4096 samples (256ms at 16kHz).
    private static let vadChunkSize = 4096
    /// Flush speech for transcription every ~3 seconds (48,000 samples at 16kHz).
    private static let flushInterval = 48_000

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    func run(stream: AsyncStream<CapturedAudioBuffer>) async {
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var isSpeaking = false
        var bufferCount = 0
        var currentSegmentStartSeconds: Double?
        var streamOriginDate: Date?

        for await capturedBuffer in stream {
            let buffer = capturedBuffer.buffer
            bufferCount += 1
            if streamOriginDate == nil {
                streamOriginDate = capturedBuffer.capturedAt
            }
            if bufferCount <= 3 {
                let fmt = buffer.format
                diagLog("[\(speaker.rawValue)] buffer #\(bufferCount): frames=\(buffer.frameLength) sr=\(fmt.sampleRate) ch=\(fmt.channelCount) interleaved=\(fmt.isInterleaved) common=\(fmt.commonFormat.rawValue)")
            }

            guard let samples = extractSamples(buffer) else { continue }

            if bufferCount <= 3 {
                let maxVal = samples.max() ?? 0
                diagLog("[\(speaker.rawValue)] samples: count=\(samples.count) max=\(maxVal)")
            }

            vadBuffer.append(contentsOf: samples)

            while vadBuffer.count >= Self.vadChunkSize {
                let chunk = Array(vadBuffer.prefix(Self.vadChunkSize))
                vadBuffer.removeFirst(Self.vadChunkSize)

                do {
                    let result = try await vadManager.processStreamingChunk(
                        chunk,
                        state: vadState,
                        config: segmentationConfig,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    vadState = result.state
                    let chunkStartSeconds = Double(result.state.processedSamples - chunk.count) / targetFormat.sampleRate

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            isSpeaking = true
                            speechSamples.removeAll(keepingCapacity: true)
                            currentSegmentStartSeconds = Double(event.sampleIndex) / targetFormat.sampleRate
                            diagLog("[\(self.speaker.rawValue)] speech start")

                        case .speechEnd:
                            isSpeaking = false
                            diagLog("[\(self.speaker.rawValue)] speech end, samples=\(speechSamples.count)")
                            if speechSamples.count > 8000 {
                                let segment = speechSamples
                                let segmentStart = currentSegmentStartSeconds ?? chunkStartSeconds
                                speechSamples.removeAll(keepingCapacity: true)
                                currentSegmentStartSeconds = nil
                                await transcribeSegment(
                                    segment,
                                    startedAtSeconds: segmentStart,
                                    streamOriginDate: streamOriginDate
                                )
                            } else {
                                speechSamples.removeAll(keepingCapacity: true)
                                currentSegmentStartSeconds = nil
                            }
                        }
                    }

                    if isSpeaking {
                        if currentSegmentStartSeconds == nil {
                            currentSegmentStartSeconds = chunkStartSeconds
                        }
                        speechSamples.append(contentsOf: chunk)

                        // Flush every ~3s for near-real-time output during continuous speech
                        if speechSamples.count >= Self.flushInterval {
                            let segment = speechSamples
                            let segmentStart = currentSegmentStartSeconds ?? chunkStartSeconds
                            speechSamples.removeAll(keepingCapacity: true)
                            currentSegmentStartSeconds = segmentStart + (Double(segment.count) / targetFormat.sampleRate)
                            await transcribeSegment(
                                segment,
                                startedAtSeconds: segmentStart,
                                streamOriginDate: streamOriginDate
                            )
                        }
                    }
                } catch {
                    log.error("VAD error: \(error.localizedDescription)")
                }
            }
        }

        if speechSamples.count > 8000 {
            let segmentStart = currentSegmentStartSeconds ?? 0
            await transcribeSegment(
                speechSamples,
                startedAtSeconds: segmentStart,
                streamOriginDate: streamOriginDate
            )
        }
    }

    private func transcribeSegment(
        _ samples: [Float],
        startedAtSeconds: Double,
        streamOriginDate: Date?
    ) async {
        do {
            let result = try await asrManager.transcribe(samples)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            log.info("[\(self.speaker.rawValue)] transcribed: \(text.prefix(80))")
            let origin = streamOriginDate ?? sessionStart
            let timestamp = origin.addingTimeInterval(max(0, startedAtSeconds))
            onFinal(text, timestamp)
        } catch {
            log.error("ASR error: \(error.localizedDescription)")
        }
    }

    /// Extract [Float] samples from an AVAudioPCMBuffer, resampling if needed.
    private func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        guard let monoFloatBuffer = monoFloatBuffer(from: buffer) else { return nil }

        if monoFloatBuffer.format.sampleRate == targetFormat.sampleRate {
            guard let channelData = monoFloatBuffer.floatChannelData else { return nil }
            let samples = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(monoFloatBuffer.frameLength)
            ))
            return applyInputGain(to: samples, sourceChannelCount: Int(sourceFormat.channelCount))
        }

        return resampleMonoBuffer(
            monoFloatBuffer,
            sourceChannelCount: Int(sourceFormat.channelCount)
        )
    }

    private func applyInputGain(to samples: [Float], sourceChannelCount: Int) -> [Float] {
        let totalGain = inputGain * (sourceChannelCount > 2 ? Self.multichannelMicGain : 1)
        guard totalGain != 1 else { return samples }

        return samples.map { sample in
            let amplified = sample * totalGain
            return min(1, max(-1, amplified))
        }
    }

    private func monoFloatBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0,
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: buffer.frameLength
              ) else {
            return nil
        }

        outputBuffer.frameLength = buffer.frameLength
        guard let destination = outputBuffer.floatChannelData?[0] else { return nil }

        if sourceFormat.commonFormat == .pcmFormatFloat32,
           let channelData = buffer.floatChannelData {
            if sourceFormat.channelCount == 1 {
                destination.update(from: channelData[0], count: frameLength)
                return outputBuffer
            }

            let bestChannel = strongestChannelIndex(
                channelData: channelData,
                frameLength: frameLength,
                channelCount: Int(sourceFormat.channelCount),
                interleaved: sourceFormat.isInterleaved
            )
            copyChannel(
                from: channelData,
                to: destination,
                frameLength: frameLength,
                channelCount: Int(sourceFormat.channelCount),
                interleaved: sourceFormat.isInterleaved,
                channelIndex: bestChannel
            )
            return outputBuffer
        }

        let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        )!
        guard let floatConverter = AVAudioConverter(from: sourceFormat, to: floatFormat),
              let floatBuffer = AVAudioPCMBuffer(
                pcmFormat: floatFormat,
                frameCapacity: buffer.frameLength + 32
              ) else {
            return nil
        }

        var floatError: NSError?
        var providedInput = false
        floatConverter.reset()
        floatConverter.convert(to: floatBuffer, error: &floatError) { _, outStatus in
            if providedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            providedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let floatError {
            log.error("Float conversion error: \(floatError.localizedDescription)")
            return nil
        }

        guard let floatChannelData = floatBuffer.floatChannelData else { return nil }
        if floatFormat.channelCount == 1 {
            destination.update(from: floatChannelData[0], count: Int(floatBuffer.frameLength))
            outputBuffer.frameLength = floatBuffer.frameLength
            return outputBuffer
        }

        let bestChannel = strongestChannelIndex(
            channelData: floatChannelData,
            frameLength: Int(floatBuffer.frameLength),
            channelCount: Int(floatFormat.channelCount),
            interleaved: false
        )
        copyChannel(
            from: floatChannelData,
            to: destination,
            frameLength: Int(floatBuffer.frameLength),
            channelCount: Int(floatFormat.channelCount),
            interleaved: false,
            channelIndex: bestChannel
        )
        outputBuffer.frameLength = floatBuffer.frameLength
        return outputBuffer
    }

    private func resampleMonoBuffer(
        _ buffer: AVAudioPCMBuffer,
        sourceChannelCount: Int
    ) -> [Float]? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio) + 32))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ),
        let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.reset()
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("Resample error: \(error.localizedDescription)")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
        return applyInputGain(to: samples, sourceChannelCount: sourceChannelCount)
    }

    private func strongestChannelIndex(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameLength: Int,
        channelCount: Int,
        interleaved: Bool
    ) -> Int {
        var bestChannel = 0
        var bestEnergy: Float = -.greatestFiniteMagnitude

        for channelIndex in 0..<channelCount {
            var energy: Float = 0
            for frameIndex in 0..<frameLength {
                let sample: Float
                if interleaved {
                    sample = channelData[0][(frameIndex * channelCount) + channelIndex]
                } else {
                    sample = channelData[channelIndex][frameIndex]
                }
                energy += sample * sample
            }

            if energy > bestEnergy {
                bestEnergy = energy
                bestChannel = channelIndex
            }
        }

        return bestChannel
    }

    private func copyChannel(
        from channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        to destination: UnsafeMutablePointer<Float>,
        frameLength: Int,
        channelCount: Int,
        interleaved: Bool,
        channelIndex: Int
    ) {
        for frameIndex in 0..<frameLength {
            if interleaved {
                destination[frameIndex] = channelData[0][(frameIndex * channelCount) + channelIndex]
            } else {
                destination[frameIndex] = channelData[channelIndex][frameIndex]
            }
        }
    }
}
