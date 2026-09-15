import AVFoundation
import SoundAnalysis

/// A second opinion on each detected rally, from the sound classifier built
/// into iOS (SoundAnalysis `.version1`). No model ships with the app and
/// nothing leaves the device.
///
/// `RallyDetector` hears strikes as band-energy transients, which is fast and
/// validated, but wind on the microphone makes transients too. The classifier
/// knows what racket play sounds like over a few seconds, so it can tell the
/// two apart — and it recognises cheering and laughter, which the voice-band
/// ratio only infers from loudness.
///
/// Measured on a 26-minute courtside doubles (2026-09-15, 13 rallies): every
/// rally with a clear exchange scored at least 0.68 on the racket labels. The
/// five that did not (0.04–0.31) were 3–5 hits whose top labels were insect,
/// snake hiss and cricket — wind and microphone noise. That is one recording,
/// with no applause, ball machine or indoor court in it, so the rules are
/// conservative: only near-zero, short rallies are dropped, and the rest of
/// the doubtful ones are ranked down rather than deleted.
enum SoundCheck {
    struct Verdict: Equatable {
        /// Highest racket-sport confidence among the windows inside the rally.
        var racket: Double
        /// Highest crowd-reaction confidence just after the last strike.
        var crowd: Double
    }

    static let racketLabels: Set<String> = [
        "playing_tennis", "playing_badminton", "playing_squash", "playing_table_tennis",
    ]
    static let crowdLabels: Set<String> = [
        "cheering", "applause", "clapping", "crowd", "shout", "yell", "screaming",
        "laughter", "booing",
    ]

    /// Below this, with few strikes, a "rally" is noise.
    static let dropBelow = 0.15
    static let dropMaxHits = 5
    /// Below this a rally is kept but scored as half as good.
    static let doubtBelow = 0.35

    /// Three-second windows, overlapping by 90%. One-second windows were too
    /// short to recognise play (0.01–0.33 on the same rallies) and missed a
    /// laugh that came four seconds after the point. At half overlap a rally's
    /// confidence depended on where the windows happened to fall: shifting
    /// them by 0.75 s moved single rallies from 0.10 to 0.38, which is the
    /// difference between dropped and kept. Dense windows hold the low reading
    /// steady, for about 3 s of classifier time per 26-minute match on an M2.
    static let windowS = 3.0
    static let overlap = 0.9

    /// Verdicts parallel to `segments`; an entry is nil for a rally without
    /// strike times. nil overall when the classifier cannot run, in which case
    /// the caller keeps detection's own answer.
    static func classify(samples: [Float], sampleRate: Int,
                         segments: [RallySegment]) -> [Verdict?]? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false) else { return nil }
        var out: [Verdict?] = []
        for seg in segments {
            guard let first = seg.hitTimes?.first, let last = seg.hitTimes?.last else {
                out.append(nil)
                continue
            }
            // Only the rally and the seconds after it — about an eighth of a
            // match's audio, and the only part the verdict is about.
            let from = max(0, Int((first - 2) * Double(sampleRate)))
            let to = min(samples.count, Int((last + 5.5) * Double(sampleRate)))
            guard to > from else { out.append(nil); continue }
            guard let windows = analyze(samples[from..<to], format: format) else { return nil }
            let offset = Double(from) / Double(sampleRate)
            func within(_ a: Double, _ b: Double) -> [[String: Double]] {
                windows.filter { offset + $0.mid >= a && offset + $0.mid <= b }.map(\.scores)
            }
            var play = within(first - 0.25, last + 0.25)
            if play.isEmpty { play = within(first - 0.5, last + 0.5) }
            let after = within(last + 0.5, last + 4.0)
            out.append(Verdict(racket: peak(play, racketLabels), crowd: peak(after, crowdLabels)))
        }
        return out
    }

    /// Folds the verdicts into the rallies: drops near-certain noise, ranks
    /// the doubtful down, and scores crowd reaction by the classifier.
    static func apply(_ verdicts: [Verdict?], to segments: [RallySegment]) -> [RallySegment] {
        guard verdicts.count == segments.count else { return segments }
        var judged = zip(segments, verdicts).map { seg, verdict -> RallySegment in
            var s = seg
            s.racketConf = verdict?.racket
            s.crowdConf = verdict?.crowd
            return s
        }
        let kept = judged.filter { s in
            guard let racket = s.racketConf else { return true }
            return !(racket < dropBelow && s.hits <= dropMaxHits)
        }
        // Dropping everything would turn a quiet recording into "no rallies",
        // which Apply treats as unfinished work. Keep detection's answer.
        if !kept.isEmpty { judged = kept }

        let lengths = judged.map {
            ($0.hitTimes?.last ?? $0.end) - ($0.hitTimes?.first ?? $0.start)
        }
        // The classifier's reaction replaces the voice-band ratio only when
        // every rally has one; mixing the two scales would rank rallies by
        // which measure they happened to get.
        let reactions = judged.allSatisfy { $0.crowdConf != nil }
            ? judged.map { $0.crowdConf ?? 0 }
            : judged.map { $0.cheer ?? 0 }
        let scores = RallyDetector.scores(shots: judged.map { Double($0.hits) },
                                          cheers: reactions, lengths: lengths)
        for i in judged.indices {
            let doubtful = (judged[i].racketConf ?? 1) < doubtBelow
            judged[i].score = doubtful ? scores[i] * 0.5 : scores[i]
        }
        return judged
    }

    // MARK: - Classifier

    /// Collects the labels this file cares about from every window. Results
    /// arrive on the thread that feeds the analyzer, before
    /// `completeAnalysis` returns, so no locking is needed.
    private final class Collector: NSObject, SNResultsObserving {
        var windows: [(mid: Double, scores: [String: Double])] = []
        var failed = false

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            var scores: [String: Double] = [:]
            for c in r.classifications
            where SoundCheck.racketLabels.contains(c.identifier)
                || SoundCheck.crowdLabels.contains(c.identifier) {
                scores[c.identifier] = c.confidence
            }
            windows.append((r.timeRange.start.seconds + r.timeRange.duration.seconds / 2, scores))
        }

        func request(_ request: SNRequest, didFailWithError error: Error) { failed = true }
    }

    private static func analyze(_ slice: ArraySlice<Float>,
                                format: AVAudioFormat) -> [(mid: Double, scores: [String: Double])]? {
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1)
        else { return nil }
        request.windowDuration = CMTime(seconds: windowS,
                                        preferredTimescale: CMTimeScale(format.sampleRate))
        request.overlapFactor = overlap
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let collector = Collector()
        guard (try? analyzer.add(request, withObserver: collector)) != nil else { return nil }

        let chunk = Int(format.sampleRate)
        slice.withUnsafeBufferPointer { src in
            var pos = 0
            while pos < src.count {
                let n = min(chunk, src.count - pos)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(n)),
                      let channel = buffer.floatChannelData?[0],
                      let base = src.baseAddress else { break }
                buffer.frameLength = AVAudioFrameCount(n)
                channel.update(from: base + pos, count: n)
                analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(pos))
                pos += n
            }
        }
        analyzer.completeAnalysis()
        return collector.failed ? nil : collector.windows
    }

    private static func peak(_ windows: [[String: Double]], _ labels: Set<String>) -> Double {
        windows.map { w in labels.map { w[$0] ?? 0 }.max() ?? 0 }.max() ?? 0
    }
}
