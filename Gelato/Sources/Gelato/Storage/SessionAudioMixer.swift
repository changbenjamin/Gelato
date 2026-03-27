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
            try await insertTrack(
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
            let preparedSystem = try TimingAwareStemRebuilder.prepareSource(
                from: systemURL,
                chunks: audioTiming?.systemChunks,
                streamStart: audioTiming?.systemFirstBufferAt,
                temporaryBasename: "\(outputURL.deletingPathExtension().lastPathComponent)-system"
            )
            if preparedSystem?.isRebuilt == true, let preparedSystem {
                temporaryURLs.append(preparedSystem.url)
            }
            try await insertTrack(
                from: preparedSystem?.url ?? systemURL,
                into: composition,
                at: insertionTime(
                    for: audioTiming?.systemFirstBufferAt,
                    relativeTo: combinedOrigin,
                    trustRoundedOffsets: false
                ),
                chunks: preparedSystem?.isRebuilt == true ? nil : audioTiming?.systemChunks,
                streamStart: preparedSystem?.isRebuilt == true ? nil : audioTiming?.systemFirstBufferAt
            )
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }

        try await exporter.export(to: outputURL, as: .mp4)

        return outputURL
    }

    private static func insertTrack(
        from url: URL,
        into composition: AVMutableComposition,
        at startTime: CMTime,
        chunks: [SessionAudioChunk]?,
        streamStart: Date?
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            return
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
            return
        }

        if !validChunks.isEmpty {
            diagLog("[AUDIO] steady chunk timing detected for \(url.lastPathComponent), inserting contiguous track")
        }

        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try compositionTrack.insertTimeRange(timeRange, of: track, at: startTime)
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
