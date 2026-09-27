// Cuts a short, shareable excerpt out of a full match recording.
//
// Why this exists: App Review needs a video to import, and the reviewer's
// device will not have one. The full recording is 6.6 GB, which is useless as
// a download. This produces a couple of minutes containing several rallies,
// small enough to host on a static site and to pull down on a phone.
//
// Detection is audio-based, so the soundtrack is what matters and the picture
// is not: the excerpt is scaled to 720p and encoded at a bitrate chosen for
// size, while the audio is re-encoded at a rate that leaves racket impacts
// intact. `AVAssetExportPreset1280x720` is not used because it picks its own
// bitrate — on this source it produced 138 MB for 170 seconds, past the 100 MB
// a file may be on GitHub Pages and far past what anyone downloads on a phone.
//
//   swift Tools/make_sample.swift <source> <out.mp4> <start> <end> [mbps] [longSide]
//
// Run from ios/.

import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 5,
      let start = Double(args[3]), let end = Double(args[4]), end > start else {
    FileHandle.standardError.write(
        "usage: make_sample.swift <source> <out.mp4> <start> <end> [mbps]\n".data(using: .utf8)!)
    exit(2)
}
let mbps = args.count > 5 ? (Double(args[5]) ?? 1.6) : 1.6
// The long side to fit inside. 1280 keeps the import sample small; 1920 is for
// the short clips that have to show what full-quality export looks like, which
// a 720p source cannot demonstrate — the app's vertical export is capped by
// what it was given.
let longSide = args.count > 6 ? (Double(args[6]) ?? 1280) : 1280

let src = URL(fileURLWithPath: args[1])
let dst = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: dst)

let sem = DispatchSemaphore(value: 0)
var failure: String?

Task {
    defer { sem.signal() }
    do {
        let asset = AVURLAsset(url: src)
        let total = CMTimeGetSeconds(try await asset.load(.duration))
        guard end <= total else {
            failure = String(format: "end %.1fs is past the source's %.1fs", end, total)
            return
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            failure = "no video track"
            return
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let fps = try await videoTrack.load(.nominalFrameRate)
        // Fit inside 720p without changing the shape of the frame.
        let shown = natural.applying(transform)
        let w = abs(shown.width), h = abs(shown.height)
        let scale = min(1, CGFloat(longSide) / max(w, h),
                        CGFloat(longSide) * 9 / 16 / min(w, h))
        func even(_ v: CGFloat) -> Int { max(2, Int((v * scale / 2).rounded()) * 2) }
        let outSize = CGSize(width: even(w), height: even(h))

        // A video composition does the scaling during decode, which keeps the
        // frames out of this process entirely.
        //
        // `renderSize` alone does NOT scale. It only sets the canvas, so a 4K
        // source keeps its full-size layer and the output is its top-left
        // 1280x720 — sky and treetops, no court. The scale has to go on the
        // layer's transform, on top of the track's own preferred transform.
        // The same mistake cost a day in FrameSequence; see CLAUDE.md.
        let comp = AVMutableVideoComposition()
        comp.renderSize = outSize
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, Int(fps.rounded()))))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)),
                           at: .zero)
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]

        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outSize.width),
            AVVideoHeightKey: Int(outSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(mbps * 1_000_000),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if audioTrack != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            aIn = input
        }
        // The excerpt must start at zero, not at `start`, or every player shows
        // ten minutes of nothing before it begins.
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Two readers rather than one with two outputs: a single reader has to
        // have both of its outputs drained at the same time or it stops feeding
        // whichever one is ahead and never finishes.
        let vReader = try AVAssetReader(asset: asset)
        vReader.timeRange = range
        let vOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        vOut.videoComposition = comp
        vReader.add(vOut)
        vReader.startReading()

        var aReader: AVAssetReader?
        var aOut: AVAssetReaderTrackOutput?
        if let audioTrack {
            let r = try AVAssetReader(asset: asset)
            r.timeRange = range
            let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            r.add(o)
            r.startReading()
            aReader = r
            aOut = o
        }

        let offset = range.start
        func pump(_ input: AVAssetWriterInput,
                  _ next: @escaping () -> CMSampleBuffer?) async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "pump")) {
                    while input.isReadyForMoreMediaData {
                        guard let buf = next() else {
                            input.markAsFinished()
                            cont.resume()
                            return
                        }
                        // Shift every sample back so the file starts at zero.
                        var timing = CMSampleTimingInfo()
                        CMSampleBufferGetSampleTimingInfo(buf, at: 0, timingInfoOut: &timing)
                        timing.presentationTimeStamp =
                            CMTimeSubtract(timing.presentationTimeStamp, offset)
                        if timing.decodeTimeStamp.isValid {
                            timing.decodeTimeStamp =
                                CMTimeSubtract(timing.decodeTimeStamp, offset)
                        }
                        var shifted: CMSampleBuffer?
                        CMSampleBufferCreateCopyWithNewTiming(
                            allocator: kCFAllocatorDefault, sampleBuffer: buf,
                            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                            sampleBufferOut: &shifted)
                        if let shifted { input.append(shifted) }
                    }
                }
            }
        }

        print(String(format: "source %.1fs -> %.0fx%.0f excerpt %.1f..%.1f (%.1fs) @ %.1f Mbps",
                     total, outSize.width, outSize.height, start, end, end - start, mbps))

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(vIn) { vOut.copyNextSampleBuffer() } }
            if let aIn, let aOut {
                group.addTask { await pump(aIn) { aOut.copyNextSampleBuffer() } }
            }
        }
        await writer.finishWriting()
        if writer.status != .completed {
            failure = writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
        }
        _ = aReader
    } catch {
        failure = error.localizedDescription
    }
}
sem.wait()

if let failure {
    FileHandle.standardError.write("failed: \(failure)\n".data(using: .utf8)!)
    exit(1)
}

let bytes = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size]) as? Int ?? 0
print(String(format: "wrote %@ (%.1f MB)", dst.lastPathComponent, Double(bytes) / 1_048_576))
