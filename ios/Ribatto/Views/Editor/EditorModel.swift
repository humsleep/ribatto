import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision
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
    var spans: [SpeedSpan] = []
    var replay: Double?
    var marks: [Mark] = []
    var voice: AudioClip?
    var images: [ImageLayer] = []
}

enum EditorTool: String, CaseIterable, Identifiable {
    case fx, text, trim, frame, speed, look, zoom, sound, background, split
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .fx: return "wand.and.stars"
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
        case .fx: return "edit_fx"
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

enum EditorSelection: Equatable { case subtitle(UUID), key(UUID), span(UUID), mark(UUID), image(UUID) }

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
            if draft.speed != oldValue.speed || draft.look.volume != oldValue.look.volume
                || draft.spans != oldValue.spans { applyPlayback() }
            if draft.voice?.file != oldValue.voice?.file { loadVoice() }
            else if let v = draft.voice { voicePlayer?.volume = Float(v.volume) }
        }
    }
    @Published private(set) var recording = false
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
    private var markCache: [String: CGImage] = [:]
    // Playback of the clip's own clock: a hold in progress, the replay, and
    // the last source time a tick saw, so a hold is taken once as it passes.
    private var holding = false
    private var replaying = false
    private var lastTick = 0.0
    private var holdTask: Task<Void, Never>?
    // The added sound: its player, the recorder, and the files this editing
    // session made, removed on the way out unless the clip kept one.
    private var voicePlayer: AVAudioPlayer?
    private var recorder: AVAudioRecorder?
    private var recordedAt = 0.0
    private var folder: URL?
    private var madeFiles: [String] = []
    /// Files the stored clip points at, which leaving must not remove.
    private var kept: Set<String> = []
    private var pictures: [String: UIImage] = [:]
    @Published private(set) var cutting = false
    @Published private(set) var captioning = false
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
                          frame: seg.frame, spans: seg.spans ?? [], replay: seg.replay,
                          marks: seg.marks ?? [], voice: seg.voice, images: seg.images ?? [])
        original = d
        draft = d
        checkpointed = d
        time = seg.start
        params.set(d.look, d.zoomKeys, out: outSize, blur: blurFill)
    }

    var changed: Bool { draft != original }
    /// Something other than the look is waiting to be saved.
    var changedBeyondLook: Bool {
        var d = draft
        d.look = original.look
        return d != original
    }
    /// The clip's own clock, as the encoder will build it.
    var map: TimeMap {
        TimeMap(start: draft.start, end: draft.end, speed: draft.speed,
                spans: draft.spans, replay: draft.replay)
    }
    var duration: Double { map.duration }
    /// Output seconds since the clip's in point, for the timecode and ruler.
    func clock(_ t: Double) -> Double { map.out(at: min(max(t, draft.start), draft.end)) }

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
        folder = store.dir(session)
        kept = clip.segment.mediaFiles
        sweep(session)
        loadVoice()
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
        pause()
        if recording { recorder?.stop(); recording = false; quietSession() }
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        // Sound recorded or imported here that the clip did not keep.
        for file in madeFiles where !kept.contains(file) {
            if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
        }
        madeFiles = []
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
        return ClipExporter.looked(image.cropped(to: CGRect(origin: .zero, size: out)), look)
    }

    /// Plays the source the way the clip's clock says: each stretch at its
    /// rate, a hold as a pause, and the replay as a jump back at half speed.
    private func tick(_ t: Double) {
        guard playing, !holding, t.isFinite else { return }
        let map = self.map
        if replaying {
            if let i = map.replayIndex, t < map.pieces[i].to - 0.02 { time = t } else { restart() }
            return
        }
        if t >= draft.end - 0.02 {
            if let i = map.replayIndex {
                let p = map.pieces[i]
                replaying = true
                player.isMuted = true
                seek(p.from, exact: true)
                time = p.from
                player.rate = Float(p.rate)
            } else {
                restart()
            }
            return
        }
        if let hold = draft.spans.first(where: { $0.hold != nil && $0.start > lastTick && $0.start <= t }) {
            holding = true
            player.pause()
            seek(hold.start, exact: true)
            time = hold.start
            lastTick = hold.start
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(hold.hold ?? 1))
                guard let self, !Task.isCancelled, self.playing else { return }
                self.holding = false
                self.player.rate = self.rate(at: hold.start + 0.001)
            }
            return
        }
        time = t
        lastTick = t
        let r = rate(at: t)
        if abs(player.rate - r) > 0.01 { player.rate = r }
    }

    /// The rate the source plays at around `t`.
    private func rate(at t: Double) -> Float {
        let map = self.map
        let piece = map.pieces.enumerated().first { i, p in
            i != map.replayIndex && !p.isFreeze && t >= p.from && t < p.to
        }
        return Float(piece?.element.rate ?? draft.speed)
    }

    private func restart() {
        replaying = false
        player.isMuted = recording
        seek(draft.start, exact: true)
        time = draft.start
        lastTick = draft.start
        player.rate = rate(at: draft.start)
        syncVoice()
    }

    func togglePlay() { playing ? pause() : play() }

    func play() {
        if time >= draft.end - 0.05 || time < draft.start { scrub(to: draft.start, exact: true) }
        playing = true
        holding = false
        replaying = false
        lastTick = time
        player.rate = rate(at: time)
        syncVoice()
    }

    func pause() {
        playing = false
        holdTask?.cancel()
        holding = false
        if replaying { replaying = false; player.isMuted = false }
        player.pause()
        voicePlayer?.pause()
    }

    private func applyPlayback() {
        player.volume = Float(draft.look.volume)
        if playing, !holding, !replaying { player.rate = rate(at: time) }
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
        markCache.removeAll()
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
        add(Subtitle(start: t, end: min(t + 2, draft.end), caption: c))
    }

    /// A name on a bar, low on the left, for the whole clip.
    func addNameTag(placeholder: String) {
        var c = CaptionEditorView.fresh(for: frame)
        c.enabled = true
        c.text = placeholder
        c.style = .bar
        c.color = .white
        c.x = 0.3
        c.y = frame.isPortrait ? 0.66 : 0.8
        add(Subtitle(start: draft.start, end: draft.end, caption: c, anim: .slide))
    }

    /// One emoji, large, popping in at the playhead.
    func addSticker(_ emoji: String) {
        var c = CaptionEditorView.fresh(for: frame)
        c.enabled = true
        c.text = emoji
        c.style = .plain
        c.size = 2.4
        c.x = 0.5
        c.y = 0.3
        let t = min(max(time, draft.start), draft.end - 0.5)
        add(Subtitle(start: t, end: min(t + 2, draft.end), caption: c, anim: .pop))
    }

    private func add(_ sub: Subtitle) {
        pause()
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
        case .span(let id):
            // A hold takes the ring it was made with along.
            if let s = draft.spans.first(where: { $0.id == id }), s.hold != nil {
                draft.marks.removeAll { abs($0.start - s.start) < 0.001 }
            }
            draft.spans.removeAll { $0.id == id }
        case .mark(let id): draft.marks.removeAll { $0.id == id }
        case .image(let id): draft.images.removeAll { $0.id == id }
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

    // MARK: - Effects

    /// The pixels of a ring or arrow at preview size, and its frame as a
    /// share of the picture (top-left origin).
    func markLayer(_ mark: Mark) -> (CGImage, CGRect)? {
        var centred = mark
        centred.x = 0.5; centred.y = 0.5
        let key = "\(mark.kind.rawValue)-\(mark.size)"
        let cg: CGImage
        if let hit = markCache[key] { cg = hit } else {
            guard let image = ClipExporter.markImage(centred, in: outSize),
                  let made = context.createCGImage(image, from: image.extent) else { return nil }
            markCache[key] = made
            cg = made
        }
        let w = CGFloat(cg.width) / outSize.width, h = CGFloat(cg.height) / outSize.height
        return (cg, CGRect(x: mark.x - w / 2, y: mark.y - h / 2, width: w, height: h))
    }

    var selectedSpan: Int? {
        guard case .span(let id) = selection else { return nil }
        return draft.spans.firstIndex { $0.id == id }
    }

    var selectedMark: Int? {
        guard case .mark(let id) = selection else { return nil }
        return draft.marks.firstIndex { $0.id == id }
    }

    /// The strike the presets aim at: the one nearest the playhead inside the
    /// clip, or the playhead itself when the detector heard none.
    var anchor: Double {
        hits.filter { $0 >= draft.start && $0 <= draft.end }
            .min { abs($0 - time) < abs($1 - time) } ?? min(max(time, draft.start), draft.end)
    }

    private func inClip(_ t: Double) -> Double { min(max(t, draft.start), draft.end) }

    /// Pushes in on the strike and eases back out.
    func addPunchIn() {
        pause()
        let h = anchor
        let times = [h - 0.6, h - 0.1, h + 0.9, h + 1.5].map(inClip)
        draft.zoomKeys.removeAll { $0.time >= times[0] - 0.05 && $0.time <= times[3] + 0.05 }
        let keys = zip(times, [1.0, 1.6, 1.6, 1.0]).map { ZoomKey(time: $0, zoom: $1) }
        draft.zoomKeys = (draft.zoomKeys + keys).sorted { $0.time < $1.time }
        selection = .key(keys[1].id)
        checkpoint()
        scrub(to: keys[1].time, exact: true)
    }

    /// Half speed across the strike.
    func addSlowMo() {
        pause()
        let h = anchor
        let span = SpeedSpan(start: inClip(h - 0.5), end: inClip(h + 0.7), rate: 0.5)
        guard span.end - span.start > 0.2 else { return }
        draft.spans.removeAll { $0.hold == nil && $0.start < span.end && $0.end > span.start }
        draft.spans.append(span)
        selection = .span(span.id)
        checkpoint()
        scrub(to: span.start, exact: true)
    }

    /// Holds the frame at the playhead with a ring to drag onto the ball.
    func addFreeze() {
        pause()
        let t = min(max(time, draft.start + 0.05), draft.end - 0.05)
        guard !draft.spans.contains(where: { $0.hold != nil && abs($0.start - t) < 0.1 }) else { return }
        let span = SpeedSpan(start: t, end: t, hold: 1.5)
        let mark = Mark(start: t, end: t + 0.05)
        draft.spans.append(span)
        draft.marks.append(mark)
        selection = .mark(mark.id)
        checkpoint()
        scrub(to: t, exact: true)
    }

    /// The last strike again at half speed, after the clip.
    func toggleReplay() {
        pause()
        if draft.replay != nil { draft.replay = nil } else {
            draft.replay = hits.filter { $0 >= draft.start && $0 <= draft.end }.max()
                ?? max(draft.start, draft.end - 1)
        }
        checkpoint()
    }

    // MARK: - Added sound

    private func loadVoice() {
        voicePlayer?.stop()
        voicePlayer = nil
        guard let voice = draft.voice, let folder else { return }
        voicePlayer = try? AVAudioPlayer(contentsOf: folder.appendingPathComponent(voice.file))
        voicePlayer?.volume = Float(voice.volume)
        voicePlayer?.prepareToPlay()
    }

    /// Starts the added sound where the playhead is in the finished clip.
    private func syncVoice() {
        guard let voice = draft.voice, let p = voicePlayer, playing, !recording else { return }
        p.volume = Float(voice.volume)
        let offset = clock(time) - (voice.start >= draft.start ? clock(voice.start)
                                                               : voice.start - draft.start)
        p.stop()
        if offset >= 0 {
            guard offset < p.duration else { return }
            p.currentTime = offset
            p.play()
        } else {
            p.currentTime = 0
            p.play(atTime: p.deviceCurrentTime + -offset)
        }
    }

    /// Records from the playhead while the clip plays muted. False when the
    /// microphone is not allowed.
    func startRecording() async -> Bool {
        guard let folder, await AVAudioApplication.requestRecordPermission() else { return false }
        pause()
        let name = "audio/voice-\(UUID().uuidString.prefix(8)).m4a"
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            let r = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
            ])
            guard r.record() else { quietSession(); return false }
            recorder = r
        } catch {
            quietSession()
            return false
        }
        madeFiles.append(name)
        if time >= draft.end - 0.3 || time < draft.start { scrub(to: draft.start, exact: true) }
        recordedAt = time
        recording = true
        player.isMuted = true
        play()
        // The take ends with the clip.
        return true
    }

    func stopRecording() {
        guard recording, let r = recorder else { return }
        let seconds = r.currentTime
        r.stop()
        recorder = nil
        recording = false
        pause()
        player.isMuted = false
        quietSession()
        guard seconds > 0.3, let name = madeFiles.last else { return }
        draft.voice = AudioClip(file: name, start: recordedAt)
        checkpoint()
    }

    private func quietSession() {
        try? AVAudioSession.sharedInstance().setCategory(.soloAmbient)
    }

    /// Copies a sound file the user picked into the session and lays it over
    /// the clip from its in point.
    func importAudio(_ url: URL) -> Bool {
        guard let folder else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let name = "audio/sound-\(UUID().uuidString.prefix(8)).\(ext)"
        let dest = folder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil,
              (try? AVAudioPlayer(contentsOf: dest)) != nil else {
            try? FileManager.default.removeItem(at: dest)
            return false
        }
        pause()
        madeFiles.append(name)
        draft.voice = AudioClip(file: name, start: draft.start, volume: 0.8)
        checkpoint()
        return true
    }

    // MARK: - Pictures

    /// Sound and pictures no rally points at: left when the app was killed
    /// with an editor open, before `stop` could tidy up.
    private func sweep(_ session: Session) {
        guard let folder else { return }
        let used = (session.segments ?? []).reduce(into: Set<String>()) { $0.formUnion($1.mediaFiles) }
        let fm = FileManager.default
        for sub in ["audio", "images"] {
            for name in (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(sub).path)) ?? []
            where !used.contains(sub + "/" + name) {
                try? fm.removeItem(at: folder.appendingPathComponent(sub + "/" + name))
            }
        }
    }

    private var draftFiles: Set<String> {
        var s = RallySegment(start: 0, end: 0, hits: 0)
        s.voice = draft.voice
        s.images = draft.images
        return s.mediaFiles
    }

    var selectedImage: Int? {
        guard case .image(let id) = selection else { return nil }
        return draft.images.firstIndex { $0.id == id }
    }

    /// The picture as the preview draws it.
    func picture(_ file: String) -> UIImage? {
        if let hit = pictures[file] { return hit }
        guard let folder, let image = UIImage(contentsOfFile: folder.appendingPathComponent(file).path)
        else { return nil }
        pictures[file] = image
        return image
    }

    /// Saves a picked photo into the session, no larger than 1024 px on its
    /// long side, and lays it over the whole clip.
    func addPicture(_ data: Data) -> Bool {
        guard let folder, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary),
              let name = save(cg, in: folder) else { return false }
        pause()
        let layer = ImageLayer(file: name, start: draft.start, end: draft.end)
        draft.images.append(layer)
        selection = .image(layer.id)
        checkpoint()
        return true
    }

    private func save(_ image: CGImage, in folder: URL) -> String? {
        let name = "images/pic-\(UUID().uuidString.prefix(8)).png"
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        madeFiles.append(name)
        return name
    }

    /// Cuts the background away from the selected picture, keeping the
    /// subject — or puts the picture back as it was. False when nothing in
    /// the picture stood out to keep.
    func toggleCutout() async -> Bool {
        guard let i = selectedImage, let folder else { return false }
        let layer = draft.images[i]
        if let original = layer.original {
            draft.images[i].file = original
            draft.images[i].original = nil
            checkpoint()
            return true
        }
        cutting = true
        defer { cutting = false }
        let source = folder.appendingPathComponent(layer.file)
        let cut: CGImage? = await Task.detached(priority: .userInitiated) {
            Self.subject(of: source)
        }.value
        guard let cut, let name = save(cut, in: folder),
              let j = draft.images.firstIndex(where: { $0.id == layer.id }) else { return false }
        draft.images[j].original = layer.file
        draft.images[j].file = name
        checkpoint()
        return true
    }

    /// The foreground of a picture on a transparent ground, cropped to it.
    nonisolated private static func subject(of url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) } catch {
            // The simulator has no Neural Engine for this request.
            #if DEBUG
            print("[cutout] \(error)")
            #endif
            return nil
        }
        guard let found = request.results?.first, !found.allInstances.isEmpty,
              let buffer = try? found.generateMaskedImage(ofInstances: found.allInstances, from: handler,
                                                          croppedToInstancesExtent: true)
        else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    // MARK: - Auto captions

    /// Lines from what is said in the clip — the added voice when there is
    /// one, else the match sound — placed on the moments they were said.
    /// Returns how many were added.
    func autoCaptions(lang: String) async throws -> Int {
        guard let locale = AutoCaptions.locale(for: lang) else { throw AutoCaptions.Failure.unavailable }
        pause()
        captioning = true
        defer { captioning = false }
        let words: [AutoCaptions.Word]
        var toSource: (Double) -> Double
        if let voice = draft.voice, let folder {
            words = try await AutoCaptions.transcribe(folder.appendingPathComponent(voice.file), locale: locale)
            // The voice plays at 1× on the finished clip's clock.
            let begins = voice.start >= draft.start ? clock(voice.start) : voice.start - draft.start
            let map = self.map
            toSource = { map.source(at: begins + $0) }
        } else {
            guard let asset else { throw AutoCaptions.Failure.failed }
            let file = try await AutoCaptions.soundFile(of: asset, from: draft.start, to: draft.end)
            defer { try? FileManager.default.removeItem(at: file) }
            words = try await AutoCaptions.transcribe(file, locale: locale)
            let start = draft.start
            toSource = { start + $0 }
        }
        let joiner = ["ja", "zh-Hans"].contains(lang) ? "" : " "
        var style = draft.subtitles.last?.caption ?? CaptionEditorView.fresh(for: frame)
        style.enabled = true
        let added: [Subtitle] = AutoCaptions.lines(words, joiner: joiner).compactMap { line in
            let a = toSource(line.start), b = min(toSource(line.end), draft.end)
            guard a < draft.end - 0.1, b > a else { return nil }
            var c = style
            c.text = line.text
            return Subtitle(start: max(a, draft.start), end: b, caption: c, anim: .fade)
        }
        guard !added.isEmpty else { throw AutoCaptions.Failure.nothingHeard }
        draft.subtitles += added
        selection = nil
        checkpoint()
        return added.count
    }

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

    /// `ownLook: false` leaves the clip's look as it was stored — for "use on
    /// every clip", which sets the match's look right after.
    func commit(_ store: SessionStore, ownLook: Bool = true) async -> Bool {
        let ok = await store.trimClip(
            clip, start: draft.start, end: draft.end, speed: draft.speed,
            edit: ownLook ? clipLook : clip.segment.edit,
            subtitles: draft.subtitles, zoomKeys: draft.zoomKeys,
            // Back to the match's own shape stores nothing.
            frame: .some(draft.frame.flatMap { OutputFrame($0) == matchFrame ? nil : $0 }),
            spans: draft.spans, replay: draft.replay, marks: draft.marks, voice: draft.voice,
            images: draft.images)
        if ok { kept = (clip.segment.mediaFiles).union(draftFiles) }
        return ok
    }

    var canSplit: Bool { time - draft.start >= minClip && draft.end - time >= minClip }
}
