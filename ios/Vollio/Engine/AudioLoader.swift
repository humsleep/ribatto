import AVFoundation

/// Extracts the audio track of a video as mono 16 kHz Float32 samples.
enum AudioLoader {
    static let sampleRate = 16_000

    static func loadMono16k(url: URL) async throws -> [Float] {
        try await loadMono16k(asset: AVURLAsset(url: url))
    }

    static func loadMono16k(asset: AVAsset) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(domain: "Vollio", code: 1,
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
        samples.reserveCapacity(Int(CMTimeGetSeconds(try await asset.load(.duration))) * sampleRate + sampleRate)

        while let buf = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
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
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "Vollio", code: 2)
        }
        return samples
    }
}
