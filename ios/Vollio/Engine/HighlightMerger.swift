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

        // Build beside the old file, not over it: rebuilding a highlight on a
        // nearly-full device used to delete the working one and then fail,
        // leaving the card offering play and save on a file that was gone.
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent("tmp_" + output.lastPathComponent)
        try? FileManager.default.removeItem(at: staging)
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
                continue
            }
            do {
                try await ClipExporter.export(session: session, to: staging)
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: staging, to: output)
                return
            } catch {
                try? FileManager.default.removeItem(at: staging)
                continue
            }
        }
        throw NSError(domain: "Vollio", code: 21,
                      userInfo: [NSLocalizedDescriptionKey: "Merge failed"])
    }
}
