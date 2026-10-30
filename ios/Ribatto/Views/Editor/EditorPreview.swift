import AVFoundation
import SwiftUI
import UIKit

/// The clip as it will come out: the output shape, fill, grade and zoom from
/// the composition, and the watermark and text as the encoder's own pixels.
/// Text is dragged and pinched in place; with the Zoom tool open the same
/// gestures move the framing instead.
struct EditorPreview: View {
    @ObservedObject var m: EditorModel
    @AppStorage("rc_lang") private var lang = "en"
    @State private var dragBase: (x: Double, y: Double)?
    @State private var sizeBase: Double?
    @State private var keyBase: ZoomKey?
    @State private var snapped = false

    var body: some View {
        GeometryReader { geo in
            let box = fitted(in: geo.size)
            ZStack {
                PlayerLayer(player: m.player)
                if let wm = m.watermarkImage {
                    Image(decorative: wm, scale: 1).resizable().allowsHitTesting(false)
                }
                // Where Instagram's and Shorts' own buttons and captions sit,
                // while text is being placed: text there is hidden once posted.
                if m.tool == .text && m.frame == .vertical { safeZone }
                ForEach(visibleSubtitles) { sub in subtitle(sub, in: box) }
                if snapped {
                    Rectangle().fill(.white.opacity(0.6)).frame(width: 1)
                        .allowsHitTesting(false)
                }
                if m.tool == .zoom || m.zoomNow > 1.01 {
                    zoomBadge.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(10).allowsHitTesting(false)
                }
            }
            .frame(width: box.width, height: box.height)
            .background(Theme.letterbox)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .gesture(zoomPan(box), including: m.tool == .zoom ? .all : .subviews)
            .simultaneousGesture(zoomPinch, including: m.tool == .zoom ? .all : .subviews)
            .onTapGesture {
                if m.tool != .zoom { m.selection = nil }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func fitted(in size: CGSize) -> CGSize {
        let a = m.frame.aspectRatio
        return size.width / size.height > a
            ? CGSize(width: size.height * a, height: size.height)
            : CGSize(width: size.width, height: size.width / a)
    }

    /// Lines showing at the playhead, and the selected one always, so it can
    /// be placed while the playhead sits elsewhere.
    private var visibleSubtitles: [Subtitle] {
        m.draft.subtitles.filter { sub in
            (m.time >= sub.start && m.time < sub.end) || m.selection == .subtitle(sub.id)
        }
    }

    @ViewBuilder private func subtitle(_ sub: Subtitle, in box: CGSize) -> some View {
        if let (image, r) = m.captionLayer(sub), let i = m.draft.subtitles.firstIndex(where: { $0.id == sub.id }) {
            let selected = m.selection == .subtitle(sub.id)
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: r.width * box.width, height: r.height * box.height)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white, lineWidth: 1.5)
                            .padding(-4)
                    }
                }
                .position(x: r.midX * box.width, y: r.midY * box.height)
                .gesture(textDrag(i, box), including: m.tool == .zoom ? .none : .all)
                .simultaneousGesture(textPinch(i), including: m.tool == .zoom ? .none : .all)
                .onTapGesture {
                    if selected { m.tool = .text } else { m.selection = .subtitle(sub.id); m.tool = .text }
                }
                .accessibilityLabel(sub.caption.text)
                .accessibilityAddTraits(.isButton)
        }
    }

    private func textDrag(_ i: Int, _ box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard m.draft.subtitles.indices.contains(i) else { return }
                m.pause()
                m.selection = .subtitle(m.draft.subtitles[i].id)
                let base = dragBase ?? (m.draft.subtitles[i].caption.x, m.draft.subtitles[i].caption.y)
                dragBase = base
                var x = min(max(base.x + v.translation.width / box.width, 0.04), 0.96)
                let y = min(max(base.y + v.translation.height / box.height, 0.04), 0.96)
                // Centred is where most text wants to be; it clicks into place.
                let near = abs(x - 0.5) < 0.02
                if near { x = 0.5 }
                if near != snapped {
                    snapped = near
                    if near { UISelectionFeedbackGenerator().selectionChanged() }
                }
                m.draft.subtitles[i].caption.x = x
                m.draft.subtitles[i].caption.y = y
            }
            .onEnded { _ in dragBase = nil; snapped = false; m.checkpoint() }
    }

    private func textPinch(_ i: Int) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                guard m.draft.subtitles.indices.contains(i) else { return }
                let base = sizeBase ?? m.draft.subtitles[i].caption.size
                sizeBase = base
                m.draft.subtitles[i].caption.size = min(max(base * v.magnification, 0.6), 1.8)
            }
            .onEnded { _ in sizeBase = nil; m.checkpoint() }
    }

    /// Drag moves what stays in view: the content follows the finger.
    private func zoomPan(_ box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                m.pause()
                let i = keyIndex()
                let base = keyBase ?? m.draft.zoomKeys[i]
                keyBase = base
                let z = max(base.zoom, 1)
                m.draft.zoomKeys[i].x = min(max(base.x - v.translation.width / box.width / z, 0), 1)
                m.draft.zoomKeys[i].y = min(max(base.y - v.translation.height / box.height / z, 0), 1)
            }
            .onEnded { _ in keyBase = nil; m.checkpoint() }
    }

    private var zoomPinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                m.pause()
                let i = keyIndex()
                let base = keyBase ?? m.draft.zoomKeys[i]
                keyBase = base
                m.draft.zoomKeys[i].zoom = min(max(base.zoom * v.magnification, 1), 3)
            }
            .onEnded { _ in keyBase = nil; m.checkpoint() }
    }

    private func keyIndex() -> Int {
        if case .key(let id) = m.selection, let i = m.draft.zoomKeys.firstIndex(where: { $0.id == id }),
           abs(m.draft.zoomKeys[i].time - m.time) < 0.1 { return i }
        return m.keyAtPlayhead()
    }

    /// Typical bands, not measured per app: top 14%, bottom 25%, right 13%.
    private var safeZone: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let band = Color.black.opacity(0.35)
            ZStack(alignment: .topLeading) {
                band.frame(width: w, height: h * 0.14)
                band.frame(width: w, height: h * 0.25).offset(y: h * 0.75)
                band.frame(width: w * 0.13, height: h * 0.61).offset(x: w * 0.87, y: h * 0.14)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var zoomBadge: some View {
        Text(String(format: "%.1f×", m.zoomNow))
            .font(.footnote.monospacedDigit().weight(.semibold))
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

/// The player's layer, aspect-fit. The composition already renders the
/// output shape, so it fills the box exactly.
struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: LayerView, context: Context) {}

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
