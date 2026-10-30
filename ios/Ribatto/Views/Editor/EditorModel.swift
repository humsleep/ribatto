import AVFoundation
import CoreImage
import SwiftUI

/// The edit as it stands before Done. One value, so undo is a stack of them.
/// Times are source seconds, as `RallySegment` stores them.
struct EditDraft: Equatable {
    var start: Double
    var end: Double
    var speed: Double
    var look: ClipEdit
    var subtitles: [Subtitle]
    var zoomKeys: [ZoomKey]
    /// This clip's own shape; nil follows the match.
    var frame: String?
}

enum EditorTool: String, CaseIterable, Identifiable {
    case text, trim, frame, speed, look, zoom, sound, background, split
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .text: return "textformat"
        case .trim: return "timeline.selection"
        case .frame: return "aspectratio"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .look: return "camera.filters"
        case .zoom: return "plus.magnifyingglass"
        case .sound: return "speaker.wave.2"
        case .background: return "rectangle.portrait.inset.filled"
        case .split: return "scissors"
        }
    }
    var label: String {
        switch self {
        case .text: return "edit_text"
        case .trim: return "edit_trim"
        case .frame: return "edit_frame"
        case .speed: return "edit_speed"
        case .look: return "edit_look"
        case .zoom: return "edit_zoom"
        case .sound: return "sound_title"
        case .background: return "backdrop_title"
        case .split: return "edit_split"
        }
    }
}

enum EditorSelection: Equatable { case subtitle(UUID), key(UUID) }

/// What the preview's composition handler reads each frame. Written on the
/// main actor and read on the video thread, so a change needs no new
/// composition — only a redraw.
final class PreviewParams: @unchecked Sendable {
    private let lock = NSLock()
    private var look = ClipEdit()
    private var keys: [ZoomKey] = []
    private var out = CGSize(width: 960, height: 540)
    private var blur = false
    func set(_ look: ClipEdit, _ keys: [ZoomKey], out: CGSize, blur: Bool) {
        lock.lock(); self.look = look; self.keys = keys; self.out = out; self.blur = blur; lock.unlock()
    }
    var snapshot: (look: ClipEdit, keys: [ZoomKey], out: CGSize, blur: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (look, keys, out, blur)
    }
}

/// State of the clip editor: the draft, its undo history, the player and the
/// preview. Commits through `SessionStore.trimClip` / `splitRally` only.
@MainActor
final class EditorModel: ObservableObject {
    let clip: ClipInfo
    let matchLook: ClipEdit
    /// The match's shape, which a clip with no frame of its own follows.
    let matchFrame: OutputFrame
    var frame: OutputFrame { draft.frame.map { OutputFrame($0) } ?? matchFrame }
    /// Handles may reach this far outside the detected rally, to recover a
    /// celebration the cut missed.
    let lower: Double, upper: Double
    let hits: [Double]
    let minClip: Double
    private let sourceAspect: CGFloat
    private let smartCrop: Bool
    /// The free vertical frame: the whole picture over a blurred fill.
    var blurFill: Bool { frame.isPortrait && !smartCrop && sourceAspect > frame.aspectRatio + 0.01 }
    /// Pass framing (smart crop, player tracking) is not re-run live.
    var approximateFraming: Bool { frame.isPortrait && smartCrop }
    let watermark: Bool
    /// The preview renders at this size; overlays are drawn in its pixels.
    var outSize: CGSize {
        let r = frame.ratio
        return r.w >= r.h
            ? CGSize(width: 960, height: (960 * r.h / r.w / 2).rounded() * 2)
            : CGSize(width: (960 * r.w / r.h / 2).rounded() * 2, height: 960)
    }
    let original: EditDraft

    @Published var draft: EditDraft {
        didSet {
            if draft.frame != oldValue.frame { reshape() }
            if draft.look != oldValue.look || draft.zoomKeys != oldValue.zoomKeys { pushPreview() }
            if draft.speed != oldValue.speed || draft.look.volume != oldValue.look.volume { applyPlayback() }
        }
    }
    @Published var time: Double
    @Published var playing = false
    @Published var tool: EditorTool?
    @Published var selection: EditorSelection?
    @Published var pxPerSec: CGFloat = 60
    @Published private(set) var undoStack: [EditDraft] = []
    @Published private(set) var redoStack: [EditDraft] = []
    @Published private(set) var thumbs: [CGImage?] = []
    @Published private(set) var lookThumbs: [ClipFilter: CGImage] = [:]
    @Published private(set) var watermarkImage: CGImage?
    @Published var sourceMissing = false
    @Published var ready = false

    let player = AVPlayer()
    private let params = PreviewParams()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var asset: AVAsset?
    private var observer: Any?
    private var checkpointed: EditDraft
    private var seeking = false
    private var pendingSeek: (Double, Bool)?
    private var captionCache: [UUID: (CaptionSettings, CGImage, CGRect)] = [:]
    static let thumbCount = 24

    init(clip: ClipInfo, session: Session?, minClip: Double) {
        self.clip = clip
        self.minClip = minClip
        let seg = clip.segment
        matchLook = session?.effectiveEdit ?? ClipEdit()
        matchFrame = OutputFrame(session?.renderedOrientation ?? session?.effectiveOrientation ?? clip.orientation)
        lower = max(0, seg.start - 4)
        upper = min(session?.duration ?? seg.end + 4, seg.end + 4)
        hits = (seg.hitTimes ?? []).filter { $0 >= seg.start - 4 && $0 <= seg.end + 4 }.sorted()
        sourceAspect = {
            guard let s = session, s.width > 0, s.height > 0 else { return 16.0 / 9 }
            return CGFloat(s.width) / CGFloat(s.height)
        }()
        smartCrop = session?.renderedSmartCrop ?? false
        watermark = !(session?.renderedPro ?? false)
        let d = EditDraft(start: seg.start, end: seg.end, speed: seg.speed ?? 1,
                          look: seg.edit ?? (session?.effectiveEdit ?? ClipEdit()),
                          subtitles: seg.subtitles ?? [], zoomKeys: seg.zoomKeys ?? [],
                          frame: seg.frame)
        original = d
        draft = d
        checkpointed = d
        time = seg.start
        params.set(d.look, d.zoomKeys, out: outSize, blur: blurFill)
    }

    var changed: Bool { draft != original }
    var duration: Double { (draft.end - draft.start) / draft.speed }
    /// Output seconds since the clip's in point, for the timecode and ruler.
    func clock(_ t: Double) -> Double { max(0, (t - draft.start) / draft.speed) }

    // MARK: - Undo

    /// Called when a gesture or a tap ENDS, so one drag is one undo step.
    func checkpoint() {
        guard draft != checkpointed else { return }
        undoStack.append(checkpointed)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        checkpointed = draft
    }

    func undo() {
        checkpoint()
        guard let last = undoStack.popLast() else { return }
        redoStack.append(draft)
        draft = last
        checkpointed = last
        clampTime()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(draft)
        draft = next
        checkpointed = next
        clampTime()
    }

    // MARK: - Player

    func load(_ store: SessionStore, _ session: Session) async {
        guard let asset = await store.loadAsset(session) else { sourceMissing = true; return }
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        let p = params
        if let comp = try? await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { req in
            let s = p.snapshot
            var image = EditorModel.outputFrame(req.sourceImage, out: s.out, blur: s.blur, look: s.look)
            if let k = ZoomKey.at(req.compositionTime.seconds, in: s.keys) {
                image = ClipExporter.zoomed(image, k)
            }
            req.finish(with: image, context: nil)
        }) {
            comp.renderSize = outSize
            item.videoComposition = comp
        }
        player.replaceCurrentItem(with: item)
        applyPlayback()
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30),
                                                  queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        seek(time, exact: true)
        drawWatermark()
        ready = true
        await makeThumbs(asset)
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    /// Same order as the encoder: shape the frame, fill, grade. Zoom follows.
    nonisolated static func outputFrame(_ source: CIImage, out: CGSize, blur: Bool,
                                        look: ClipEdit) -> CIImage {
        let r = source.extent
        guard r.width > 0, r.height > 0 else { return source }
        var image = source.transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        if blur {
            let s = out.width / r.width
            let fit = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            image = look.backdrop == .black ? ClipExporter.blackFilled(fit, out: out)
                                            : ClipExporter.blurFilled(fit, out: out)
        } else {
            let s = max(out.width / r.width, out.height / r.height)
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: -(r.width * s - out.width) / 2,
                                                   y: -(r.height * s - out.height) / 2))
        }
        return ClipExporter.graded(image, look.filter).cropped(to: CGRect(origin: .zero, size: out))
    }

    private func tick(_ t: Double) {
        guard playing, t.isFinite else { return }
        if t >= draft.end - 0.02 {
            seek(draft.start, exact: true)
            time = draft.start
        } else {
            time = t
        }
    }

    func togglePlay() { playing ? pause() : play() }

    func play() {
        if time >= draft.end - 0.05 || time < draft.start { scrub(to: draft.start, exact: true) }
        playing = true
        player.rate = Float(draft.speed)
    }

    func pause() {
        playing = false
        player.pause()
    }

    private func applyPlayback() {
        player.volume = Float(draft.look.volume)
        if playing { player.rate = Float(draft.speed) }
    }

    /// Moves the playhead. Seeks coalesce: one in flight, the latest wins.
    func scrub(to t: Double, exact: Bool = false) {
        time = min(max(t, lower), upper)
        seek(time, exact: exact)
    }

    /// Shows the frame at `t` without moving the playhead, so a handle being
    /// dragged does not slide the timeline out from under the finger.
    func peek(_ t: Double) { seek(t, exact: false) }

    private func seek(_ t: Double, exact: Bool) {
        if seeking { pendingSeek = (t, exact); return }
        seeking = true
        let tol = exact ? CMTime.zero : CMTime(value: 1, timescale: 10)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if let (next, ex) = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(next, exact: ex)
                }
            }
        }
    }

    private func clampTime() {
        if time < draft.start || time > draft.end { scrub(to: draft.start, exact: true) }
    }

    /// Hands the new look and keys to the composition and redraws a paused frame.
    private func pushPreview(resize: Bool = false) {
        params.set(draft.look, draft.zoomKeys, out: outSize, blur: blurFill)
        guard !playing || resize, let item = player.currentItem,
              let comp = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition else { return }
        comp.renderSize = outSize
        item.videoComposition = comp
    }

    /// A new shape: the preview, the watermark and every text layer are
    /// drawn at the output size, so all of them are made again.
    private func reshape() {
        captionCache.removeAll()
        drawWatermark()
        pushPreview(resize: true)
    }

    private func drawWatermark() {
        let out = outSize
        guard watermark, let wm = ClipExporter.watermarkImage(for: out) else { watermarkImage = nil; return }
        watermarkImage = context.createCGImage(wm, from: CGRect(origin: .zero, size: out))
    }

    // MARK: - Thumbnails

    private func makeThumbs(_ asset: AVAsset) async {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 200)
        let tol = CMTime(value: 3, timescale: 10)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let n = Self.thumbCount, span = upper - lower
        var out = [CGImage?](repeating: nil, count: n)
        thumbs = out
        let times = (0..<n).map { CMTime(seconds: lower + span * (Double($0) + 0.5) / Double(n),
                                         preferredTimescale: 600) }
        for await result in gen.images(for: times) {
            guard let image = try? result.image else { continue }
            let i = Int(((result.requestedTime.seconds - lower) / span * Double(n)).rounded(.down))
            guard out.indices.contains(i) else { continue }
            out[i] = image
            thumbs = out
        }
        // The look chips show the user's own frame in each grade.
        guard let mid = out[n / 2] ?? out.compactMap({ $0 }).first else { return }
        let base = CIImage(cgImage: mid)
        var looks: [ClipFilter: CGImage] = [:]
        for f in ClipFilter.allCases {
            autoreleasepool {
                let graded = ClipExporter.graded(base, f).cropped(to: base.extent)
                looks[f] = context.createCGImage(graded, from: base.extent)
            }
        }
        lookThumbs = looks
    }

    // MARK: - Text

    /// The burned-in pixels of one subtitle at preview size, and where they
    /// sit as a share of the frame (top-left origin).
    func captionLayer(_ sub: Subtitle) -> (CGImage, CGRect)? {
        var c = sub.caption
        c.enabled = true
        if let hit = captionCache[sub.id], hit.0 == c { return (hit.1, hit.2) }
        guard c.isVisible, let image = ClipExporter.captionImage(c, in: outSize),
              let cg = context.createCGImage(image, from: image.extent) else { return nil }
        let e = image.extent
        let rect = CGRect(x: e.minX / outSize.width, y: (outSize.height - e.maxY) / outSize.height,
                          width: e.width / outSize.width, height: e.height / outSize.height)
        captionCache[sub.id] = (c, cg, rect)
        return (cg, rect)
    }

    var selectedSubtitle: Int? {
        guard case .subtitle(let id) = selection else { return nil }
        return draft.subtitles.firstIndex { $0.id == id }
    }

    var selectedKey: Int? {
        guard case .key(let id) = selection else { return nil }
        return draft.zoomKeys.firstIndex { $0.id == id }
    }

    /// A new line at the playhead, two seconds long, styled like the last one.
    func addSubtitle(placeholder: String) {
        var c = draft.subtitles.last?.caption ?? CaptionEditorView.fresh(for: frame)
        c.enabled = true
        c.text = placeholder
        let t = min(max(time, draft.start), draft.end - 0.5)
        let sub = Subtitle(start: t, end: min(t + 2, draft.end), caption: c)
        draft.subtitles.append(sub)
        selection = .subtitle(sub.id)
        checkpoint()
    }

    /// The line under the playhead, if any — tapping Text edits it.
    var subtitleAtPlayhead: Subtitle? {
        draft.subtitles.last { time >= $0.start && time < $0.end }
    }

    func deleteSelection() {
        switch selection {
        case .subtitle(let id): draft.subtitles.removeAll { $0.id == id }
        case .key(let id): draft.zoomKeys.removeAll { $0.id == id }
        case nil: return
        }
        selection = nil
        checkpoint()
    }

    // MARK: - Zoom

    /// The key at the playhead, made from the current framing when there is
    /// none, so a gesture on the preview always has something to move.
    func keyAtPlayhead() -> Int {
        if let i = draft.zoomKeys.firstIndex(where: { abs($0.time - time) < 0.1 }) {
            selection = .key(draft.zoomKeys[i].id)
            return i
        }
        var k = ZoomKey.at(time, in: draft.zoomKeys) ?? ZoomKey(time: time, zoom: 1)
        k.id = UUID()
        k.time = time
        draft.zoomKeys.append(k)
        draft.zoomKeys.sort { $0.time < $1.time }
        selection = .key(k.id)
        return draft.zoomKeys.firstIndex { $0.id == k.id } ?? 0
    }

    /// The framing showing at the playhead, for the badge and the panel.
    var zoomNow: Double { ZoomKey.at(time, in: draft.zoomKeys)?.zoom ?? 1 }

    // MARK: - Trim

    func fitToHits() {
        let inside = hits.filter { $0 >= lower && $0 <= upper }
        guard let first = inside.first, let last = inside.last else { return }
        var from = max(lower, first - 0.7)
        var to = min(upper, last + 1.5)
        if to - from < minClip { to = min(upper, from + minClip) }
        if to - from < minClip { from = max(lower, to - minClip) }
        draft.start = from
        draft.end = to
        checkpoint()
        scrub(to: from, exact: true)
    }

    // MARK: - Commit

    /// What the clip stores for its look: nothing when it matches the match.
    var clipLook: ClipEdit? {
        var mine = draft.look, match = matchLook
        if !frame.isPortrait { mine.backdrop = .blur; match.backdrop = .blur }
        return mine == match ? nil : draft.look
    }

    func commit(_ store: SessionStore) async -> Bool {
        await store.trimClip(clip, start: draft.start, end: draft.end, speed: draft.speed,
                             edit: clipLook, subtitles: draft.subtitles, zoomKeys: draft.zoomKeys,
                             // Back to the match's own shape stores nothing.
                             frame: .some(draft.frame.flatMap { OutputFrame($0) == matchFrame ? nil : $0 }))
    }

    var canSplit: Bool { time - draft.start >= minClip && draft.end - time >= minClip }
}
