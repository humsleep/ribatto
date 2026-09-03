import AVFoundation
import Foundation
import CoreLocation
import Photos
import SwiftUI

/// One clip of one session, derived from disk + metadata.
struct ClipInfo: Identifiable, Equatable {
    let id: String            // "clip_01"
    let index: Int            // 0-based, timeline order
    let url: URL
    let thumbURL: URL
    let segment: RallySegment
    let orientation: String
    let sessionID: UUID
    /// false while the clip is still encoding
    let isReady: Bool
    var duration: Double { segment.end - segment.start }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var progress: [UUID: ProcessingStage] = [:]
    /// Mirrored from PurchaseManager so the export path knows the tier.
    @Published var isPro = false

    private let fm = FileManager.default
    /// Shown when the original has been deleted from Photos.
    var missingSourceMessage = "Original video is no longer available"
    /// Locale used when turning coordinates into a place name.
    var placeLocale = Locale(identifier: "en_US")

    private var root: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("sessions", isDirectory: true)
    }

    init() { load() }

    // MARK: - Paths

    func dir(_ s: Session) -> URL { root.appendingPathComponent(s.id.uuidString) }
    func sourceURL(_ s: Session) -> URL { dir(s).appendingPathComponent("source.mov") }
    func posterURL(_ s: Session) -> URL { dir(s).appendingPathComponent("poster.jpg") }
    func highlightURL(_ s: Session) -> URL { dir(s).appendingPathComponent("highlight.mp4") }
    func clipsDir(_ s: Session) -> URL { dir(s).appendingPathComponent("clips", isDirectory: true) }
    private func metaURL(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("meta.json")
    }

    // MARK: - Persistence

    func load() {
        guard let ids = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        var out: [Session] = []
        for idStr in ids {
            guard let id = UUID(uuidString: idStr),
                  let data = try? Data(contentsOf: metaURL(id)),
                  let s = try? JSONDecoder().decode(Session.self, from: data) else { continue }
            out.append(s)
        }
        sessions = out.sorted { $0.playedAt > $1.playedAt }
    }

    func save(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[i] = s
        }
        try? JSONEncoder().encode(s).write(to: metaURL(s.id))
    }

    /// Read-modify-write against the freshest copy.
    ///
    /// The pipeline used to bind `var s` once and write that same struct back
    /// after several awaits, which silently reverted anything that finished in
    /// the meantime. Reverse geocoding was the visible casualty: the place name
    /// resolved during detection and then vanished the moment the clips
    /// finished. Every write that spans an await goes through here.
    @discardableResult
    private func mutate(_ id: UUID, _ body: (inout Session) -> Void) -> Session? {
        guard var s = sessions.first(where: { $0.id == id }) else { return nil }
        body(&s)
        save(s)
        return s
    }

    func clips(of s: Session) -> [ClipInfo] {
        guard let segments = s.segments else { return [] }
        let cdir = clipsDir(s)
        var out: [ClipInfo] = []
        for (i, seg) in segments.enumerated() {
            let cid = String(format: "clip_%02d", i + 1)
            let url = cdir.appendingPathComponent("\(cid).mp4")
            let thumb = cdir.appendingPathComponent("\(cid).jpg")
            let ready = fm.fileExists(atPath: url.path)
            // a rally with only its poster drawn is still worth showing
            guard ready || fm.fileExists(atPath: thumb.path) else { continue }
            out.append(ClipInfo(id: cid, index: i, url: url, thumbURL: thumb,
                                segment: seg,
                                orientation: s.renderedOrientation ?? "landscape",
                                sessionID: s.id, isReady: ready))
        }
        return out
    }

    func allClips() -> [(session: Session, clip: ClipInfo)] {
        sessions.flatMap { s in clips(of: s).map { (s, $0) } }
    }

    // MARK: - Place

    private func coordinate(assetIdentifier: String?,
                            asset: AVAsset) async -> CLLocationCoordinate2D? {
        if let assetIdentifier,
           let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier],
                                             options: nil).firstObject,
           let location = phAsset.location {
            return location.coordinate
        }
        return await PlaceLookup.coordinate(in: asset)
    }

    // MARK: - Capture date

    /// When the match was filmed. Photos knows this exactly; for a file we fall
    /// back to the container's own creation metadata. Both can be absent, in
    /// which case the session keeps showing its import date.
    private func captureDate(assetIdentifier: String?, asset: AVAsset) async -> Date? {
        if let assetIdentifier,
           let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier],
                                             options: nil).firstObject,
           let created = phAsset.creationDate {
            return created
        }
        if let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue) {
            return date
        }
        return nil
    }

    /// Sessions imported before the capture date was read show their import
    /// date; fill the real one in so the library and the season stats agree
    /// with when the user actually played.
    func backfillCaptureDates() {
        for s in sessions where s.capturedAt == nil {
            let id = s.id
            Task { [weak self] in
                guard let self,
                      let session = await MainActor.run(body: { self.sessions.first { $0.id == id } }),
                      let asset = await self.loadAsset(session),
                      let date = await self.captureDate(
                        assetIdentifier: session.assetIdentifier, asset: asset)
                else { return }
                await MainActor.run { self.mutate(id) { $0.capturedAt = date } }
            }
        }
    }

    /// Fills in the readable place name in the background once we have coordinates.
    func resolvePlaceName(for sessionID: UUID) {
        guard let s = sessions.first(where: { $0.id == sessionID }),
              s.placeName == nil,
              let lat = s.latitude, let lon = s.longitude else { return }
        let locale = placeLocale
        Task { [weak self] in
            let name = await PlaceLookup.placeName(
                for: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                locale: locale)
            guard let name, let self else { return }
            await MainActor.run { self.mutate(sessionID) { $0.placeName = name } }
        }
    }

    func setPlaceName(_ s: Session, _ name: String?) {
        var v = s
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        v.placeName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save(v)
    }

    /// Sessions imported without a network connection never got a place name;
    /// try again whenever the library is shown.
    func resolveMissingPlaceNames() {
        for s in sessions where s.placeName == nil && s.latitude != nil {
            resolvePlaceName(for: s.id)
        }
    }

    /// Every place name the library knows about, most used first.
    func knownPlaces() -> [String] {
        let counts = sessions.compactMap(\.placeName)
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    // MARK: - Source

    /// The video this session works from. Sessions imported from Photos hold
    /// only an identifier; recordings and older sessions keep a local copy.
    func loadAsset(_ s: Session) async -> AVAsset? {
        if let id = s.assetIdentifier {
            if let asset = await Self.photoAsset(id) { return asset }
            return nil          // the user deleted it from Photos
        }
        let url = sourceURL(s)
        return fm.fileExists(atPath: url.path) ? AVURLAsset(url: url) : nil
    }

    /// True when the original is gone and nothing can be re-rendered.
    func sourceMissing(_ s: Session) -> Bool {
        if let id = s.assetIdentifier {
            return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count == 0
        }
        return !fm.fileExists(atPath: sourceURL(s).path)
    }

    private static func photoAsset(_ identifier: String) async -> AVAsset? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let phAsset = fetch.firstObject else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true     // pull it back from iCloud if needed
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(
                forVideo: phAsset, options: options) { asset, _, _ in
                cont.resume(returning: asset)
            }
        }
    }

    // MARK: - Import

    /// Registers a video picked from Photos without copying it. Falls back to
    /// taking a copy when the library can't be read. Returns true only when a
    /// session was actually created — the caller spends a free import on that.
    @discardableResult
    func importFromPhotos(identifier: String, fallback: URL?, name: String) async -> Bool {
        let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let canReference = granted == .authorized || granted == .limited
        if canReference, let asset = await Self.photoAsset(identifier) {
            if await register(name: name, assetIdentifier: identifier,
                              asset: asset, localCopy: nil) {
                if let fallback { try? fm.removeItem(at: fallback) }
                return true
            }
            // referencing the library asset failed — fall through to the copy
        }
        if let fallback {
            return await importVideo(from: fallback, name: name)
        }
        return false
    }

    /// Moves a file into the session folder — used for in-app recordings and
    /// when Photos access is unavailable. Returns true when a session was made.
    @discardableResult
    func importVideo(from temp: URL, name: String) async -> Bool {
        await register(name: name, assetIdentifier: nil, asset: nil, localCopy: temp)
    }

    @discardableResult
    private func register(name: String, assetIdentifier: String?,
                          asset: AVAsset?, localCopy: URL?) async -> Bool {
        let id = UUID()
        let sdir = root.appendingPathComponent(id.uuidString)
        do {
            try fm.createDirectory(at: sdir, withIntermediateDirectories: true)
            var source = asset
            if let localCopy {
                let dest = sdir.appendingPathComponent("source.mov")
                try fm.moveItem(at: localCopy, to: dest)
                source = AVURLAsset(url: dest)
            }
            guard let source else { throw NSError(domain: "Vollio", code: 40) }
            let info = try await VideoProbe.probe(
                asset: source, posterURL: sdir.appendingPathComponent("poster.jpg"))
            var s = Session(id: id, name: name, createdAt: Date(),
                            duration: info.duration,
                            width: info.width, height: info.height)
            s.assetIdentifier = assetIdentifier
            s.capturedAt = await captureDate(assetIdentifier: assetIdentifier,
                                             asset: source)
            if let coordinate = await coordinate(assetIdentifier: assetIdentifier,
                                                 asset: source) {
                s.latitude = coordinate.latitude
                s.longitude = coordinate.longitude
            }
            sessions.insert(s, at: 0)
            try? JSONEncoder().encode(s).write(to: metaURL(id))
            resolvePlaceName(for: id)             // needs the network; don't block
            await process(sessionID: id)          // auto-detect on import
            return true
        } catch {
            try? fm.removeItem(at: sdir)
            return false
        }
    }

    func deleteSession(_ s: Session) {
        try? fm.removeItem(at: dir(s))
        sessions.removeAll { $0.id == s.id }
        progress[s.id] = nil
    }

    // MARK: - Settings

    // Changing a setting only records the choice. Nothing is re-processed
    // until the user presses the apply button — picking three settings used to
    // kick off three full re-detects.

    func setSport(_ s: Session, _ sport: Sport) {
        var v = s; v.sport = sport; save(v)
    }
    func setSensitivity(_ s: Session, _ sens: Sensitivity) {
        var v = s; v.sensitivity = sens; save(v)
    }
    func setAspect(_ s: Session, _ aspect: AspectSetting) {
        var v = s; v.aspect = aspect; save(v)
    }
    func setCaption(_ s: Session, _ caption: CaptionSettings) {
        var v = s; v.caption = caption; save(v)
    }
    func setSmartCrop(_ s: Session, _ on: Bool) {
        var v = s; v.smartCrop = on; save(v)
    }
    /// Picking a player only matters through the smart-crop path, so turn that
    /// on with it; clearing the player leaves smart crop as the user had it.
    func setTargetPlayer(_ s: Session, _ target: TargetPlayer?) {
        var v = s
        v.targetPlayer = target
        if target != nil { v.smartCrop = true }
        save(v)
    }

    /// Points ONE clip at a different player, or back at the session's choice
    /// with nil, and re-cuts just that clip.
    ///
    /// Only one clip is re-encoded because only one changed — re-running the
    /// whole session for a single rally is minutes of work to redo seconds of
    /// it.
    func setClipTarget(_ clip: ClipInfo, _ target: TargetPlayer?) async {
        guard let session = sessions.first(where: { $0.id == clip.sessionID }),
              let segments = session.segments,
              clip.index < segments.count,
              progress[session.id] == nil else { return }
        let key = String(clip.index)
        mutate(session.id) {
            var targets = $0.clipTargets ?? [:]
            targets[key] = target                     // nil removes the override
            $0.clipTargets = targets
            $0.hasHighlight = false
        }
        try? fm.removeItem(at: highlightURL(session))
        guard let updated = sessions.first(where: { $0.id == clip.sessionID }),
              updated.renderedSmartCrop == true else { return }

        progress[session.id] = .render(done: clip.index, total: segments.count)
        defer { progress[session.id] = nil }
        guard let source = await loadAsset(updated) else {
            progress[session.id] = .failed(missingSourceMessage)
            return
        }
        let base = String(format: "clip_%02d", clip.index + 1)
        let dir = clipsDir(updated)
        do {
            try await ClipExporter.export(
                source: source, segment: segments[clip.index],
                orientation: updated.renderedOrientation ?? updated.effectiveOrientation,
                pro: updated.renderedPro ?? isPro,
                caption: updated.renderedCaption,
                smartCrop: true,
                clipURL: dir.appendingPathComponent("\(base).mp4"),
                thumbURL: dir.appendingPathComponent("\(base).jpg"),
                targetPlayer: updated.target(forClip: clip.index))
            // Only this clip was re-cut, so only this clip's record moves —
            // leaving the rest of `renderedClipTargets` alone keeps the
            // "settings changed" hint honest about the clips still stale.
            mutate(session.id) {
                var rendered = $0.renderedClipTargets ?? [:]
                rendered[key] = updated.clipTargets?[key]
                $0.renderedClipTargets = rendered
            }
            objectWillChange.send()
        } catch {
            progress[session.id] = .failed(error.localizedDescription)
        }
    }

    /// Applies whatever the user changed: re-detect if the detection inputs
    /// moved, otherwise just re-render at the new aspect.
    func apply(sessionID: UUID) async {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        if s.segments == nil || s.needsRedetect {
            await process(sessionID: sessionID)
        } else if s.needsRerender {
            await render(sessionID: sessionID)
        }
    }

    // MARK: - Pipeline

    func process(sessionID: UUID) async {
        guard let s = sessions.first(where: { $0.id == sessionID }),
              progress[sessionID] == nil else { return }
        do {
            progress[sessionID] = .audio
            guard let source = await loadAsset(s) else {
                progress[sessionID] = .failed(missingSourceMessage)
                return
            }
            let samples = try await AudioLoader.loadMono16k(asset: source)

            progress[sessionID] = .detect
            let sport = s.sport, sens = s.sensitivity, dur = s.duration
            let segments = await Task.detached(priority: .userInitiated) {
                RallyDetector.detect(samples: samples, sampleRate: AudioLoader.sampleRate,
                                     duration: dur, sensitivity: sens, sport: sport)
            }.value
            mutate(sessionID) {
                $0.segments = segments
                $0.detectedSport = sport
                $0.detectedSensitivity = sens
            }
            await render(sessionID: sessionID, alreadyRunning: true)
        } catch {
            progress[sessionID] = .failed(error.localizedDescription)
        }
    }

    func render(sessionID: UUID, alreadyRunning: Bool = false) async {
        guard let s = sessions.first(where: { $0.id == sessionID }),
              let segments = s.segments else { return }
        if !alreadyRunning && progress[sessionID] != nil { return }
        do {
            let cdir = clipsDir(s)
            try? fm.removeItem(at: cdir)
            try fm.createDirectory(at: cdir, withIntermediateDirectories: true)
            // the old reel is built from the clips being replaced — drop it now
            // so the UI can't offer a reel whose file is already gone
            try? fm.removeItem(at: highlightURL(s))
            let orient = s.effectiveOrientation
            let pro = isPro
            let caption = s.caption
            let useSmartCrop = isPro && s.effectiveSmartCrop
            let target = useSmartCrop ? s.targetPlayer : nil
            let perClip = useSmartCrop ? (s.clipTargets ?? [:]) : [:]
            mutate(sessionID) {
                $0.hasHighlight = false
                $0.renderedOrientation = orient
            }
            guard let source = await loadAsset(s) else {
                progress[sessionID] = .failed(missingSourceMessage)
                return
            }
            // 1) posters for every rally (no encoding — takes a moment, not minutes)
            for (i, seg) in segments.enumerated() {
                let base = String(format: "clip_%02d", i + 1)
                try? ClipExporter.writeThumbnail(
                    of: source, at: min(seg.start + 1.0, seg.end),
                    to: cdir.appendingPathComponent("\(base).jpg"))
            }
            objectWillChange.send()

            // 2) the actual clips
            for (i, seg) in segments.enumerated() {
                progress[sessionID] = .render(done: i, total: segments.count)
                let base = String(format: "clip_%02d", i + 1)
                try await ClipExporter.export(
                    source: source, segment: seg, orientation: orient, pro: pro,
                    caption: caption, smartCrop: useSmartCrop,
                    clipURL: cdir.appendingPathComponent("\(base).mp4"),
                    // Replaces the source-aspect placeholder written above with
                    // a poster cut from the finished clip. Without this a
                    // portrait clip kept a 16:9 still, and the card had to
                    // stretch to hold it.
                    thumbURL: cdir.appendingPathComponent("\(base).jpg"),
                    targetPlayer: useSmartCrop ? s.target(forClip: i) : nil)
            }
            mutate(sessionID) {
                $0.renderedOrientation = orient
                $0.renderedPro = pro
                $0.renderedCaption = caption
                $0.renderedSmartCrop = useSmartCrop
                $0.renderedTargetPlayer = target
                $0.renderedClipTargets = perClip
            }
            progress[sessionID] = nil
        } catch {
            progress[sessionID] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Trim

    /// Moves one rally's in/out points and re-renders only that clip.
    ///
    /// Re-rendering the session for a trim would cost minutes to change one
    /// clip, so this writes the segment, drops the reel built from the old cut,
    /// and encodes the single file.
    func trimClip(_ clip: ClipInfo, start: Double, end: Double) async {
        guard let session = sessions.first(where: { $0.id == clip.sessionID }),
              var segments = session.segments,
              clip.index < segments.count,
              end - start >= minClipSeconds,
              progress[session.id] == nil else { return }
        segments[clip.index].start = max(0, start)
        segments[clip.index].end = min(session.duration, end)
        segments[clip.index].trimmed = true
        let segment = segments[clip.index]
        mutate(session.id) {
            $0.segments = segments
            $0.hasHighlight = false
        }
        try? fm.removeItem(at: highlightURL(session))

        progress[session.id] = .render(done: clip.index, total: segments.count)
        defer { progress[session.id] = nil }
        guard let source = await loadAsset(session) else {
            progress[session.id] = .failed(missingSourceMessage)
            return
        }
        let base = String(format: "clip_%02d", clip.index + 1)
        let dir = clipsDir(session)
        do {
            try await ClipExporter.export(
                source: source, segment: segment,
                orientation: session.renderedOrientation ?? session.effectiveOrientation,
                pro: session.renderedPro ?? isPro,
                caption: session.renderedCaption,
                smartCrop: session.renderedSmartCrop ?? false,
                clipURL: dir.appendingPathComponent("\(base).mp4"),
                thumbURL: dir.appendingPathComponent("\(base).jpg"),
                targetPlayer: (session.renderedSmartCrop ?? false)
                    ? session.target(forClip: clip.index) : nil)
            objectWillChange.send()
        } catch {
            progress[session.id] = .failed(error.localizedDescription)
        }
    }

    /// Shortest clip worth making — below this there is no rally to watch,
    /// only a strike and a cut.
    let minClipSeconds = 1.5

    func makeHighlight(sessionID: UUID) async {
        guard let s = sessions.first(where: { $0.id == sessionID }),
              progress[sessionID] == nil else { return }
        let urls = clips(of: s).filter(\.isReady).map(\.url)
        guard !urls.isEmpty else { return }
        do {
            progress[sessionID] = .merge
            try await HighlightMerger.merge(clips: urls, to: highlightURL(s))
            mutate(sessionID) { $0.hasHighlight = true }
            progress[sessionID] = nil
        } catch {
            progress[sessionID] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Batch clip actions

    /// Deletes the given clips and renumbers what remains so clip_NN stays
    /// aligned with the segment list.
    func deleteClips(_ ids: Set<String>, from session: Session) {
        guard var s = sessions.first(where: { $0.id == session.id }),
              let segments = s.segments else { return }
        let cdir = clipsDir(s)
        let doomed = Set(clips(of: s).filter { ids.contains($0.id) }.map(\.index))
        guard !doomed.isEmpty else { return }

        for i in doomed {
            let base = String(format: "clip_%02d", i + 1)
            for ext in ["mp4", "jpg"] {
                try? fm.removeItem(at: cdir.appendingPathComponent("\(base).\(ext)"))
            }
        }

        // survivors keep their order; new index is never greater than the old
        // one, so renaming front-to-back never collides
        let survivors = segments.indices.filter { !doomed.contains($0) }
        for (newIndex, oldIndex) in survivors.enumerated() where newIndex != oldIndex {
            for ext in ["mp4", "jpg"] {
                let from = cdir.appendingPathComponent(String(format: "clip_%02d.%@", oldIndex + 1, ext))
                let to = cdir.appendingPathComponent(String(format: "clip_%02d.%@", newIndex + 1, ext))
                if fm.fileExists(atPath: from.path) {
                    try? fm.removeItem(at: to)
                    try? fm.moveItem(at: from, to: to)
                }
            }
        }

        s.segments = survivors.map { segments[$0] }
        // the reel was built from the old set
        try? fm.removeItem(at: highlightURL(s))
        s.hasHighlight = false
        save(s)
    }

    /// Saves the given clips (or all of them when `ids` is nil) to Photos.
    /// Returns the number saved, or nil if access was denied.
    func saveClipsToPhotos(_ session: Session, ids: Set<String>? = nil) async -> Int? {
        let wanted = clips(of: session).filter { ids == nil || ids!.contains($0.id) }
        let urls = wanted.filter(\.isReady).map(\.url)
        guard !urls.isEmpty else { return 0 }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return nil }
        var saved = 0
        for url in urls {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                saved += 1
            } catch { continue }
        }
        return saved
    }

    /// Pro: joins the chosen clips (in timeline order) into one file.
    func mergeClips(_ ids: Set<String>, in session: Session) async -> URL? {
        let chosen = clips(of: session).filter { ids.contains($0.id) && $0.isReady }
        guard chosen.count >= 2 else { return nil }
        let out = dir(session).appendingPathComponent("merged.mp4")
        progress[session.id] = .merge
        defer { progress[session.id] = nil }
        do {
            try await HighlightMerger.merge(clips: chosen.map(\.url), to: out)
            return out
        } catch {
            progress[session.id] = .failed(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Reels / Shorts

    var reelsDir: URL { root.appendingPathComponent("reels", isDirectory: true) }

    /// Builds one vertical reel out of the given clips, which may come from
    /// different sessions. Each rally is re-rendered from its own original so
    /// the vertical framing is chosen with the whole frame available.
    ///
    /// Returns the finished file and a report of what the platform cap cut.
    func buildReel(from pairs: [(session: Session, clip: ClipInfo)],
                   target: ReelTarget,
                   frame: OutputFrame = .vertical,
                   pace: ReelPace = .full) async -> (url: URL, plan: ReelPlan)? {
        let ordered = pairs.sorted {
            ($0.session.playedAt, $0.clip.segment.start)
                < ($1.session.playedAt, $1.clip.segment.start)
        }
        guard !ordered.isEmpty else { return nil }
        let key = ordered[0].session.id
        guard progress[key] == nil else { return nil }
        progress[key] = .reel(done: 0, total: ordered.count)
        defer { progress[key] = nil }

        // one asset load per session, however many clips it contributes
        var assets: [UUID: AVAsset] = [:]
        var items: [ReelItem] = []
        for pair in ordered {
            let sid = pair.session.id
            if assets[sid] == nil {
                guard let a = await loadAsset(pair.session) else { continue }
                assets[sid] = a
            }
            guard let asset = assets[sid] else { continue }
            let useSmartCrop = isPro && pair.session.smartCropEnabled
            items.append(ReelItem(asset: asset,
                                  segment: pair.clip.segment,
                                  caption: pair.session.caption,
                                  smartCrop: useSmartCrop,
                                  targetPlayer: useSmartCrop
                                      ? pair.session.target(forClip: pair.clip.index) : nil))
        }
        guard !items.isEmpty else {
            progress[key] = .failed(missingSourceMessage)
            return nil
        }

        do {
            try? fm.createDirectory(at: reelsDir, withIntermediateDirectories: true)
            let out = reelsDir.appendingPathComponent(
                "reel_\(target.rawValue)_\(frame.rawValue)_\(pace.rawValue).mp4")
            let plan = try await ReelBuilder.build(
                items: items, target: target, frame: frame, pace: pace,
                pro: isPro, to: out) { [weak self] done, total in
                    self?.progress[key] = .reel(done: done, total: total)
                }
            return (out, plan)
        } catch {
            progress[key] = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Saves a finished reel to Photos so it can be picked up by Instagram or
    /// YouTube, which is the only reliable hand-off iOS offers.
    func saveToPhotos(_ url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return true
        } catch { return false }
    }

    func deleteClip(_ clip: ClipInfo) {
        guard var s = sessions.first(where: { $0.id == clip.sessionID }),
              var segments = s.segments,
              clip.index < segments.count else { return }
        segments.remove(at: clip.index)
        s.segments = segments
        let cdir = clipsDir(s)
        try? fm.removeItem(at: clip.url)
        try? fm.removeItem(at: clip.thumbURL)
        // shift remaining files down so ids stay aligned with segments
        for j in (clip.index + 1)...(segments.count + 1) where j >= 1 {
            for ext in ["mp4", "jpg"] {
                let old = cdir.appendingPathComponent(String(format: "clip_%02d.%@", j + 1, ext))
                let new = cdir.appendingPathComponent(String(format: "clip_%02d.%@", j, ext))
                if fm.fileExists(atPath: old.path) {
                    try? fm.moveItem(at: old, to: new)
                }
            }
        }
        save(s)
    }
}
