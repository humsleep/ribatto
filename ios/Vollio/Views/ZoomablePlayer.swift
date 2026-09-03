import AVFoundation
import SwiftUI
import UIKit

/// Bare `AVPlayerLayer` in a SwiftUI view.
///
/// `VideoPlayer` brings its own controls, and scaling that view for zoom scales
/// the controls with it. Owning the layer keeps the picture zoomable while the
/// controls below stay put at their normal size.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class Host: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: Host, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// Video with pinch-to-zoom, drag-to-pan, and a compact control row.
struct ZoomableVideo: View {
    @AppStorage("rc_lang") private var lang = "en"
    let player: AVPlayer

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero
    @State private var playing = true
    @State private var time: Double = 0
    @State private var duration: Double = 1
    @State private var scrubbing = false
    @State private var observer: Any?
    @State private var showHint = true

    private let maxZoom: CGFloat = 5

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                PlayerLayerView(player: player)
                    .scaleEffect(zoom)
                    .offset(x: pan.width, y: pan.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(zoomGesture(in: geo.size).simultaneously(with: panGesture(in: geo.size)))
                    .onTapGesture(count: 2) { resetZoom() }
                    .overlay(alignment: .top) { zoomBadge }
            }
            controls
        }
        .background(Color.black)
        .onAppear { attach() }
        .onDisappear { detach() }
    }

    // MARK: Gestures

    private func zoomGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                zoom = min(max(committedZoom * v.magnification, 1), maxZoom)
                pan = clamp(committedPan, in: size)
            }
            .onEnded { _ in
                committedZoom = zoom
                if zoom <= 1.01 { resetZoom() } else { committedPan = clamp(pan, in: size) }
            }
    }

    /// Panning is only meaningful once zoomed in, and never far enough to drag
    /// the picture off its own frame.
    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                guard zoom > 1.01 else { return }
                pan = clamp(CGSize(width: committedPan.width + v.translation.width,
                                   height: committedPan.height + v.translation.height),
                            in: size)
            }
            .onEnded { _ in committedPan = pan }
    }

    private func clamp(_ offset: CGSize, in size: CGSize) -> CGSize {
        guard zoom > 1 else { return .zero }
        let slackX = size.width * (zoom - 1) / 2
        let slackY = size.height * (zoom - 1) / 2
        return CGSize(width: min(max(offset.width, -slackX), slackX),
                      height: min(max(offset.height, -slackY), slackY))
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1; committedZoom = 1; pan = .zero; committedPan = .zero
        }
    }

    /// The hint has to sit over the picture, which can be any colour, so it
    /// carries its own backing and gets out of the way on its own.
    @ViewBuilder private var zoomBadge: some View {
        if zoom > 1.01 {
            pill(String(format: "%.1f×", zoom))
        } else if showHint {
            pill(L.s("zoom_hint", lang))
                .transition(.opacity)
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation(.easeOut(duration: 0.4)) { showHint = false }
                }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, 8)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(
                get: { time },
                set: { v in
                    time = v
                    player.seek(to: CMTime(seconds: v, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                }),
                in: 0...max(duration, 0.1),
                onEditingChanged: { scrubbing = $0 })
            .tint(Theme.accent)

            HStack {
                Text(fmtTs(time))
                Spacer()
                Button {
                    playing.toggle()
                    playing ? player.play() : player.pause()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 34)
                }
                .foregroundStyle(Theme.accent)
                Spacer()
                Text(fmtTs(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func attach() {
        if let d = player.currentItem?.asset.duration.seconds, d.isFinite, d > 0 {
            duration = d
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { t in
            guard !scrubbing else { return }
            time = t.seconds
            if duration <= 1,
               let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                duration = d
            }
        }
        player.play()
    }

    private func detach() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
    }
}
