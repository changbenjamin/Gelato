import AVFoundation
import Foundation

enum SessionAudioMixer {
    static func createCombinedAudio(
        micURL: URL?,
        systemURL: URL?,
        outputURL: URL
    ) async throws -> URL? {
        guard micURL != nil || systemURL != nil else { return nil }

        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()

        if let micURL {
            let asset = AVURLAsset(url: micURL)
            if let track = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let timeRange = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
                try compositionTrack.insertTimeRange(timeRange, of: track, at: .zero)
            }
        }

        if let systemURL {
            let asset = AVURLAsset(url: systemURL)
            if let track = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let timeRange = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
                try compositionTrack.insertTimeRange(timeRange, of: track, at: .zero)
            }
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }

        try await exporter.export(to: outputURL, as: .m4a)

        return outputURL
    }
}
