import AVFoundation
import Speech

/// Speech in a clip turned into timed lines, on the device only.
///
/// `requiresOnDeviceRecognition` is the whole point: PrivacyView says nothing
/// but the court name and the ads leaves the phone. A language whose model is
/// not on the device fails as `unavailable` — it never falls back to Apple's
/// servers.
enum AutoCaptions {
    struct Word: Equatable { var text: String; var start: Double; var end: Double }
    struct Line: Equatable { var text: String; var start: Double; var end: Double }
    enum Failure: Error { case denied, unavailable, nothingHeard, failed }

    /// Words into lines a viewer can read: a new line after a pause, or when
    /// the current one is long in characters or seconds. Each line stays up
    /// until the next begins, or a moment after its last word.
    static func lines(_ words: [Word], joiner: String, maxChars: Int = 26,
                      maxSeconds: Double = 3, pause: Double = 0.7, hold: Double = 0.6) -> [Line] {
        var out: [Line] = []
        var cur: [Word] = []
        func flush() {
            guard let a = cur.first, let b = cur.last else { return }
            out.append(Line(text: cur.map(\.text).joined(separator: joiner), start: a.start, end: b.end + hold))
            cur = []
        }
        for w in words where !w.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let a = cur.first, let b = cur.last {
                let text = (cur.map(\.text) + [w.text]).joined(separator: joiner)
                if w.start - b.end > pause || text.count > maxChars || w.end - a.start > maxSeconds { flush() }
            }
            cur.append(w)
        }
        flush()
        for i in out.indices.dropLast() { out[i].end = min(out[i].end, out[i + 1].start) }
        return out
    }

    /// The installed recognizer for the app's language, in the device's region
    /// when there is a choice ("en" in the UK is en-GB).
    static func locale(for lang: String) -> Locale? {
        let want = lang == "zh-Hans" ? "zh" : lang
        let all = SFSpeechRecognizer.supportedLocales().filter { $0.language.languageCode?.identifier == want }
        let region = Locale.current.region?.identifier
        return all.first { $0.region?.identifier == region }
            ?? all.first { lang == "zh-Hans" ? $0.identifier.hasPrefix("zh-CN") || $0.identifier.hasPrefix("zh_CN") : true }
    }

    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    /// Every word heard in `file`, with seconds from the file's start.
    static func transcribe(_ file: URL, locale: Locale) async throws -> [Word] {
        guard await authorize() else { throw Failure.denied }
        guard let rec = SFSpeechRecognizer(locale: locale), rec.supportsOnDeviceRecognition
        else { throw Failure.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let box = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[Word], Error>) in
                box.task = rec.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let words = result.bestTranscription.segments.map {
                            Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                        }
                        box.finish { words.isEmpty ? c.resume(throwing: Failure.nothingHeard) : c.resume(returning: words) }
                    } else if let error {
                        // "No speech detected" is not a failure of the feature;
                        // 1101 is the on-device service without its language
                        // assets (always so in the simulator).
                        let e = error as NSError
                        let assistant = e.domain == "kAFAssistantErrorDomain"
                        #if DEBUG
                        print("[captions] \(e.domain) \(e.code) \(e.localizedDescription)")
                        #endif
                        box.finish {
                            c.resume(throwing: assistant && [1110, 203].contains(e.code) ? Failure.nothingHeard
                                     : assistant && e.code == 1101 ? Failure.unavailable : Failure.failed)
                        }
                    }
                }
            }
        } onCancel: { box.task?.cancel() }
    }

    /// The sound of `asset` from `from` to `to`, written to a temporary file.
    static func soundFile(of asset: AVAsset, from: Double, to: Double) async throws -> URL {
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { throw Failure.nothingHeard }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).m4a")
        session.outputURL = url
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                        end: CMTime(seconds: to, preferredTimescale: 600))
        nonisolated(unsafe) let s = session
        await withCheckedContinuation { c in s.exportAsynchronously { c.resume() } }
        guard s.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.failed
        }
        return url
    }

    /// Resumes a continuation once: the recognizer can report an error after
    /// its final result.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var task: SFSpeechRecognitionTask?
        func finish(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }

    #if DEBUG
    static func selfCheck() {
        let w = { (t: String, a: Double, b: Double) in Word(text: t, start: a, end: b) }
        let ls = lines([w("Watch", 0, 0.3), w("this", 0.35, 0.6), w("forehand", 0.65, 1.1),
                        w("down", 2.5, 2.7), w("the", 2.75, 2.85), w("line", 2.9, 3.2)], joiner: " ")
        assert(ls.map(\.text) == ["Watch this forehand", "down the line"], "\(ls)")
        assert(abs(ls[0].end - 1.7) < 1e-9 && ls[1].start == 2.5 && abs(ls[1].end - 3.8) < 1e-9, "\(ls)")
        // A long run splits on length, and a line never overlaps the next.
        let long = lines((0..<12).map { w("word\($0)", Double($0) * 0.3, Double($0) * 0.3 + 0.25) }, joiner: " ")
        assert(long.count > 1 && long.allSatisfy { $0.text.count <= 26 })
        assert(zip(long, long.dropFirst()).allSatisfy { $0.end <= $1.start })
        assert(lines([], joiner: " ").isEmpty)
        assert(lines([w("ナイス", 0, 0.4), w("ショット", 0.4, 0.9)], joiner: "")[0].text == "ナイスショット")
    }
    #endif
}
