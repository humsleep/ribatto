import Foundation

// Scores the shipping detector (RallyDetector → SoundCheck, the same order
// SessionStore runs) against hand-labelled rallies.
//
//   ./Eval/eval.sh                         every label in Eval/labels
//   ./Eval/eval.sh --json out.json         also write the numbers
//   ./Eval/eval.sh --baseline Eval/baseline.json   exit 1 if any F1 drops > 0.01
//   ./Eval/eval.sh --draft <video> <sport> print a label draft from today's detector
//   ./Eval/eval.sh --selftest
//
// A label rally runs from the serve to the moment the ball is dead. A detection
// is scored by its play span (first strike → last strike + 1 s), not the padded
// clip: 2.0 s + 3.5 s of padding pushes a 4 s rally under IoU 0.5 on its own.
// A detection matches a label when IoU ≥ 0.5, greedily, one to one.

struct Label: Codable {
    var video: String
    var sport: String
    /// Only this stretch of the video is scored (labels need not cover it all).
    var range: [Double]?
    var rallies: [[Double]]
}

struct Score: Codable {
    var tp = 0, fp = 0, fn = 0
    var startErr: [Double] = [], endErr: [Double] = []
    var precision: Double { tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp) }
    var recall: Double { tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn) }
    var f1: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }
    static func + (a: Score, b: Score) -> Score {
        Score(tp: a.tp + b.tp, fp: a.fp + b.fp, fn: a.fn + b.fn,
              startErr: a.startErr + b.startErr, endErr: a.endErr + b.endErr)
    }
}

func iou(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
    let inter = max(0, min(a.1, b.1) - max(a.0, b.0))
    let union = max(a.1, b.1) - min(a.0, b.0)
    return union > 0 ? inter / union : 0
}

func score(detected: [(Double, Double)], truth: [(Double, Double)]) -> Score {
    var pairs: [(Double, Int, Int)] = []
    for (i, d) in detected.enumerated() {
        for (j, t) in truth.enumerated() {
            let v = iou(d, t)
            if v >= 0.5 { pairs.append((v, i, j)) }
        }
    }
    var usedD = Set<Int>(), usedT = Set<Int>(), s = Score()
    for (_, i, j) in pairs.sorted(by: { $0.0 > $1.0 }) where !usedD.contains(i) && !usedT.contains(j) {
        usedD.insert(i); usedT.insert(j); s.tp += 1
        s.startErr.append(abs(detected[i].0 - truth[j].0))
        s.endErr.append(abs(detected[i].1 - truth[j].1))
    }
    s.fp = detected.count - s.tp
    s.fn = truth.count - s.tp
    return s
}

func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func selftest() {
    assert(iou((0, 10), (0, 10)) == 1)
    assert(iou((0, 10), (10, 20)) == 0)
    assert(abs(iou((0, 10), (5, 15)) - 1.0 / 3) < 1e-9)
    // One good match, one false alarm, one miss; the overlap of 1/3 is not a match.
    let s = score(detected: [(0, 10), (20, 30), (50, 60)], truth: [(1, 10), (55, 65), (100, 110)])
    assert(s.tp == 1 && s.fp == 2 && s.fn == 2, "\(s)")
    assert(s.startErr == [1] && s.endErr == [0])
    // One detection cannot claim two labels.
    let t = score(detected: [(0, 20)], truth: [(0, 10), (0, 12)])
    assert(t.tp == 1 && t.fn == 1)
    assert(median([3, 1, 2]) == 2 && median([1, 2, 3, 4]) == 2.5)
    print("selftest ok")
}

/// Decoded audio is cached by path, size and date so tuning runs skip the decode.
func samples(for url: URL) async throws -> [Float] {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs[.size] as? Int) ?? 0
    let date = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    let dir = URL(fileURLWithPath: ".build/eval-cache")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let cache = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(size)-\(date).f32")
    if let data = try? Data(contentsOf: cache) {
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    let s = try await AudioLoader.loadMono16k(url: url)
    try s.withUnsafeBufferPointer { try Data(buffer: $0).write(to: cache) }
    return s
}

func expand(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

/// Runs exactly what SessionStore runs at import (normal sensitivity is the default).
func detect(_ s: [Float], duration: Double, sport: Sport) -> (segs: [RallySegment], soundCheck: Bool) {
    let found = RallyDetector.detect(samples: s, sampleRate: AudioLoader.sampleRate,
                                     duration: duration, sensitivity: .normal, sport: sport)
    guard let v = SoundCheck.classify(samples: s, sampleRate: AudioLoader.sampleRate, segments: found)
    else { return (found, false) }
    return (SoundCheck.apply(v, to: found), true)
}

/// The play inside a detected clip — what labels and drafts mark.
func play(_ seg: RallySegment) -> (Double, Double) {
    ((seg.hitTimes?.first ?? seg.start), (seg.hitTimes?.last).map { $0 + 1 } ?? seg.end)
}

func fmt(_ x: Double) -> String { x.isNaN ? "  -  " : String(format: "%.2f", x) }

struct Report: Codable {
    var videos: [String: Double]   // name → F1
    var sports: [String: Double]
    var overall: Double
}

func run(jsonOut: String?, baseline: String?) async throws -> Bool {
    let dir = URL(fileURLWithPath: "Eval/labels")
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    guard !files.isEmpty else { print("no labels in Eval/labels"); return false }

    var report = Report(videos: [:], sports: [:], overall: 0)
    var bySport: [String: Score] = [:], total = Score()
    print("video                    P     R     F1    start  end   (median s)  s/min  TP FP FN")
    for file in files {
        let name = file.deletingPathExtension().lastPathComponent
        let label = try JSONDecoder().decode(Label.self, from: Data(contentsOf: file))
        guard let sport = Sport(rawValue: label.sport) else { print("\(name): unknown sport"); continue }
        let url = expand(label.video)
        let s = try await samples(for: url)
        let duration = Double(s.count) / Double(AudioLoader.sampleRate)

        let t0 = Date()
        let (segs, checked) = detect(s, duration: duration, sport: sport)
        let perMin = Date().timeIntervalSince(t0) / (duration / 60)

        // Inside the scored range by midpoint, so a rally on the edge counts once.
        let lo = label.range?.first ?? 0, hi = label.range?.last ?? .infinity
        let inRange = { (a: Double, b: Double) in (a + b) / 2 >= lo && (a + b) / 2 < hi }
        let det = segs.map(play).filter(inRange)
        let truth = label.rallies.map { ($0[0], $0[1]) }.filter(inRange)
        let sc = score(detected: det, truth: truth)

        bySport[label.sport] = (bySport[label.sport] ?? Score()) + sc
        total = total + sc
        report.videos[name] = sc.f1
        print(String(format: "%@ %@  %@  %@   %@   %@              %.2f  %2d %2d %2d%@",
                     name.padding(toLength: 22, withPad: " ", startingAt: 0), fmt(sc.precision), fmt(sc.recall), fmt(sc.f1),
                     fmt(median(sc.startErr)), fmt(median(sc.endErr)), perMin,
                     sc.tp, sc.fp, sc.fn, checked ? "" : "  (SoundCheck did not run)"))
    }
    for (sport, sc) in bySport.sorted(by: { $0.key < $1.key }) {
        report.sports[sport] = sc.f1
        print(String(format: "[%@] P %@  R %@  F1 %@", sport, fmt(sc.precision), fmt(sc.recall), fmt(sc.f1)))
    }
    report.overall = total.f1
    print(String(format: "overall  P %@  R %@  F1 %@  start %@  end %@",
                 fmt(total.precision), fmt(total.recall), fmt(total.f1),
                 fmt(median(total.startErr)), fmt(median(total.endErr))))

    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let jsonOut { try enc.encode(report).write(to: URL(fileURLWithPath: jsonOut)) }

    guard let baseline else { return true }
    let base = try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: baseline)))
    var ok = true
    let checks = [("overall", base.overall, report.overall)]
        + base.videos.map { ($0.key, $0.value, report.videos[$0.key] ?? 0) }
    for (name, was, now) in checks where now < was - 0.01 {
        print(String(format: "REGRESSION %@: F1 %.3f → %.3f", name, was, now)); ok = false
    }
    print(ok ? "baseline ok" : "baseline FAILED")
    return ok
}

func draft(video: String, sport: String) async throws {
    guard let sp = Sport(rawValue: sport) else { print("unknown sport \(sport)"); exit(1) }
    let s = try await samples(for: expand(video))
    let (segs, _) = detect(s, duration: Double(s.count) / Double(AudioLoader.sampleRate), sport: sp)
    let rallies = segs.map(play).map { [($0.0 * 10).rounded() / 10, ($0.1 * 10).rounded() / 10] }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    let out = try enc.encode(Label(video: video, sport: sport, range: nil, rallies: rallies))
    print(String(decoding: out, as: UTF8.self))
}

let args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

if args.first == "--selftest" { selftest(); exit(0) }

let sema = DispatchSemaphore(value: 0)
var code: Int32 = 0
Task {
    do {
        if let i = args.firstIndex(of: "--draft"), i + 2 < args.count {
            try await draft(video: args[i + 1], sport: args[i + 2])
        } else if try await !run(jsonOut: value("--json"), baseline: value("--baseline")) {
            code = 1
        }
    } catch {
        print("ERROR: \(error)"); code = 1
    }
    sema.signal()
}
sema.wait()
exit(code)
