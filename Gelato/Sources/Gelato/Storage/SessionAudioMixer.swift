import AVFoundation
import Foundation

enum SessionAudioMixer {
    static func createCombinedAudio(
        micURL: URL?,
        systemURL: URL?,
        outputURL: URL,
        audioTiming: SessionAudioTiming? = nil
    ) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            try await createCombinedAudioSync(
                micURL: micURL,
                systemURL: systemURL,
                outputURL: outputURL,
                audioTiming: audioTiming
            )
        }.value
    }

    /// Volume boost applied to the microphone track so it matches system audio
    /// loudness in the combined mix. Mic input is typically much quieter than
    /// system audio routed through a process tap.
    private static let micVolumeBoost: Float = 9.0

    private static func createCombinedAudioSync(
        micURL: URL?,
        systemURL: URL?,
        outputURL: URL,
        audioTiming: SessionAudioTiming? = nil
    ) async throws -> URL? {
        guard micURL != nil || systemURL != nil else { return nil }

        try? FileManager.default.removeItem(at: outputURL)
        var temporaryURLs: [URL] = []
        defer {
            for temporaryURL in temporaryURLs {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let composition = AVMutableComposition()
        let combinedOrigin = [audioTiming?.micFirstBufferAt, audioTiming?.systemFirstBufferAt]
            .compactMap { $0 }
            .min()

        var micTrackID: CMPersistentTrackID?

        if let micURL {
            let preparedMic = try TimingAwareStemRebuilder.prepareSource(
                from: micURL,
                chunks: audioTiming?.micChunks,
                streamStart: audioTiming?.micFirstBufferAt,
                temporaryBasename: "\(outputURL.deletingPathExtension().lastPathComponent)-mic"
            )
            if preparedMic?.isRebuilt == true, let preparedMic {
                temporaryURLs.append(preparedMic.url)
            }
            micTrackID = try await insertTrack(
                from: preparedMic?.url ?? micURL,
                into: composition,
                at: insertionTime(
                    for: audioTiming?.micFirstBufferAt,
                    relativeTo: combinedOrigin,
                    trustRoundedOffsets: false
                ),
                chunks: preparedMic?.isRebuilt == true ? nil : audioTiming?.micChunks,
                streamStart: preparedMic?.isRebuilt == true ? nil : audioTiming?.micFirstBufferAt
            )
        }

        if let systemURL {
            // Compute the effective sample rate from wall-clock timing (OpenOats approach).
            // The process tap can deliver far more frames than real-time after a device
            // switch, so the declared sample rate in the CAF file may be wrong.
            let effectiveSystemURL: URL
            let addedTempURL: Bool
            if let effectiveRate = Self.effectiveSampleRate(
                url: systemURL,
                chunks: audioTiming?.systemChunks,
                firstBufferAt: audioTiming?.systemFirstBufferAt
            ) {
                let resampledURL = outputURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        "\(outputURL.deletingPathExtension().lastPathComponent)-system-resampled.caf"
                    )
                if let resampled = try? Self.resampleToCorrectDuration(
                    sourceURL: systemURL,
                    outputURL: resampledURL,
                    effectiveRate: effectiveRate
                ) {
                    effectiveSystemURL = resampled
                    temporaryURLs.append(resampled)
                    addedTempURL = true
                } else {
                    effectiveSystemURL = systemURL
                    addedTempURL = false
                }
            } else {
                effectiveSystemURL = systemURL
                addedTempURL = false
            }

            let preparedSystem = try TimingAwareStemRebuilder.prepareSource(
                from: effectiveSystemURL,
                chunks: addedTempURL ? nil : audioTiming?.systemChunks,
                streamStart: addedTempURL ? nil : audioTiming?.systemFirstBufferAt,
                temporaryBasename: "\(outputURL.deletingPathExtension().lastPathComponent)-system"
            )
            if preparedSystem?.isRebuilt == true, let preparedSystem {
                temporaryURLs.append(preparedSystem.url)
            }
            try await insertTrack(
                from: preparedSystem?.url ?? effectiveSystemURL,
                into: composition,
                at: insertionTime(
                    for: audioTiming?.systemFirstBufferAt,
                    relativeTo: combinedOrigin,
                    trustRoundedOffsets: false
                ),
                chunks: (preparedSystem?.isRebuilt == true || addedTempURL) ? nil : audioTiming?.systemChunks,
                streamStart: (preparedSystem?.isRebuilt == true || addedTempURL) ? nil : audioTiming?.systemFirstBufferAt
            )
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }

        // Boost the mic track volume so it matches system audio loudness.
        if let micTrackID,
           let micCompositionTrack = composition.track(withTrackID: micTrackID) {
            let micParams = AVMutableAudioMixInputParameters(track: micCompositionTrack)
            micParams.trackID = micTrackID
            micParams.setVolume(micVolumeBoost, at: .zero)

            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [micParams]
            exporter.audioMix = audioMix
        }

        try await exporter.export(to: outputURL, as: .mp4)

        return outputURL
    }

    /// Inserts an audio file as a new track in the composition.
    /// Returns the track ID of the inserted composition track, or `nil` if insertion failed.
    @discardableResult
    private static func insertTrack(
        from url: URL,
        into composition: AVMutableComposition,
        at startTime: CMTime,
        chunks: [SessionAudioChunk]?,
        streamStart: Date?
    ) async throws -> CMPersistentTrackID? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            return nil
        }

        let audioFile = try AVAudioFile(forReading: url)
        let validChunks = SessionAudioTiming.validChunks(chunks)
        let useChunkTiming = SessionAudioTiming.shouldUseChunkTiming(
            validChunks,
            sampleRate: audioFile.processingFormat.sampleRate
        )

        if !validChunks.isEmpty, let streamStart, useChunkTiming {
            let sampleRate = audioFile.processingFormat.sampleRate
            var sourceCursor: Double = 0

            for chunk in validChunks {
                let chunkDurationSeconds = Double(chunk.frameCount) / sampleRate
                let chunkDuration = CMTime(
                    seconds: chunkDurationSeconds,
                    preferredTimescale: 60_000
                )
                let sourceTime = CMTime(
                    seconds: sourceCursor,
                    preferredTimescale: 60_000
                )
                let targetTime = insertionTime(
                    for: chunk.capturedAt,
                    relativeTo: streamStart,
                    trustRoundedOffsets: true
                )
                    + startTime
                let timeRange = CMTimeRange(start: sourceTime, duration: chunkDuration)
                try compositionTrack.insertTimeRange(timeRange, of: track, at: targetTime)
                sourceCursor += chunkDurationSeconds
            }
            return compositionTrack.trackID
        }

        if !validChunks.isEmpty {
            diagLog("[AUDIO] steady chunk timing detected for \(url.lastPathComponent), inserting contiguous track")
        }

        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try compositionTrack.insertTimeRange(timeRange, of: track, at: startTime)
        return compositionTrack.trackID
    }

    // MARK: - Effective Sample Rate (OpenOats approach)

    /// Compute the actual sample rate by comparing total frames written to the
    /// wall-clock time span. If the effective rate differs significantly from the
    /// file's declared rate, we need to resample.
    private static func effectiveSampleRate(
        url: URL,
        chunks: [SessionAudioChunk]?,
        firstBufferAt: Date?
    ) -> Double? {
        let validChunks = SessionAudioTiming.validChunks(chunks)
        guard validChunks.count >= 2, let firstBufferAt else { return nil }

        let totalFrames = validChunks.reduce(0) { $0 + $1.frameCount }
        guard totalFrames > 0 else { return nil }

        let lastChunk = validChunks.last!
        let wallClockSeconds = lastChunk.capturedAt.timeIntervalSince(firstBufferAt)
        guard wallClockSeconds > 1.0 else { return nil }

        let effectiveRate = Double(totalFrames) / wallClockSeconds

        // Check if effective rate differs significantly from declared rate
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let declaredRate = audioFile.processingFormat.sampleRate
        let ratio = effectiveRate / declaredRate

        // If the effective rate is within 15% of declared, no correction needed
        if abs(ratio - 1.0) < 0.15 {
            return nil
        }

        diagLog(
            "[AUDIO-RATE-FIX] \(url.lastPathComponent): effective=\(Int(effectiveRate))Hz " +
            "declared=\(Int(declaredRate))Hz ratio=\(String(format: "%.2f", ratio))x " +
            "wallClock=\(String(format: "%.1f", wallClockSeconds))s"
        )
        return effectiveRate
    }

    /// Resample a CAF file from its effective sample rate to produce correct-duration
    /// output. Reads all samples, re-tags them at the effective rate, then resamples
    /// to 48kHz mono via AVAudioConverter.
    private static func resampleToCorrectDuration(
        sourceURL: URL,
        outputURL: URL,
        effectiveRate: Double
    ) throws -> URL? {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = sourceFile.processingFormat
        let frameCount = AVAudioFrameCount(sourceFile.length)
        guard frameCount > 0 else { return nil }

        // Read all source samples
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return nil
        }
        try sourceFile.read(into: readBuffer)

        // Re-tag at the effective rate (same raw samples, different declared rate)
        guard let effectiveFormat = AVAudioFormat(
            commonFormat: sourceFormat.commonFormat,
            sampleRate: effectiveRate,
            channels: sourceFormat.channelCount,
            interleaved: sourceFormat.isInterleaved
        ) else { return nil }

        guard let retaggedBuffer = AVAudioPCMBuffer(
            pcmFormat: effectiveFormat,
            frameCapacity: frameCount
        ) else { return nil }
        retaggedBuffer.frameLength = readBuffer.frameLength

        // Copy raw sample data
        if let src = readBuffer.floatChannelData, let dst = retaggedBuffer.floatChannelData {
            for ch in 0..<Int(sourceFormat.channelCount) {
                memcpy(dst[ch], src[ch], Int(frameCount) * MemoryLayout<Float>.size)
            }
        }

        // Resample to 48kHz mono
        let targetRate: Double = 48_000
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetRate, channels: 1
        ) else { return nil }

        guard let converter = AVAudioConverter(from: effectiveFormat, to: targetFormat) else {
            return nil
        }

        let ratio = targetRate / effectiveRate
        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio) + 1
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
            return nil
        }

        var consumed = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return retaggedBuffer
        }

        guard outBuffer.frameLength > 0 else { return nil }

        let correctedDuration = Double(outBuffer.frameLength) / targetRate
        diagLog(
            "[AUDIO-RATE-FIX] resampled \(sourceURL.lastPathComponent): " +
            "\(frameCount) frames @ \(Int(effectiveRate))Hz -> " +
            "\(outBuffer.frameLength) frames @ \(Int(targetRate))Hz " +
            "(duration: \(String(format: "%.1f", correctedDuration))s)"
        )

        // Write resampled audio to output file
        try? FileManager.default.removeItem(at: outputURL)
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: targetFormat.settings,
            commonFormat: targetFormat.commonFormat,
            interleaved: targetFormat.isInterleaved
        )
        try outputFile.write(from: outBuffer)

        return outputURL
    }

    private static func insertionTime(
        for streamStart: Date?,
        relativeTo origin: Date?,
        trustRoundedOffsets: Bool
    ) -> CMTime {
        let offset = SessionAudioTiming.offsetSeconds(
            from: streamStart,
            relativeTo: origin,
            trustRoundedOffsets: trustRoundedOffsets
        )
        return CMTime(seconds: offset, preferredTimescale: 60_000)
    }
}
