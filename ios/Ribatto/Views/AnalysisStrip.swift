import SwiftUI
import UIKit

/// A duration as people read it on these screens: "42s" under a minute,
/// "1:55" from there. "114s" beside "Longest 1:55" for the same rally read as
/// two different numbers.
func fmtLen(_ seconds: Double, _ lang: String) -> String {
    seconds < 59.5 ? String(Int(seconds.rounded())) + L.s("sec", lang) : fmtDur(seconds)
}

/// The live part of the session's progress card while a match is analysed:
/// the poster, a loudness strip that fills as the audio is decoded, rallies
/// landing on it once found, one progress bar and a time estimate.
///
/// Testers watching a two-hour import saw a dark screen, "Extracting audio"
/// and an empty bar for minutes, and took it for a hang. Every part of this
/// exists to show that something is happening and roughly how long it takes.
struct AnalysisProgress: View {
    @ObservedObject var feed: AnalysisFeed
    @AppStorage("rc_lang") private var lang = "en"
    let sessionID: UUID
    let stage: ProcessingStage
    let poster: URL
    /// The session's rallies as stored now. Once the detection is committed
    /// they are what the markers show, so a later edit moves them too.
    let liveSegments: [RallySegment]?
    /// A rally marker was tapped; index into the session's rallies.
    let onTapRally: (Int) -> Void

    private var analysing: Bool {
        switch stage {
        case .audio, .detect, .queued: return true
        default: return false
        }
    }

    var body: some View {
        if let item = feed.items[sessionID] {
            VStack(alignment: .leading, spacing: 10) {
                // Something to look at besides the bar: the match itself.
                if analysing {
                    Color.clear
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxHeight: 150)
                        .overlay { PosterImage(url: poster) }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                AnalysisStrip(feed: feed, sessionID: sessionID, item: item,
                              compact: !analysing, liveSegments: liveSegments,
                              stageText: stageText, onTapRally: onTapRally)
                if analysing && item.phase != .found {
                    ProgressView(value: item.overall)
                        .tint(Theme.accent)
                        .accessibilityHidden(true)
                    if let eta = item.eta {
                        EtaText(seconds: eta)
                    }
                }
            }
        }
    }

    private var stageText: String {
        switch stage {
        case .detect: return L.s("stage_detect", lang)
        case .render: return L.s("stage_render", lang)
        default: return L.s("stage_audio", lang)
        }
    }
}

/// "About 4 min left", or "Almost done" inside the last minute.
struct EtaText: View {
    @AppStorage("rc_lang") private var lang = "en"
    let seconds: Double

    var body: some View {
        Text(seconds < 60 ? L.s("eta_soon", lang)
                          : String(format: L.s("eta_min_fmt", lang),
                                   Int((seconds / 60).rounded(.up))))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Time left in a render, from the average time per finished clip. Starts
/// counting at the first clip it sees finish, so a screen opened mid-render
/// does not divide the whole elapsed time by the clips done since.
struct RenderEta: View {
    let done: Int
    let total: Int
    @State private var start: (date: Date, done: Int)?
    @State private var eta: Double?

    var body: some View {
        Group {
            if let eta { EtaText(seconds: eta) }
        }
        .onAppear { if start == nil { start = (Date(), done) } }
        .onChange(of: done) { _, now in
            guard let start, now > start.done, total > now else { eta = nil; return }
            let per = Date().timeIntervalSince(start.date) / Double(now - start.done)
            let raw = per * Double(total - now)
            eta = eta.map { $0 * 0.6 + raw * 0.4 } ?? raw
        }
    }
}

/// Thin loudness bars over the length of the match, a playhead while it is
/// read, and translucent rally ranges that arrive one by one when found.
struct AnalysisStrip: View {
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let feed: AnalysisFeed
    let sessionID: UUID
    let item: AnalysisFeed.Item
    /// During the render, where it is a map rather than the show: one line
    /// and a 28pt strip.
    let compact: Bool
    let liveSegments: [RallySegment]?
    let stageText: String
    let onTapRally: (Int) -> Void

    @State private var width: CGFloat = 0

    /// The committed rallies when there are any, else the fresh detection.
    /// A staged re-detect keeps its own: the session still holds the old ones.
    private var rallies: [RallySegment] {
        guard item.rallies != nil else { return [] }
        if !item.staged, let liveSegments { return liveSegments }
        return item.rallies ?? []
    }

    /// Markers open clips only when they are the session's rallies.
    private var tappable: Bool { item.rallies != nil && !item.staged }

    private var shown: Int { min(item.revealed, rallies.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.rallies != nil {
                if compact {
                    // Count and legend on one line, so the card stays small
                    // while the clips are made.
                    (Text(String(format: L.s("rallies_found_fmt", lang), shown))
                        .bold().monospacedDigit()
                     + Text(tappable ? "  ·  " + L.s("strip_legend", lang) : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(format: L.s("rallies_found_fmt", lang), shown))
                        .font(.subheadline.bold().monospacedDigit())
                        .contentTransition(.numericText())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Canvas { ctx, size in draw(in: &ctx, size: size) }
                .frame(height: compact ? 28 : 64)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap(at: $0.location) }, including: .all)
                .background(GeometryReader { g in
                    Color.clear.preference(key: StripWidth.self, value: g.size.width)
                })
                .onPreferenceChange(StripWidth.self) { width = $0 }
            if !compact && tappable && shown > 0 {
                // What the green ranges are, and that they can be pressed.
                (Text(Image(systemName: "square.fill")).foregroundColor(Theme.accent.opacity(0.6))
                 + Text(" " + L.s("strip_legend", lang)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // One element for VoiceOver: the bars mean nothing read aloud. The
        // label and value say what they show; each rally is an action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stageText + (item.rallies != nil
            ? ", " + String(format: L.s("rallies_found_fmt", lang), rallies.count) : ""))
        .accessibilityValue(String(format: L.s("strip_ax_fmt", lang),
                                   Int(item.overall * 100), rallies.count))
        .accessibilityActions {
            if tappable {
                ForEach(Array(rallies.prefix(shown).enumerated()), id: \.offset) { i, seg in
                    Button("#\(i + 1) · " + fmtTs(seg.start)) { onTapRally(i) }
                }
            }
        }
        .task(id: rallies.count) { await reveal() }
    }

    private struct StripWidth: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let n = CGFloat(AudioLoader.envelopeBuckets)
        let step = size.width / n
        // Square root, against the loudest so far: a racket strike and a
        // quiet changeover both stay visible on a linear scale they don't.
        let peak = max(item.envelope.max() ?? 0, 1e-6)
        let mid = size.height / 2
        // The not-yet-read part as a faint baseline, so the strip reads as a
        // whole match being filled in.
        ctx.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                 with: .color(.white.opacity(0.15)))
        for (i, v) in item.envelope.enumerated() {
            let h = max(1.5, CGFloat((v / peak).squareRoot()) * size.height * 0.9)
            let rect = CGRect(x: CGFloat(i) * step, y: mid - h / 2,
                              width: max(1, step * 0.6), height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 0.5),
                     with: .color(.white.opacity(0.55)))
        }
        // Accent only where a marker can be pressed; a staged re-detect's
        // rallies are shown but cannot open anything yet.
        let marker: Color = tappable ? Theme.accent.opacity(0.4) : .white.opacity(0.22)
        for seg in rallies.prefix(shown) {
            let x0 = CGFloat(seg.start / item.duration) * size.width
            let x1 = CGFloat(seg.end / item.duration) * size.width
            let rect = CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(marker))
        }
        if item.phase == .audio {
            let x = CGFloat(item.audioFraction) * size.width
            ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)),
                     with: .color(.white))
        }
    }

    /// Nearest rally within a finger's width. A ten-second rally in a two-hour
    /// match is under a point wide, so hitting the range itself is hopeless.
    private func tap(at point: CGPoint) {
        guard tappable, width > 0, shown > 0 else { return }
        let t = Double(point.x / width) * item.duration
        let slack = Double(16 / width) * item.duration
        let best = rallies.prefix(shown).enumerated().min { a, b in
            distance(t, a.element) < distance(t, b.element)
        }
        guard let best, distance(t, best.element) <= slack else { return }
        onTapRally(best.offset)
    }

    private func distance(_ t: Double, _ s: RallySegment) -> Double {
        t < s.start ? s.start - t : (t > s.end ? t - s.end : 0)
    }

    /// One by one with a light tap each, over at most about two seconds —
    /// the moment the waiting pays off. All at once under Reduce Motion, and
    /// without haptics when the app is not in front.
    private func reveal() async {
        let total = rallies.count
        guard item.revealed < total else { return }
        if reduceMotion {
            feed.reveal(sessionID, count: total)
            return
        }
        let interval = min(0.15, 1.8 / Double(max(total, 1)))
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.prepare()
        var lastHaptic = Date.distantPast
        var count = item.revealed
        while count < total {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            count += 1
            withAnimation(.easeOut(duration: 0.2)) { feed.reveal(sessionID, count: count) }
            if scenePhase == .active, Date().timeIntervalSince(lastHaptic) >= 0.08 {
                haptic.impactOccurred(intensity: 0.6)
                lastHaptic = Date()
            }
        }
    }
}
