import Accelerate
import Foundation

/// Audio-based rally detection — Swift port of the validated Python pipeline.
///
/// Racquet/paddle impacts are broadband transients with strong energy in a
/// sport-specific band that decay within ~150 ms. Camera AGC compresses
/// absolute loudness, so we detect sudden *rises* of band energy (spectral
/// flux) against the clip's own flux tail distribution.
///
/// Two-tier rule: hits are collected at a loose threshold so quiet far-court
/// shots still count, but a group only becomes a rally if it contains at
/// least one strong hit (or is long enough on its own).
enum RallyDetector {

    static let nfft = 512
    static let hop = 160                    // 10 ms at 16 kHz
    static let voiceBand: (Float, Float) = (60, 1000)
    static let decayS = 0.15
    static let padStartS = 2.0
    static let padEndS = 3.5
    /// Window after the last hit to listen for a reaction in. It starts late
    /// enough to skip the hit's own broadband tail and runs long enough to
    /// catch a shout that arrives after the ball lands.
    static let cheerFromS = 0.2
    static let cheerToS = 2.5
    /// Weights of the three signals in a rally's score. Shot count leads
    /// because it is the one that never lies: a long exchange really was a
    /// better point. Crowd reaction is next, and raw length last — a rally can
    /// be long because someone was slow to serve.
    static let scoreWeights = (hits: 0.40, cheer: 0.35, length: 0.25)

    static func detect(samples: [Float],
                       sampleRate: Int,
                       duration: Double,
                       sensitivity: Sensitivity,
                       sport: Sport) -> [RallySegment] {
        let p = sensitivity.params
        let nfrm = (samples.count - nfft) / hop
        guard nfrm > 10 else { return [] }
        let hopS = Double(hop) / Double(sampleRate)

        // ── per-frame band magnitudes ──
        let (bandE, voiceE) = bandEnergies(samples: samples, sampleRate: sampleRate,
                                           nfrm: nfrm, band: sport.band)

        // ── spectral flux (positive rises only) ──
        var flux = [Float](repeating: 0, count: nfrm)
        for i in 1..<nfrm { flux[i] = max(bandE[i] - bandE[i - 1], 0) }

        let looseT = percentile(flux, p.loosePct)
        let strongT = percentile(flux, p.strongPct)

        // ── transient hit candidates ──
        let w = Int(0.05 / hopS)
        let decayW = Int(decayS / hopS)
        var hits: [(t: Double, f: Float, pk: Float)] = []
        for i in 0..<nfrm where flux[i] > looseT {
            if i < w || i > nfrm - decayW - 3 { continue }
            var isMax = true
            for j in (i - w)...(i + w) where flux[j] > flux[i] { isMax = false; break }
            if !isMax { continue }
            let pk = bandE[i..<min(i + 3, nfrm)].max() ?? 0
            let tail = bandE[(i + 4)..<min(i + decayW, nfrm)]
            if let tmin = tail.min(), tmin > 0.6 * pk { continue }  // sustained sound
            let vpk = voiceE[max(0, i - 1)..<min(i + 2, nfrm)].max() ?? 0
            if pk < 0.8 * vpk { continue }                           // voice-dominated
            let t = Double(i) * hopS
            // Two strikes closer than the ball can travel and come back are two
            // sources, not one exchange. Keep the louder — the near court is
            // the loud one — instead of whichever came first.
            if let last = hits.last, t - last.t < sport.minExchangeS {
                if flux[i] > last.f { hits[hits.count - 1] = (t, flux[i], pk) }
                continue
            }
            hits.append((t, flux[i], pk))
        }

        // ── cluster hits into rallies ──
        var groups: [[(t: Double, f: Float, pk: Float)]] = []
        var cur: [(t: Double, f: Float, pk: Float)] = []
        for h in hits {
            if let last = cur.last, h.t - last.t > sport.gap {
                groups.append(cur); cur = []
            }
            cur.append(h)
        }
        if !cur.isEmpty { groups.append(cur) }

        var kept: [[(t: Double, f: Float, pk: Float)]] = []
        for g in groups {
            let span = g[g.count - 1].t - g[0].t
            let nStrong = g.filter { $0.f >= strongT }.count
            // A real rally's hits are paced by ball travel — the mean interval
            // can't be under ~0.3s. Applause and chatter bursts are far denser,
            // so this one check rejects them without touching real play.
            let meanInterval = span / Double(max(1, g.count - 1))
            if meanInterval < 0.3 { continue }
            if (g.count >= p.minHits && nStrong >= 1 && span >= p.minSpan)
                || (g.count >= 6 && span >= 4.0) {
                kept.append(g)
            }
        }

        var merged: [[(t: Double, f: Float, pk: Float)]] = []
        for g in kept {
            if let last = merged.last?.last, g[0].t - last.t < sport.mergeGap {
                merged[merged.count - 1].append(contentsOf: g)
            } else {
                merged.append(g)
            }
        }

        // ── score the points ──
        //
        // Which fifteen seconds to post is the whole problem with a 26-minute
        // match, so rank the rallies rather than leaving the user to scroll.
        // Everything here reads arrays that are already in memory.
        let cheers = merged.map { g in
            cheerRatio(voiceE: voiceE, hopS: hopS, nfrm: nfrm,
                       rallyStart: g[0].t, lastHit: g[g.count - 1].t)
        }
        let lengths = merged.map { $0[$0.count - 1].t - $0[0].t }
        let shots = merged.map { Double($0.count) }
        let nHits = normalized(shots)
        let nCheer = normalized(cheers)
        let nLength = normalized(lengths)

        return merged.enumerated().map { i, g in
            let score = nHits[i] * scoreWeights.hits
                      + nCheer[i] * scoreWeights.cheer
                      + nLength[i] * scoreWeights.length
            return RallySegment(start: max(0, g[0].t - padStartS),
                                end: min(duration, g[g.count - 1].t + padEndS),
                                hits: g.count,
                                score: min(max(score, 0), 1),
                                hitTimes: g.map { $0.t },
                                cheer: cheers[i])
        }
    }

    // MARK: - Scoring

    /// Loudest voice-band moment just after the point ends, over how loud the
    /// same band was during play. Measuring against the rally's own baseline
    /// rather than an absolute level keeps this honest across microphones,
    /// camera AGC and how far away the phone was sitting.
    private static func cheerRatio(voiceE: [Float], hopS: Double, nfrm: Int,
                                   rallyStart: Double, lastHit: Double) -> Double {
        let from = Int((lastHit + cheerFromS) / hopS)
        let to = min(nfrm, Int((lastHit + cheerToS) / hopS))
        let baseFrom = max(0, Int(rallyStart / hopS))
        let baseTo = min(nfrm, Int(lastHit / hopS))
        guard to > from, from >= 0, to <= nfrm, baseTo > baseFrom + 1 else { return 0 }
        let peak = voiceE[from..<to].max() ?? 0
        // median, so one shout mid-rally doesn't raise the bar it's measured against
        let baseline = voiceE[baseFrom..<baseTo].sorted()[(baseTo - baseFrom) / 2]
        guard baseline > 0 else { return 0 }
        return Double(peak / baseline)
    }

    /// Min-max over the session, so a score says "good for this match" rather
    /// than comparing against some absolute that a different court would break.
    private static func normalized(_ values: [Double]) -> [Double] {
        guard let lo = values.min(), let hi = values.max(), hi > lo else {
            return Array(repeating: 0.5, count: values.count)
        }
        return values.map { ($0 - lo) / (hi - lo) }
    }

    // MARK: - FFT band energies

    private static func bandEnergies(samples: [Float], sampleRate: Int, nfrm: Int,
                                     band: (lo: Float, hi: Float)) -> ([Float], [Float]) {
        let half = nfft / 2
        // numpy-compatible symmetric Hann: 0.5 - 0.5*cos(2πn/(N-1))
        var window = [Float](repeating: 0, count: nfft)
        for n in 0..<nfft {
            window[n] = 0.5 - 0.5 * cos(2 * .pi * Float(n) / Float(nfft - 1))
        }
        let binHz = Float(sampleRate) / Float(nfft)
        func binRange(_ lo: Float, _ hi: Float) -> Range<Int> {
            let a = max(1, Int((lo / binHz).rounded(.up)))
            let b = min(half - 1, Int((hi / binHz).rounded(.down)))
            return a..<(b + 1)
        }
        let bandBins = binRange(band.lo, band.hi)
        let voiceBins = binRange(voiceBand.0, voiceBand.1)

        guard let dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nfft), .FORWARD) else {
            return ([], [])
        }
        defer { vDSP_DFT_DestroySetup(dft) }

        var bandE = [Float](repeating: 0, count: nfrm)
        var voiceE = [Float](repeating: 0, count: nfrm)
        var frame = [Float](repeating: 0, count: nfft)
        var evens = [Float](repeating: 0, count: half)
        var odds = [Float](repeating: 0, count: half)
        var outR = [Float](repeating: 0, count: half)
        var outI = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)

        for f in 0..<nfrm {
            let off = f * hop
            samples.withUnsafeBufferPointer { src in
                window.withUnsafeBufferPointer { win in
                    vDSP_vmul(src.baseAddress! + off, 1, win.baseAddress!, 1,
                              &frame, 1, vDSP_Length(nfft))
                }
            }
            // deinterleave to even/odd for real-input DFT
            frame.withUnsafeBufferPointer { fp in
                for k in 0..<half {
                    evens[k] = fp[2 * k]
                    odds[k] = fp[2 * k + 1]
                }
            }
            vDSP_DFT_Execute(dft, evens, odds, &outR, &outI)
            // |X_k| for k in 1..<half (packing puts DC/Nyquist in index 0 — unused)
            outR.withUnsafeBufferPointer { rp in
                outI.withUnsafeBufferPointer { ip in
                    var split = DSPSplitComplex(
                        realp: UnsafeMutablePointer(mutating: rp.baseAddress!),
                        imagp: UnsafeMutablePointer(mutating: ip.baseAddress!))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
            var s: Float = 0
            mags.withUnsafeBufferPointer { mp in
                vDSP_sve(mp.baseAddress! + bandBins.lowerBound, 1, &s,
                         vDSP_Length(bandBins.count))
                bandE[f] = s
                vDSP_sve(mp.baseAddress! + voiceBins.lowerBound, 1, &s,
                         vDSP_Length(voiceBins.count))
                voiceE[f] = s
            }
        }
        return (bandE, voiceE)
    }

    /// numpy-compatible linear-interpolation percentile.
    static func percentile(_ values: [Float], _ pct: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = pct / 100 * Double(sorted.count - 1)
        let lo = Int(rank)
        let hi = min(lo + 1, sorted.count - 1)
        let frac = Float(rank - Double(lo))
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }
}
