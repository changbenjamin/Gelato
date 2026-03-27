@preconcurrency import AVFoundation
import FluidAudio
import os

/// Consumes an audio buffer stream, detects speech via Silero VAD,
/// and transcribes completed speech segments via Parakeet-TDT.
final class StreamingTranscriber: @unchecked Sendable {
    private let asrManager: AsrManager
    private let vadManager: VadManager
    private let speaker: Speaker
    private let sessionStart: Date
    private let segmentationConfig: VadSegmentationConfig
    private let inputGain: Float
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String, Date) -> Void
    private let log = Logger(subsystem: "com.opengranola", category: "StreamingTranscriber")

    /// Resampler from source format to 16kHz mono Float32.
    private var converter: AVAudioConverter?
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

        // Fast path: already Float32 at 16kHz (common for system audio from ScreenCaptureKit)
        if sourceFormat.commonFormat == .pcmFormatFloat32 && sourceFormat.sampleRate == 16000 {
            guard let channelData = buffer.floatChannelData else { return nil }
            if sourceFormat.channelCount == 1 {
                // Mono — direct copy
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                return applyInputGain(to: samples)
            } else {
                // Multi-channel — use the strongest channel so stereo output doesn't get diluted.
                let channelCount = Int(sourceFormat.channelCount)
                var bestChannel = 0
                var bestEnergy: Float = -.greatestFiniteMagnitude

                for channelIndex in 0..<channelCount {
                    let channel = channelData[channelIndex]
                    var energy: Float = 0
                    for frameIndex in 0..<frameLength {
                        let sample = channel[frameIndex]
                        energy += sample * sample
                    }

                    if energy > bestEnergy {
                        bestEnergy = energy
                        bestChannel = channelIndex
                    }
                }

                let samples = Array(UnsafeBufferPointer(start: channelData[bestChannel], count: frameLength))
                return applyInputGain(to: samples)
            }
        }

        // Slow path: need to resample via AVAudioConverter
        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrames > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
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
        return applyInputGain(to: samples)
    }

    private func applyInputGain(to samples: [Float]) -> [Float] {
        guard inputGain != 1 else { return samples }

        return samples.map { sample in
            let amplified = sample * inputGain
            return min(1, max(-1, amplified))
        }
    }
}
