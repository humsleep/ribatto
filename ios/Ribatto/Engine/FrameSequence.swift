import AVFoundation
import CoreGraphics
import CoreVideo

/// Frames from one time range of an asset, in order.
///
/// The trackers used to pull every sample with `AVAssetImageGenerator`, which
/// seeks per frame — measured at 45 ms each on 4K match footage, 87% of
/// tracking's wall time, and the reason a dense frame feed was unaffordable.
/// Decoding the range once in order costs 2.1 ms a frame on the same file, so
/// even after throwing most frames away this wins at every sampling rate the
/// app uses (3 ms per sample at 15 fps, 20 ms at 2.5 fps).
///
/// Frames arrive already rotated to display orientation and scaled down, which
/// is what `appliesPreferredTrackTransform` plus `maximumSize` did before.
enum FrameSequence {

    /// Reads `[start, end)` in order and hands back roughly `fps` frames per
    /// second. Return `false` from `body` to stop early.
    ///
    /// Falls back to seeking if a reader can't be built — some Photos-backed
    /// assets don't support one — so a caller always gets frames, just fewer.
    /// Returns how many were delivered.
    @discardableResult
    static func read(asset: AVAsset, from start: Double, to end: Double,
                     fps: Double, maxWidth: CGFloat,
                     body: (_ time: Double, _ frame: CGImage) -> Bool) async -> Int {
        if let delivered = try? await sequential(asset: asset, from: start, to: end,
                                                 fps: fps, maxWidth: maxWidth, body: body),
           delivered > 0 {
            return delivered
        }
        return seeking(asset: asset, from: start, to: end,
                       fps: fps, maxWidth: maxWidth, body: body)
    }

    // MARK: - Sequential

    private static func sequential(asset: AVAsset, from start: Double, to end: Double,
                                   fps: Double, maxWidth: CGFloat,
                                   body: (Double, CGImage) -> Bool) async throws -> Int {
        guard fps > 0, end > start,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Ribatto", code: 60)
        }
        // A composition applies the track's preferred transform and the
        // downscale in one pass, so frames come out the right way up.
        let composition = try await AVMutableVideoComposition.videoComposition(
            withPropertiesOf: asset)
        let full = composition.renderSize
        guard full.width > 0, full.height > 0 else {
            throw NSError(domain: "Ribatto", code: 61)
        }
        let shrink = min(1, maxWidth / max(full.width, full.height))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
        composition.renderSize = CGSize(width: even(full.width * shrink),
                                        height: even(full.height * shrink))

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600))
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NSError(domain: "Ribatto", code: 62) }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "Ribatto", code: 63)
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let step = 1.0 / fps
        var nextEmit = start
        var delivered = 0
        while let sample = output.copyNextSampleBuffer() {
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard time.isFinite, time + 1e-6 >= nextEmit else { continue }
            // advance the grid past this frame rather than by one step, so a
            // gap in the source doesn't produce a burst of catch-up frames
            while nextEmit <= time { nextEmit += step }
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  let image = makeImage(buffer) else { continue }
            delivered += 1
            if !body(time, image) { break }
        }
        return delivered
    }

    private static func makeImage(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        return ctx.makeImage()      // copies, so it outlives the locked buffer
    }

    // MARK: - Seeking fallback

    /// One seek per frame. Capped at a frame every 0.3 s however dense the
    /// caller asked for — at 45 ms a seek, a 15 fps feed this way would cost
    /// more than the encode it feeds.
    private static func seeking(asset: AVAsset, from start: Double, to end: Double,
                                fps: Double, maxWidth: CGFloat,
                                body: (Double, CGImage) -> Bool) -> Int {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        let step = max(fps > 0 ? 1.0 / fps : 0.3, 0.3)
        var time = start
        var delivered = 0
        while time < end {
            if let image = try? generator.copyCGImage(
                at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) {
                delivered += 1
                if !body(time, image) { break }
            }
            time += step
        }
        return delivered
    }
}
