import Foundation

// Runs the shipping detection engine over a video and prints what each
// sport / sensitivity preset would produce. Use this to sanity-check new
// footage (indoor courts, night games, badminton, noisy clubs) before
// trusting a preset in the app.
//
//   ./validate <video> [sport]        sport: tennis|badminton|pickleball|padel

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: validate <video> [sport]")
    exit(1)
}
let url = URL(fileURLWithPath: args[1])
let sports: [Sport] = args.count > 2
    ? [Sport(rawValue: args[2]) ?? .tennis]
    : Sport.allCases

func mmss(_ t: Double) -> String {
    String(format: "%02d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        let info = try await VideoProbe.probe(url: url)
        print("file      : \(url.lastPathComponent)")
        print("dimensions: \(info.width)x\(info.height)  (\(info.height > info.width ? "vertical" : "landscape"))")
        print("duration  : \(String(format: "%.1f", info.duration))s")

        let t0 = Date()
        let samples = try await AudioLoader.loadMono16k(url: url)
        print("audio     : \(samples.count) samples in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\n")

        for sport in sports {
            print("── \(sport.rawValue) ─────────────────────────────")
            for sens in [Sensitivity.low, .normal, .high] {
                let t1 = Date()
                let segs = RallyDetector.detect(
                    samples: samples, sampleRate: AudioLoader.sampleRate,
                    duration: info.duration, sensitivity: sens, sport: sport)
                let kept = segs.reduce(0.0) { $0 + ($1.end - $1.start) }
                let pct = info.duration > 0 ? 100 * kept / info.duration : 0
                print(String(format: "  %-6s %2d rallies  %5.0fs kept (%.0f%%)  [%.2fs]",
                             (sens.rawValue as NSString).utf8String!, segs.count,
                             kept, pct, Date().timeIntervalSince(t1)))
                if sens == .normal {
                    for (i, s) in segs.enumerated() {
                        // "mixed" means the strikes split into two loudness
                        // groups — another court is audible and the count is
                        // not to be trusted. The app hides its counter then.
                        print(String(format: "        #%2d  %@ - %@  (%4.1fs, %2d hits, cheer %.2f, score %.2f)%@",
                                     i + 1, mmss(s.start), mmss(s.end),
                                     s.end - s.start, s.hits, s.cheer ?? 0, s.score ?? 0,
                                     s.countIsUncertain ? "  ⚠ mixed courts" : ""))
                    }
                }
            }
            print("")
        }
    } catch {
        print("ERROR: \(error)")
    }
    sema.signal()
}
sema.wait()
