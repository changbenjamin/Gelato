import AVFoundation
import Foundation

enum OpenAISpeakerReferenceBuilder {
    static func buildReferences(
        audioFiles: SessionAudioFiles,
        audioTiming: SessionAudioTiming?,
        liveUtterances: [Utterance]
    ) async -> [OpenAIKnownSpeakerReference] {
        var results: [OpenAIKnownSpeakerReference] = []

        if let micReference = await buildReference(
            name: "You",
            speaker: .you,
            sourceURL: audioFiles.micURL,
            streamStart: audioTiming?.micFirstBufferAt,
            liveUtterances: liveUtterances
        ) {
            results.append(micReference)
        }

        if let systemReference = await buildReference(
            name: "Them",
            speaker: .them,
            sourceURL: audioFiles.systemURL,
            streamStart: audioTiming?.systemFirstBufferAt,
            liveUtterances: liveUtterances
        ) {
            results.append(systemReference)
        }

        return results
    }

    private static func buildReference(
        name: String,
        speaker: Speaker,
        sourceURL: URL?,
        streamStart: Date?,
        liveUtterances: [Utterance]
    ) async -> OpenAIKnownSpeakerReference? {
        guard let sourceURL else { return nil }

        do {
            let asset = AVURLAsset(url: sourceURL)
            let duration = try await asset.load(.duration)
            let totalDuration = CMTimeGetSeconds(duration)
            guard totalDuration.isFinite, totalDuration >= 2 else {
                return nil
            }

            let preferredOffset = referenceOffset(
                for: speaker,
                streamStart: streamStart,
                liveUtterances: liveUtterances
            )
            let clipDuration = min(6.0, totalDuration)
            let maxStart = max(0, totalDuration - clipDuration)
            let clipStart = min(max(0, preferredOffset), maxStart)
            guard let clipURL = try await exportClip(
                from: asset,
                sourceURL: sourceURL,
                start: clipStart,
                duration: clipDuration
            ) else {
                return nil
            }

            defer { try? FileManager.default.removeItem(at: clipURL) }

            let data = try Data(contentsOf: clipURL)
            return OpenAIKnownSpeakerReference(
                name: name,
                dataURL: "data:audio/mp4;base64,\(data.base64EncodedString())"
            )
        } catch {
            diagLog("[OPENAI-REF-FAIL] \(speaker.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    private static func referenceOffset(
        for speaker: Speaker,
        streamStart: Date?,
        liveUtterances: [Utterance]
    ) -> TimeInterval {
        guard let streamStart else { return 0 }
        guard let referenceUtterance = liveUtterances.first(where: { utterance in
            utterance.speaker == speaker && utterance.text.split(separator: " ").count >= 2
        }) ?? liveUtterances.first(where: { $0.speaker == speaker }) else {
            return 0
        }

        return max(0, referenceUtterance.timestamp.timeIntervalSince(streamStart) - 0.35)
    }

    private static func exportClip(
        from asset: AVURLAsset,
        sourceURL: URL,
        start: TimeInterval,
        duration: TimeInterval
    ) async throws -> URL? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }

        let startTime = CMTime(seconds: start, preferredTimescale: 600)
        let durationTime = CMTime(seconds: duration, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, duration: durationTime)
        try compositionTrack.insertTimeRange(timeRange, of: track, at: .zero)

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GelatoOpenAIRefs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("\(sourceURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outputURL)

        try await exporter.export(to: outputURL, as: .m4a)
        return outputURL
    }
}
