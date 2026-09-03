import AVFoundation

/// Concatenates same-format clips into one highlight reel.
/// Passthrough is near-instant when all clips share one encode;
/// falls back to a re-encode if the formats differ.
enum HighlightMerger {

    static func merge(clips: [URL], to output: URL) async throws {
        precondition(!clips.isEmpty)
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Vollio", code: 20)
        }

        var cursor = CMTime.zero
        for url in clips {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try? vTrack.insertTimeRange(range, of: v, at: cursor)
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                try? aTrack.insertTimeRange(range, of: a, at: cursor)
            }
            cursor = cursor + duration
        }

        try? FileManager.default.removeItem(at: output)
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
                continue
            }
            do {
                try await ClipExporter.export(session: session, to: output)
                return
            } catch {
                try? FileManager.default.removeItem(at: output)
                continue
            }
        }
        throw NSError(domain: "Vollio", code: 21,
                      userInfo: [NSLocalizedDescriptionKey: "Merge failed"])
    }
}
