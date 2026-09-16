import AVFoundation
import PryntTrimmerView
import SwiftUI
import UIKit

/// The thumbnail strip with draggable in and out handles.
///
/// `TrimmerView` reads and writes time in the time base of whatever asset it is
/// handed, and a rally is a few seconds inside a match that can run half an
/// hour. Handed the original, every thumbnail would be a different point of the
/// match and a handle would move minutes per pixel, so it is handed a short
/// window cut out around the rally instead (`TrimSheet.window`). `origin` is
/// the source time of that window's first frame: window seconds + origin =
/// source seconds, and that conversion is the only thing this wrapper owes the
/// rest of the app.
struct TrimmerBar: UIViewRepresentable {
    let asset: AVAsset
    /// Source time of the window's first frame.
    let origin: Double
    /// Length of the window, in seconds.
    let duration: Double
    /// In and out points, in source seconds.
    @Binding var start: Double
    @Binding var end: Double
    let minDuration: Double
    /// Detected strike times, in source seconds, drawn over the thumbnails.
    let hits: [Double]
    let enabled: Bool
    /// Source time to preview while a handle is moving.
    let onScrub: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TrimStrip {
        let host = TrimStrip()
        host.trimmer.delegate = context.coordinator
        host.trimmer.mainColor = UIColor(Theme.accent)
        host.trimmer.handleColor = UIColor(Theme.onAccent)
        host.trimmer.positionBarColor = .white
        // The package draws this at 0.7 alpha over everything outside the
        // selection. White is its default and would brighten those parts on the
        // app's dark sheet, which reads as the selected part instead.
        host.trimmer.maskColor = UIColor(Theme.background)
        host.trimmer.minDuration = minDuration
        context.coordinator.host = host
        push(host)
        return host
    }

    func updateUIView(_ host: TrimStrip, context: Context) {
        // The coordinator answers UIKit callbacks with whatever bindings it was
        // built with; refresh them or a drag writes into a stale sheet.
        context.coordinator.parent = self
        push(host)
    }

    private func push(_ host: TrimStrip) {
        host.isUserInteractionEnabled = enabled
        host.alpha = enabled ? 1 : 0.4
        host.ticks.marks = hits.compactMap {
            let f = (($0 - origin) / max(duration, 0.001))
            return f >= 0 && f <= 1 ? CGFloat(f) : nil
        }
        host.load(asset: asset, window: duration)
        host.select(start: start - origin, end: end - origin)
    }

    // MARK: - Delegate

    final class Coordinator: NSObject, TrimmerViewDelegate {
        var parent: TrimmerBar
        weak var host: TrimStrip?

        init(_ parent: TrimmerBar) { self.parent = parent }

        func didChangePositionBar(_ playerTime: CMTime) { read(playerTime) }
        func positionBarStoppedMoving(_ playerTime: CMTime) { read(playerTime) }

        /// The delegate only reports the position bar, which the trimmer parks
        /// on whichever handle is moving — so one callback carries both the new
        /// selection, read back off the view, and the frame worth previewing.
        private func read(_ playerTime: CMTime) {
            guard let trimmer = host?.trimmer,
                  let s = trimmer.startTime?.seconds, let e = trimmer.endTime?.seconds,
                  s.isFinite, e.isFinite else { return }
            // Only real movement is written back: an unconditional write would
            // bounce against the values `push` sends the other way.
            let newStart = parent.origin + s, newEnd = parent.origin + e
            if abs(newStart - parent.start) > 0.02 { parent.start = newStart }
            if abs(newEnd - parent.end) > 0.02 { parent.end = newEnd }
            let t = playerTime.seconds
            if t.isFinite { parent.onScrub(parent.origin + t) }
        }
    }
}

/// Hosts the trimmer so the strip can be laid out by hand.
///
/// Two things can only happen once the view has a size, and `TrimmerView` is
/// `public`, not `open`, so it cannot be subclassed to catch them: thumbnails
/// are generated from the view's height (at zero height the package logs
/// "Could not calculate the thumbnail size" and draws an empty strip), and a
/// selection can only be placed once there is a width to place it in.
final class TrimStrip: UIView {
    let trimmer = TrimmerView()
    let ticks = TickView()

    /// The trimmer's own handle width. It is private and fixed at 15 in 4.0.2;
    /// the strip of thumbnails is inset by it on both sides.
    private static let handleWidth: CGFloat = 15

    private var pendingAsset: AVAsset?
    private var builtFor = CGSize.zero
    private var windowSeconds: Double = 1
    private var wanted: (start: Double, end: Double)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        backgroundColor = .clear
        trimmer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trimmer)
        NSLayoutConstraint.activate([
            trimmer.leftAnchor.constraint(equalTo: leftAnchor),
            trimmer.rightAnchor.constraint(equalTo: rightAnchor),
            trimmer.topAnchor.constraint(equalTo: topAnchor),
            trimmer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        ticks.isUserInteractionEnabled = false
        ticks.backgroundColor = .clear
        ticks.isOpaque = false
        // The trimmer parks itself at zPosition 1, so the marks have to sit
        // above that or the mask views cover them.
        ticks.layer.zPosition = 2
        addSubview(ticks)
    }

    func load(asset: AVAsset, window: Double) {
        windowSeconds = max(window, 0.1)
        guard pendingAsset !== asset else { return }
        pendingAsset = asset
        builtFor = .zero
        setNeedsLayout()
    }

    func select(start: Double, end: Double) {
        wanted = (start, end)
        place()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = TrimStrip.handleWidth
        ticks.frame = CGRect(x: inset, y: bounds.height - 10,
                             width: max(bounds.width - inset * 2, 0), height: 8)
        applyAsset()
        place()
    }

    /// (Re)generates the thumbnails once the strip has a size, and again when
    /// that size changes — rotation, or the sheet growing at accessibility text
    /// sizes, otherwise leaves the old strip stretched.
    private func applyAsset() {
        guard let asset = pendingAsset, bounds.width > 0, bounds.height > 0,
              builtFor != bounds.size else { return }
        builtFor = bounds.size
        if trimmer.asset === asset {
            trimmer.regenerateThumbnails()
        } else {
            // How many screens wide the strip is, `duration / maxDuration`.
            // The window is short enough to show whole, and a strip that
            // scrolls hides the handle the user is not holding.
            trimmer.maxDuration = windowSeconds
            trimmer.asset = asset      // this resets the handles to the window
            // Assigning the asset generates the thumbnails straight away, at a
            // size taken from the package's own scroll view — which has no
            // height yet on the pass that creates it. The package logs "Could
            // not calculate the thumbnail size", gives up, and never retries,
            // which leaves the handles and the mask drawn over an empty strip.
            // Lay its subviews out, then ask again.
            trimmer.layoutIfNeeded()
            trimmer.regenerateThumbnails()
        }
    }

    /// Puts the handles where the sheet says they are.
    ///
    /// `TrimmerView` publishes `startTime`/`endTime` read-only: 4.0.2 has no
    /// way to set them and the two constraints that would are private. Without
    /// this, Reset, the steppers and "fit to shots" would move the preview and
    /// leave the strip showing the old range. The constraints are found by
    /// shape through plain UIKit, and if a later version stops matching, the
    /// handles simply stay where the user left them.
    private func place() {
        guard let want = wanted,
              let assetSeconds = trimmer.asset?.duration.seconds, assetSeconds > 0,
              let bars = frameConstraints() else { return }
        let width = stripWidth
        guard width > 0 else { return }
        let position = { (t: Double) in CGFloat(min(max(t / assetSeconds, 0), 1)) * width }
        let left = position(want.start)
        let right = min(position(want.end) - width, 0)
        // Half a point of slop: the values read back off a drag are this same
        // geometry inverted, and re-applying them would fight the gesture.
        guard abs(bars.left.constant - left) > 0.5
                || abs(bars.right.constant - right) > 0.5 else { return }
        bars.left.constant = left
        bars.right.constant = right
        trimmer.layoutIfNeeded()
        trimmer.seek(to: CMTime(seconds: want.start, preferredTimescale: 600))
    }

    /// Width of the thumbnail strip in the trimmer's own position space.
    private var stripWidth: CGFloat {
        if let scroll = trimmer.subviews.compactMap({ $0 as? UIScrollView }).first,
           scroll.contentSize.width > 0 {
            return scroll.contentSize.width
        }
        return max(bounds.width - TrimStrip.handleWidth * 2, 0)
    }

    private func frameConstraints() -> (left: NSLayoutConstraint, right: NSLayoutConstraint)? {
        // The selection frame is the only subview that is stroked and takes no
        // touches: the handles take touches, the masks are filled.
        guard let frame = trimmer.subviews.first(where: {
            $0.layer.borderWidth > 0 && !$0.isUserInteractionEnabled
        }) else { return nil }
        var left: NSLayoutConstraint?
        var right: NSLayoutConstraint?
        for c in trimmer.constraints where (c.firstItem as? UIView) === frame
            && (c.secondItem as? UIView) === trimmer {
            if c.firstAttribute == .left, c.secondAttribute == .left { left = c }
            if c.firstAttribute == .right, c.secondAttribute == .right { right = c }
        }
        guard let l = left, let r = right else { return nil }
        return (l, r)
    }
}

/// Small marks over the strip for the strikes the detector heard, so the in and
/// out points can be set against the rally itself rather than against a guess.
final class TickView: UIView {
    var marks: [CGFloat] = [] {
        didSet { if marks != oldValue { setNeedsDisplay() } }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        // White, not the accent: the accent marks what can be pressed and what
        // is selected, and these only say where the shots were. The shadow is
        // what keeps them visible against a bright sky.
        ctx.setShadow(offset: .zero, blur: 2.5, color: UIColor.black.withAlphaComponent(0.9).cgColor)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        for mark in marks {
            let x = min(max(mark, 0), 1) * bounds.width
            ctx.move(to: CGPoint(x: x, y: bounds.height - 1))
            ctx.addLine(to: CGPoint(x: x, y: 1))
        }
        ctx.strokePath()
    }
}
