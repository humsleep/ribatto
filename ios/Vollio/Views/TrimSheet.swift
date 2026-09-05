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

    @State private var start: Double
    @State private var end: Double
    @State private var player: AVPlayer?
    @State private var working = false
    @State private var message: String?
    @State private var splitAt: Double

    init(clip: ClipInfo) {
        self.clip = clip
        _start = State(initialValue: clip.segment.start)
        _end = State(initialValue: clip.segment.end)
        _splitAt = State(initialValue: (clip.segment.start + clip.segment.end) / 2)
    }

    private var session: Session? { store.sessions.first { $0.id == clip.sessionID } }
    private var lower: Double { max(0, clip.segment.start - slack) }
    private var upper: Double {
        min(session?.duration ?? clip.segment.end + slack, clip.segment.end + slack)
    }
    private var changed: Bool {
        abs(start - clip.segment.start) > 0.05 || abs(end - clip.segment.end) > 0.05
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(OutputFrame(clip.orientation).aspectRatio,
                                     contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(spacing: 14) {
                    // Ranges are built with `safe`, never `a...b` directly.
                    // Dragging End below Start made the lower bound exceed the
                    // upper one, and Swift traps on that — the app disappeared
                    // mid-drag.
                    handle(L.s("trim_start", lang), value: $start,
                           range: safe(lower, end - store.minClipSeconds),
                           preview: start)
                    handle(L.s("trim_end", lang), value: $end,
                           range: safe(start + store.minClipSeconds, upper),
                           preview: max(start, end - 0.15))

                    HStack {
                        Text(L.s("length", lang)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(fmtDur(end - start))
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(Theme.accent)
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
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button {
                        working = true
                        Task {
                            // Apply the trim first when the handles have moved:
                            // `splitRally` reads the stored segment, so a split
                            // taken while a trim was pending cut at a point
                            // outside the range the user could see.
                            if start != clip.segment.start || end != clip.segment.end {
                                await store.trimClip(clip, start: start, end: end)
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
                    .disabled(working || end - start < store.minClipSeconds * 2)
                }
                .padding(14)
                .rcCard()

                if working {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                    Text(L.s("trim_rendering", lang))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button {
                        Task {
                            working = true
                            await store.trimClip(clip, start: start, end: end)
                            working = false
                            dismiss()
                        }
                    } label: {
                        Label(L.s("trim_apply", lang), systemImage: "scissors")
                            .frame(maxWidth: .infinity)
                    }
                    .rcPrimary()
                    .disabled(!changed)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
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

    /// One handle. Scrubbing it seeks the preview to that instant, which is the
    /// only way to judge an in or out point without playing the whole clip.
    private func handle(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, preview: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(fmtTs(value.wrappedValue))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: value,
                   in: range.lowerBound < range.upperBound ? range
                       : range.lowerBound...(range.lowerBound + 0.1)) { editing in
                if !editing { seek(to: preview) }
            }
            .tint(Theme.accent)
            .disabled(working)
        }
    }

    // MARK: - Preview

    /// Previews from the ORIGINAL video, not the rendered clip: the handles can
    /// reach outside what the clip contains, and seeking a file that stops at
    /// the old out point would show nothing there.
    private func load() async {
        guard let session, let asset = await store.loadAsset(session) else { return }
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        player = p
        seek(to: start)
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
