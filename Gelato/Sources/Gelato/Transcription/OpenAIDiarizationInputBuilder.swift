import AVFoundation
import Foundation

enum OpenAIDiarizationInputBuilder {
    private static let targetSampleRate: Double = 16_000
    private static let inputFrameCapacity: AVAudioFrameCount = 8_192
    private static let targetPeak: Float = 0.85
    private static let minimumSystemGain: Float = 1.0
    private static let maximumSystemGain: Float = 8.0
    private static let desiredSystemToMicRMSRatio: Float = 1.1
    private static let maximumMicDuckAmount: Float = 0.6
    private static let duckAttack: Float = 0.35
    private static let duckRelease: Float = 0.015

    static func buildUploadFile(
        audioFiles: SessionAudioFiles,
        audioTiming: SessionAudioTiming?,
        sessionID: String
    ) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            try buildUploadFileSync(
                audioFiles: audioFiles,
                audioTiming: audioTiming,
                sessionID: sessionID
            )
        }.value
    }

    private static func buildUploadFileSync(
        audioFiles: SessionAudioFiles,
        audioTiming: SessionAudioTiming?,
        sessionID: String
    ) throws -> URL? {
        guard audioFiles.micURL != nil || audioFiles.systemURL != nil else { return nil }

        let sessionStart = SessionMetadataIO.parseDate(from: sessionID) ?? Date()
        let earliestStart = [audioTiming?.micFirstBufferAt, audioTiming?.systemFirstBufferAt, sessionStart]
            .compactMap { $0 }
            .min() ?? sessionStart

        let micSource = try loadSource(from: audioFiles.micURL)
        let systemSource = try loadSource(from: audioFiles.systemURL)
        let gains = mixingGains(micSource: micSource, systemSource: systemSource)
        let micShouldUseChunkTiming = SessionAudioTiming.shouldUseChunkTiming(
            audioTiming?.micChunks,
            sampleRate: micSource?.sampleRate ?? 0
        )
        let systemShouldUseChunkTiming = SessionAudioTiming.shouldUseChunkTiming(
            audioTiming?.systemChunks,
            sampleRate: systemSource?.sampleRate ?? 0
        )

        guard micSource != nil || systemSource != nil else { return nil }

        let totalLength = max(
            projectedLength(
                source: micSource,
                firstBufferAt: audioTiming?.micFirstBufferAt ?? sessionStart,
                chunks: audioTiming?.micChunks,
                earliestStart: earliestStart,
                useChunkTiming: micShouldUseChunkTiming
            ),
            projectedLength(
                source: systemSource,
                firstBufferAt: audioTiming?.systemFirstBufferAt ?? sessionStart,
                chunks: audioTiming?.systemChunks,
                earliestStart: earliestStart,
                useChunkTiming: systemShouldUseChunkTiming
            )
        )
        guard totalLength > 0 else { return nil }

        var micMix = [Float](repeating: 0, count: totalLength)
        var systemMix = [Float](repeating: 0, count: totalLength)

        accumulate(
            source: micSource,
            into: &micMix,
            firstBufferAt: audioTiming?.micFirstBufferAt ?? sessionStart,
            chunks: audioTiming?.micChunks,
            earliestStart: earliestStart,
            gain: gains.mic,
            useChunkTiming: micShouldUseChunkTiming
        )
        accumulate(
            source: systemSource,
            into: &systemMix,
            firstBufferAt: audioTiming?.systemFirstBufferAt ?? sessionStart,
            chunks: audioTiming?.systemChunks,
            earliestStart: earliestStart,
            gain: gains.system,
            useChunkTiming: systemShouldUseChunkTiming
        )

        var mixed = mergeForDiarization(
            mic: micMix,
            system: systemMix,
            systemRMS: rms(of: systemMix)
        )
        normalize(&mixed)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GelatoOpenAIUploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputURL = directory.appendingPathComponent("\(sessionID)-openai-upload.wav")
        try? FileManager.default.removeItem(at: outputURL)
        try writeWAV(samples: mixed, to: outputURL)
        return outputURL
    }

    private struct LoadedSource {
        let samples: [Float]
        let sampleRate: Double
    }

    private static func loadSource(from url: URL?) throws -> LoadedSource? {
        guard let url else { return nil }

        let inputFile = try AVAudioFile(forReading: url)
        let sourceFormat = inputFile.processingFormat
        let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        )!

        let needsFloatConversion =
            sourceFormat.commonFormat != .pcmFormatFloat32 || sourceFormat.isInterleaved
        let floatConverter = needsFloatConversion
            ? AVAudioConverter(from: sourceFormat, to: floatFormat)
            : nil

        var samples: [Float] = []

        while true {
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: inputFrameCapacity
            ) else {
                break
            }

            try inputFile.read(into: inputBuffer, frameCount: inputFrameCapacity)
            if inputBuffer.frameLength == 0 { break }

            let floatBuffer: AVAudioPCMBuffer
            if let floatConverter {
                let outputCapacity = AVAudioFrameCount(max(1, inputBuffer.frameLength + 32))
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: floatFormat,
                    frameCapacity: outputCapacity
                ) else {
                    continue
                }

                var error: NSError?
                var didProvideInput = false
                floatConverter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    if didProvideInput {
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    didProvideInput = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                }

                if let error { throw error }
                floatBuffer = outputBuffer
            } else {
                floatBuffer = inputBuffer
            }

            samples.append(contentsOf: dominantChannelSamples(from: floatBuffer))
        }

        guard !samples.isEmpty else { return nil }
        return LoadedSource(samples: samples, sampleRate: sourceFormat.sampleRate)
    }

    private static func mixingGains(
        micSource: LoadedSource?,
        systemSource: LoadedSource?
    ) -> (mic: Float, system: Float) {
        guard let micSource, let systemSource else {
            return (mic: 1.0, system: 1.0)
        }

        let micRMS = rms(of: micSource.samples)
        let systemRMS = rms(of: systemSource.samples)
        guard micRMS > 0, systemRMS > 0 else {
            return (mic: 1.0, system: 1.0)
        }

        let desiredSystemGain = (micRMS * desiredSystemToMicRMSRatio) / systemRMS
        let systemGain = min(max(desiredSystemGain, minimumSystemGain), maximumSystemGain)

        diagLog(
            "[OPENAI-UPLOAD] balancing stems micRMS=\(micRMS) systemRMS=\(systemRMS) " +
            "systemGain=\(systemGain)"
        )

        return (mic: 1.0, system: systemGain)
    }

    private static func mergeForDiarization(
        mic: [Float],
        system: [Float],
        systemRMS: Float
    ) -> [Float] {
        let count = max(mic.count, system.count)
        guard count > 0 else { return [] }

        var output = [Float](repeating: 0, count: count)
        guard systemRMS > 0 else {
            for index in 0..<count where index < mic.count {
                output[index] = mic[index]
            }
            return output
        }

        var envelope: Float = 0
        let duckReference = max(systemRMS * 4, 0.01)

        for index in 0..<count {
            let micSample = index < mic.count ? mic[index] : 0
            let systemSample = index < system.count ? system[index] : 0
            let targetEnvelope = abs(systemSample)
            let smoothing = targetEnvelope > envelope ? duckAttack : duckRelease
            envelope += (targetEnvelope - envelope) * smoothing

            let normalizedEnvelope = min(max(envelope / duckReference, 0), 1)
            let micDuck = normalizedEnvelope * maximumMicDuckAmount
            output[index] = (micSample * (1 - micDuck)) + systemSample
        }

        diagLog(
            "[OPENAI-UPLOAD] applied mic ducking with systemRMS=\(systemRMS) " +
            "duckReference=\(duckReference)"
        )

        return output
    }

    private static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }

    private static func dominantChannelSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0, let channelData = buffer.floatChannelData else { return [] }
        guard channelCount > 1 else {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

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

        return Array(UnsafeBufferPointer(start: channelData[bestChannel], count: frameLength))
    }

    private static func projectedLength(
        source: LoadedSource?,
        firstBufferAt: Date,
        chunks: [SessionAudioChunk]?,
        earliestStart: Date,
        useChunkTiming: Bool
    ) -> Int {
        guard let source else { return 0 }

        if let chunks, !chunks.isEmpty, useChunkTiming {
            return chunks.reduce(0) { partialResult, chunk in
                let chunkOffset = targetOffset(
                    for: chunk.capturedAt,
                    earliestStart: earliestStart,
                    trustRoundedOffsets: true
                )
                let chunkLength = targetFrameCount(
                    sourceFrameCount: chunk.frameCount,
                    sourceRate: source.sampleRate
                )
                return max(partialResult, chunkOffset + chunkLength)
            }
        }

        let offset = targetOffset(
            for: firstBufferAt,
            earliestStart: earliestStart,
            trustRoundedOffsets: useChunkTiming
        )
        return offset + targetFrameCount(
            sourceFrameCount: source.samples.count,
            sourceRate: source.sampleRate
        )
    }

    private static func accumulate(
        source: LoadedSource?,
        into mix: inout [Float],
        firstBufferAt: Date,
        chunks: [SessionAudioChunk]?,
        earliestStart: Date,
        gain: Float,
        useChunkTiming: Bool
    ) {
        guard let source else { return }

        if let chunks, !chunks.isEmpty, useChunkTiming {
            var sourceIndex = 0

            for chunk in chunks {
                guard sourceIndex < source.samples.count else { break }

                let sourceCount = min(chunk.frameCount, source.samples.count - sourceIndex)
                guard sourceCount > 0 else { continue }

                let chunkSamples = Array(source.samples[sourceIndex..<(sourceIndex + sourceCount)])
                sourceIndex += sourceCount

                let resampled = resample(chunkSamples, from: source.sampleRate)
                let offset = targetOffset(
                    for: chunk.capturedAt,
                    earliestStart: earliestStart,
                    trustRoundedOffsets: true
                )
                accumulate(samples: resampled, into: &mix, offset: offset, gain: gain)
            }
            return
        }

        if let chunks, !chunks.isEmpty, !useChunkTiming {
            diagLog("[OPENAI-UPLOAD] coarse chunk timing detected, mixing contiguous stem")
        }

        let resampled = resample(source.samples, from: source.sampleRate)
        let offset = targetOffset(
            for: firstBufferAt,
            earliestStart: earliestStart,
            trustRoundedOffsets: useChunkTiming
        )
        accumulate(samples: resampled, into: &mix, offset: offset, gain: gain)
    }

    private static func resample(_ samples: [Float], from sourceRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard sourceRate != targetSampleRate else { return samples }

        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        )!
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            return samples
        }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        inputBuffer.floatChannelData?[0].update(from: samples, count: samples.count)

        let outputCapacity = AVAudioFrameCount(
            max(1, ceil(Double(samples.count) * (targetSampleRate / sourceRate)) + 32)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            return samples
        }

        var error: NSError?
        var didProvideInput = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if error != nil { return samples }
        guard let channelData = outputBuffer.floatChannelData?[0] else { return samples }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
    }

    private static func targetOffset(
        for date: Date,
        earliestStart: Date,
        trustRoundedOffsets: Bool
    ) -> Int {
        let offsetSeconds = SessionAudioTiming.offsetSeconds(
            from: date,
            relativeTo: earliestStart,
            trustRoundedOffsets: trustRoundedOffsets
        )
        return max(0, Int(round(offsetSeconds * targetSampleRate)))
    }

    private static func targetFrameCount(sourceFrameCount: Int, sourceRate: Double) -> Int {
        max(1, Int(ceil(Double(sourceFrameCount) * (targetSampleRate / sourceRate))))
    }

    private static func accumulate(
        samples: [Float],
        into mix: inout [Float],
        offset: Int,
        gain: Float
    ) {
        guard !samples.isEmpty, offset < mix.count else { return }

        for (index, sample) in samples.enumerated() {
            let targetIndex = offset + index
            guard targetIndex < mix.count else { break }
            mix[targetIndex] += sample * gain
        }
    }

    private static func normalize(_ samples: inout [Float]) {
        guard let peak = samples.lazy.map({ abs($0) }).max(), peak > 0 else { return }
        let gain = min(targetPeak / peak, 1.0)

        if gain != 1 {
            for index in samples.indices {
                samples[index] *= gain
            }
        }

        for index in samples.indices {
            samples[index] = min(1, max(-1, samples[index]))
        }
    }

    private static func writeWAV(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let outputFile = try AVAudioFile(forWriting: url, settings: settings)
        let outputFormat = outputFile.processingFormat
        let chunkSize = 16_384
        var index = 0

        while index < samples.count {
            let count = min(chunkSize, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(count)
            ) else {
                break
            }

            buffer.frameLength = AVAudioFrameCount(count)
            guard let channelData = buffer.int16ChannelData?[0] else { break }

            for sampleIndex in 0..<count {
                let sample = min(1, max(-1, samples[index + sampleIndex]))
                channelData[sampleIndex] = Int16(sample * Float(Int16.max))
            }

            try outputFile.write(from: buffer)
            index += count
        }
    }
}
