import AVFoundation

/// Extracts the audio track of a video as mono 16 kHz Float32 samples.
enum AudioLoader {
    static let sampleRate = 16_000
    /// Screen recordings and some action-camera files carry no audio track.
    /// Detection runs on sound alone, so the store tells the user that rather
    /// than showing the generic "couldn't build that".
    static let noAudioCode = 1

    static func loadMono16k(url: URL) async throws -> [Float] {
        try await loadMono16k(asset: AVURLAsset(url: url))
    }

    static func loadMono16k(asset: AVAsset) async throws -> [Float] {
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
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "Ribatto", code: 2)
        }
        return samples
    }
}
