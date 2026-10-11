import AVFoundation
import Accelerate

/// Extracts the audio track of a video as mono 16 kHz Float32 samples.
enum AudioLoader {
    static let sampleRate = 16_000
    /// Screen recordings and some action-camera files carry no audio track.
    /// Detection runs on sound alone, so the store tells the user that rather
    /// than showing the generic "couldn't build that".
    static let noAudioCode = 1
    /// Columns in the loudness envelope drawn while a match is read.
    static let envelopeBuckets = 300

    /// How far the decode has got (0…1) and the loudness envelope so far: one
    /// RMS value per finished bucket, `envelopeBuckets` over the whole match.
    typealias Progress = @Sendable (_ fraction: Double, _ envelope: [Float]) -> Void

    static func loadMono16k(url: URL) async throws -> [Float] {
        try await loadMono16k(asset: AVURLAsset(url: url))
    }

    /// `progress` is called from the reading thread, at most about every 1%
    /// or quarter-second. Decoding a two-hour match takes minutes, and an
    /// empty bar for all of it read as a hung app.
    static func loadMono16k(asset: AVAsset, progress: Progress? = nil) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(domain: "Ribatto", code: noAudioCode,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track"])
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        var samples: [Float] = []
        // An indefinite duration is NaN here, and Int(NaN) traps.
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        samples.reserveCapacity((seconds.isFinite ? Int(seconds) : 0) * sampleRate + sampleRate)

        // The envelope rides on the copy: one sum of squares per chunk with
        // vDSP, a few hundred milliseconds over a 90-minute match.
        // No usable duration, no envelope: with nothing to divide by, a bucket
        // was one sample long and the "envelope" grew as large as the audio,
        // copied to the main thread four times a second.
        let measurable = seconds.isFinite && seconds > 1
        let expected = max(1, (measurable ? seconds : 0) * Double(sampleRate))
        let bucketLength = max(1, Int(expected) / envelopeBuckets)
        var envelope: [Float] = []
        envelope.reserveCapacity(envelopeBuckets + 1)
        var bucketSum: Float = 0
        var bucketFill = 0
        var reported = 0.0
        var reportedAt = Date()

        // A pool per buffer, as for every sample loop (CLAUDE.md): over a
        // 90-minute match the reader's buffers otherwise pile up until the
        // loop ends, on top of the samples array itself.
        var reading = true
        while reading {
            autoreleasepool {
                guard let buf = output.copyNextSampleBuffer() else { reading = false; return }
                guard let block = CMSampleBufferGetDataBuffer(buf) else { return }
                let length = CMBlockBufferGetDataLength(block)
                let count = length / MemoryLayout<Float>.size
                let old = samples.count
                samples.append(contentsOf: repeatElement(0, count: count))
                samples.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(
                        block, atOffset: 0, dataLength: length,
                        destination: raw.baseAddress!.advanced(by: old * MemoryLayout<Float>.size))
                }
                guard let progress else { return }
                // Capped at the bucket count: audio that runs past the
                // container's stated duration adds no columns.
                if measurable && envelope.count < envelopeBuckets {
                samples.withUnsafeBufferPointer { all in
                    var i = old
                    while i < all.count {
                        let n = min(bucketLength - bucketFill, all.count - i)
                        var sq: Float = 0
                        vDSP_svesq(all.baseAddress! + i, 1, &sq, vDSP_Length(n))
                        bucketSum += sq
                        bucketFill += n
                        i += n
                        if bucketFill == bucketLength {
                            envelope.append((bucketSum / Float(bucketLength)).squareRoot())
                            bucketSum = 0
                            bucketFill = 0
                            if envelope.count == envelopeBuckets { break }
                        }
                    }
                }
                }
                let fraction = min(1, Double(samples.count) / expected)
                if fraction - reported >= 0.01 || Date().timeIntervalSince(reportedAt) >= 0.25 {
                    reported = fraction
                    reportedAt = Date()
                    progress(fraction, envelope)
                }
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "Ribatto", code: 2)
        }
        // Only after the failure check: a read that died must not first
        // announce itself as complete.
        if let progress {
            if measurable && bucketFill > 0 && envelope.count < envelopeBuckets {
                envelope.append((bucketSum / Float(bucketFill)).squareRoot())
            }
            progress(1, envelope)
        }
        return samples
    }
}
