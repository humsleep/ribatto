import AVFoundation
import CoreGraphics

struct ProbeInfo {
    var duration: Double
    var width: Int
    var height: Int
}

enum VideoProbe {
    /// Orientation-corrected dimensions + duration, and an optional poster JPEG.
    static func probe(url: URL, posterURL: URL? = nil) async throws -> ProbeInfo {
        try await probe(asset: AVURLAsset(url: url), posterURL: posterURL)
    }

    /// Works on an asset so the source can live in the Photos library instead
    /// of being copied into the app.
    static func probe(asset: AVAsset, posterURL: URL? = nil) async throws -> ProbeInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Vollio", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let t = try await track.load(.preferredTransform)
        let natural = try await track.load(.naturalSize)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let rect = CGRect(origin: .zero, size: natural).applying(t)

        if let posterURL {
            try? ClipExporter.writeThumbnail(
                of: asset, at: min(2.0, duration / 2), to: posterURL)
        }
        return ProbeInfo(duration: duration,
                         width: Int(abs(rect.width)),
                         height: Int(abs(rect.height)))
    }
}
