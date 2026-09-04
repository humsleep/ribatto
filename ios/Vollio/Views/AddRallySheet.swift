import AVKit
import SwiftUI

/// Adds a rally the detector missed.
///
/// The detector is audio-only, so an indoor court, a windy day or a soft touch
/// at the net can lose a point entirely — and one missed point costs trust in
/// every other clip. This scrubs the original and adds a segment by hand, at
/// which point it is an ordinary rally: trimmable, taggable, in the reel.
struct AddRallySheet: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    let session: Session

    @State private var player: AVPlayer?
    @State private var centre: Double = 0
    @State private var length: Double = 12
    @State private var working = false
    @State private var failed = false

    /// Kept inside the source, and never shorter than a clip is allowed to be.
    private var start: Double { max(0, min(centre - length / 2, session.duration - length)) }
    private var end: Double { min(session.duration, start + length) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(OutputFrame(session.sourceOrientation).aspectRatio,
                                     contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(spacing: 14) {
                    row(L.s("target_frame", lang), value: $centre,
                        range: 0...max(1, session.duration), text: fmtTs(centre))
                    row(L.s("length", lang), value: $length,
                        range: store.minClipSeconds...40, text: fmtDur(length))
                    HStack {
                        Text(fmtTs(start)).font(.caption.monospacedDigit())
                        Spacer()
                        Text("→").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(fmtTs(end)).font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(Theme.accent)
                }
                .padding(14)
                .rcCard()

                Text(L.s("add_rally_d", lang))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if working {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(L.s("add_rally", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.s("cancel", lang)) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.s("add_rally", lang)) { add() }
                        .font(.subheadline.bold())
                        .disabled(working)
                }
            }
            .alert(L.s("import_failed", lang), isPresented: $failed) {
                Button("OK", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func row(_ title: String, value: Binding<Double>,
                     range: ClosedRange<Double>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.subheadline.monospacedDigit().bold())
            }
            Slider(value: value, in: range) { editing in
                if !editing { seek() }
            }
            .tint(Theme.accent)
        }
    }

    private func load() async {
        guard let asset = await store.loadAsset(session) else { return }
        centre = min(session.duration / 2, max(0, session.duration - length))
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        seek()
    }

    /// Preview from the start of the proposed rally, which is what the user is
    /// actually judging.
    private func seek() {
        player?.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func add() {
        working = true
        Task {
            let ok = await store.addRally(to: session, start: start, end: end)
            working = false
            if ok { dismiss() } else { failed = true }
        }
    }
}
