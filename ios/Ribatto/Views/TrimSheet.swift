import AVKit
import SwiftUI

/// Drag the in and out points of one rally.
///
/// Detection pads every rally by a fixed 2 s in front and 3.5 s behind, which
/// is a reasonable guess and wrong often enough to matter: a long celebration
/// gets cut off, a slow serve leaves dead air at the front. This edits the
/// segment directly and re-encodes only this one clip.
struct TrimSheet: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    let clip: ClipInfo

    /// Seconds of headroom the handles may reach outside the detected rally,
    /// so a clipped celebration can be recovered.
    private let slack = 4.0
    /// How much one tap of a stepper moves a handle.
    private let step = 0.25

    @State private var start: Double
    @State private var end: Double
    @State private var player: AVPlayer?
    @State private var working = false
    @State private var message: String?
    @State private var splitAt: Double
    @State private var speed: Double
    /// Just the reachable window of the original, for the thumbnail strip.
    @State private var windowAsset: AVAsset?
    /// The original could not be opened (deleted from Photos). Without this
    /// the strip spun forever and Apply went on to fail.
    @State private var sourceMissing = false
    /// The strip could not be cut (window failed). Without this the spinner
    /// never stopped; the steppers below still trim.
    @State private var stripUnavailable = false

    /// The strip grows with the text size — it is the main control here, not
    /// decoration — but only so far: past this it pushes the buttons off a
    /// small screen for no more detail.
    @ScaledMetric(relativeTo: .body) private var stripHeight = 64

    init(clip: ClipInfo) {
        self.clip = clip
        _start = State(initialValue: clip.segment.start)
        _end = State(initialValue: clip.segment.end)
        _splitAt = State(initialValue: (clip.segment.start + clip.segment.end) / 2)
        _speed = State(initialValue: clip.segment.speed ?? 1)
    }

    private var session: Session? { store.sessions.first { $0.id == clip.sessionID } }
    private var sourceAspect: CGFloat {
        guard let s = session, s.width > 0, s.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(s.width) / CGFloat(s.height)
    }
    private var lower: Double { max(0, clip.segment.start - slack) }
    private var upper: Double {
        min(session?.duration ?? clip.segment.end + slack, clip.segment.end + slack)
    }
    private var changed: Bool {
        abs(start - clip.segment.start) > 0.05 || abs(end - clip.segment.end) > 0.05
            || speed != (clip.segment.speed ?? 1)
    }
    /// The strikes the detector heard, in source seconds. Rallies detected
    /// before these were kept have none, and a trim can leave one outside the
    /// window the handles reach.
    private var hits: [Double] {
        (clip.segment.hitTimes ?? []).filter { $0 >= lower && $0 <= upper }.sorted()
    }

    /// A range that can never be inverted. The handles are interdependent, so
    /// a drag can momentarily ask for a lower bound above the upper one, and
    /// `a...b` traps rather than clamping.
    private func safe(_ a: Double, _ b: Double) -> ClosedRange<Double> {
        a < b ? a...b : a...(a + 0.1)
    }

    private func clampSplit() {
        let lo = start + store.minClipSeconds, hi = end - store.minClipSeconds
        splitAt = lo < hi ? min(max(splitAt, lo), hi) : lo
    }

    /// Scrollable: at the largest accessibility size the fixed stack put
    /// the video off the top and cut "Apply trim" off the bottom, with no
    /// way to reach either.
    private var content: some View {
        VStack(spacing: 16) {
                    // The preview plays the original, so it takes the
                    // original's shape. Boxed at the clip's 9:16 it stood
                    // taller than the screen and pushed every control below
                    // the fold; the height cap keeps a portrait source in view.
                    if let player {
                        VideoPlayer(player: player)
                            .aspectRatio(sourceAspect, contentMode: .fit)
                            .frame(maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if sourceMissing {
                        Label(L.s("source_missing", lang), systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .rcCard()
                    }

                    VStack(spacing: 14) {
                        strip
                        // Ranges are built with `safe`, never `a...b` directly.
                        // Pushing End below Start made the lower bound exceed
                        // the upper one, and Swift traps on that — the app
                        // disappeared mid-edit.
                        nudge(L.s("trim_start", lang), value: $start,
                              range: safe(lower, end - store.minClipSeconds))
                        nudge(L.s("trim_end", lang), value: $end,
                              range: safe(start + store.minClipSeconds, upper))

                        HStack {
                            Text(L.s("length", lang)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            // What the clip will run for, at its speed.
                            Text(fmtDur((end - start) / speed))
                                .font(.subheadline.monospacedDigit().bold())
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(L.s("speed_title", lang)).font(.caption).foregroundStyle(.secondary)
                            Picker(L.s("speed_title", lang), selection: $speed) {
                                Text("0.5×").tag(0.5)
                                Text("1×").tag(1.0)
                                Text("1.5×").tag(1.5)
                                Text("2×").tag(2.0)
                            }
                            .pickerStyle(.segmented)
                            .disabled(working)
                            if speed < 1 {
                                Text(L.s("speed_hint", lang))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !hits.isEmpty {
                            Button { fitToHits() } label: {
                                Label(L.s("trim_fit_hits", lang), systemImage: "arrow.right.and.line.vertical.and.arrow.left")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity, minHeight: 24)
                            }
                            .rcSecondary()
                            .disabled(working)
                        }
                    }
                    .padding(14)
                    .rcCard()

                    // Two points run together by the detector are one clip that
                    // nobody wants to post; cutting it is the other half of trimming.
                    VStack(alignment: .leading, spacing: 10) {
                        handle(L.s("split_rally", lang), value: $splitAt,
                               range: safe(start + store.minClipSeconds,
                                           end - store.minClipSeconds),
                               preview: splitAt)
                        Text(L.s("split_hint", lang))
                            .font(.caption2).foregroundStyle(.secondary)
                        Button {
                            working = true
                            Task {
                                // Apply the trim first when the handles have moved:
                                // `splitRally` reads the stored segment, so a split
                                // taken while a trim was pending cut at a point
                                // outside the range the user could see.
                                if start != clip.segment.start || end != clip.segment.end {
                                    // A trim that did not take must not be
                                    // followed by a split of the untrimmed rally.
                                    guard await store.trimClip(clip, start: start, end: end) else {
                                        working = false
                                        message = L.s(store.isBusy(clip.sessionID)
                                                      ? "busy_wait" : "render_failed", lang)
                                        return
                                    }
                                }
                                let ok = await store.splitRally(clip, at: splitAt)
                                working = false
                                if ok { dismiss() } else { message = L.s("split_failed", lang) }
                            }
                        } label: {
                            Label(L.s("split_rally", lang), systemImage: "scissors")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, minHeight: 24)
                        }
                        .rcSecondary()
                        .disabled(working || sourceMissing || end - start < store.minClipSeconds * 2)
                    }
                    .padding(14)
                    .rcCard()

                    if working {
                        ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                        Text(L.s("trim_rendering", lang))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            // A busy session (usually the previous clip's own
                            // re-render) used to swallow the trim while the
                            // sheet closed as if it had applied.
                            if store.isBusy(clip.sessionID) {
                                message = L.s("busy_wait", lang)
                                return
                            }
                            Task {
                                working = true
                                let ok = await store.trimClip(clip, start: start, end: end,
                                                              speed: speed)
                                working = false
                                if ok { dismiss() } else { message = L.s("render_failed", lang) }
                            }
                        } label: {
                            Label(L.s("trim_apply", lang), systemImage: "scissors")
                                .frame(maxWidth: .infinity)
                        }
                        .rcPrimary()
                        .disabled(!changed || sourceMissing)
                    }
                    Spacer(minLength: 0)
        }
        .padding(16)
    }

    var body: some View {
        NavigationStack {
            ScrollView { content }
            .background(Theme.background.ignoresSafeArea())
            // The split point is only meaningful inside the trimmed range;
            // left alone it kept displaying a time outside it.
            .onChange(of: start) { _, _ in clampSplit() }
            .onChange(of: end) { _, _ in clampSplit() }
            .navigationTitle(L.s("trim_title", lang))
            .alert(message ?? "", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L.s("done", lang))
                        .tint(.secondary)
                        .disabled(working)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.s("reset", lang)) {
                        start = clip.segment.start
                        end = clip.segment.end
                        seek(to: start)
                    }
                    .font(.subheadline)
                    .disabled(!changed || working)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(working)
        .task { await load() }
    }

    // MARK: - Trimmer

    /// Thumbnails of the reachable window with the two handles over them, and
    /// the strikes marked so the rally can be read off the strip.
    @ViewBuilder private var strip: some View {
        let height = min(stripHeight, 104)
        Group {
            if let windowAsset {
                TrimmerBar(asset: windowAsset, origin: lower, duration: upper - lower,
                           start: $start, end: $end,
                           minDuration: store.minClipSeconds,
                           hits: hits, enabled: !working) { seek(to: $0) }
                    // Handles are dragged, which VoiceOver cannot reach at all;
                    // the two steppers below carry the same two values, so the
                    // strip is left out of the accessibility tree rather than
                    // announced as something that cannot be used.
                    .accessibilityHidden(true)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.surfaceHigh)
                    .overlay {
                        if !sourceMissing && !stripUnavailable { ProgressView().tint(Theme.accent) }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)

        if !hits.isEmpty {
            Text(L.s("trim_ticks_hint", lang))
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A hint about a decoration; unbounded it takes a line per word
                // and pushes the buttons off the screen.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }

    /// One value as a stepper. The strip is how a trim is made; this is how it
    /// is made with VoiceOver, where there is no handle to drag, and how to
    /// land on an exact second on a small screen.
    private func nudge(_ title: String, value: Binding<Double>,
                       range: ClosedRange<Double>) -> some View {
        Stepper {
            HStack(spacing: 8) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(fmtPos(value.wrappedValue)).font(.caption.monospacedDigit())
            }
        } onIncrement: {
            move(value, to: value.wrappedValue + step, in: range)
        } onDecrement: {
            move(value, to: value.wrappedValue - step, in: range)
        }
        .disabled(working)
    }

    private func move(_ value: Binding<Double>, to seconds: Double,
                      in range: ClosedRange<Double>) {
        let next = min(max(seconds, range.lowerBound), range.upperBound)
        value.wrappedValue = next
        seek(to: next)
    }

    /// Snap the handles to the rally's own strikes.
    ///
    /// A button rather than a magnet on the handles: 0.3 s is about two points
    /// on this strip, so a magnet would fire on drags that were never aiming
    /// for it, and it would fight the user who is deliberately keeping the
    /// serve toss or the celebration. A button says what it does, and Reset
    /// undoes it.
    private func fitToHits() {
        guard let first = hits.first, let last = hits.last else { return }
        // Lead: the toss and the swing are already in the air before the strike
        // the detector hears. Tail: the ball is still in play after the last
        // one, and the point is won after it lands.
        var from = max(lower, first - 0.7)
        var to = min(upper, last + 1.5)
        if to - from < store.minClipSeconds { to = min(upper, from + store.minClipSeconds) }
        if to - from < store.minClipSeconds { from = max(lower, to - store.minClipSeconds) }
        start = from
        end = to
        seek(to: from)
    }

    /// The split playhead. Scrubbing it seeks the preview to that instant,
    /// which is the only way to judge a cut without playing the whole clip.
    private func handle(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, preview: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(fmtPos(value.wrappedValue))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: value,
                   in: range.lowerBound < range.upperBound ? range
                       : range.lowerBound...(range.lowerBound + 0.1)) { editing in
                if !editing { seek(to: preview) }
            }
            .tint(Theme.accent)
            .accessibilityLabel(title)
            .accessibilityValue(fmtPos(value.wrappedValue))
            .disabled(working)
        }
    }

    // MARK: - Preview

    /// Previews from the ORIGINAL video, not the rendered clip: the handles can
    /// reach outside what the clip contains, and seeking a file that stops at
    /// the old out point would show nothing there.
    private func load() async {
        guard let session, let asset = await store.loadAsset(session) else {
            sourceMissing = true
            return
        }
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        player = p
        seek(to: start)
        windowAsset = await window(from: asset)
        stripUnavailable = windowAsset == nil
    }

    /// The strip's asset: only the window the handles can reach, cut out of the
    /// original. Handed the whole match — half an hour of it — the thumbnails
    /// would be minutes apart and this rally would be thinner than a handle.
    private func window(from asset: AVAsset) async -> AVAsset? {
        guard upper > lower,
              let source = try? await asset.loadTracks(withMediaType: .video).first
        else { return nil }
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let range = CMTimeRange(start: CMTime(seconds: lower, preferredTimescale: 600),
                                duration: CMTime(seconds: upper - lower, preferredTimescale: 600))
        do { try track.insertTimeRange(range, of: source, at: .zero) } catch { return nil }
        // Without this a portrait recording draws its thumbnails on their side:
        // the generator applies the track's transform, and a fresh composition
        // track carries none.
        if let t = try? await source.load(.preferredTransform) { track.preferredTransform = t }
        return comp
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
