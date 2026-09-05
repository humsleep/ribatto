import AVFoundation
import Foundation
import CoreLocation
import Photos
import UIKit
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
    /// Called once a new session exists on disk, so the free allowance is spent
    /// even if processing is interrupted.
    var onSessionRegistered: (() -> Void)?
    /// Called when a detection produced no rallies, so the free import that
    /// paid for it can be returned.
    var onDetectionFoundNothing: (() -> Void)?
    /// Set by the app: suspends until the App Store has said whether this user
    /// owns Pro. A render bakes the tier into the file, so starting one before
    /// the answer lands is how a paying customer gets watermarked 720p clips on
    /// a phone they just restored.
    var awaitEntitlement: (() async -> Void)?

    private let fm = FileManager.default
    /// Shown when iOS stopped a render because the app was in the background
    /// for too long.
    var interruptedMessage = "Processing stopped when the app went to the background. Tap to try again."
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
            // Qualified by session: "clip_01" repeats in every session, and the
            // All Clips tab keys its multi-select on this across all of them —
            // selecting one match's first rally selected every match's first
            // rally, and Delete removed them all.
            let gid = s.id.uuidString + "/" + cid
            let url = cdir.appendingPathComponent("\(cid).mp4")
            let thumb = cdir.appendingPathComponent("\(cid).jpg")
            let ready = fm.fileExists(atPath: url.path)
            // a rally with only its poster drawn is still worth showing
            guard ready || fm.fileExists(atPath: thumb.path) else { continue }
            out.append(ClipInfo(id: gid, index: i, url: url, thumbURL: thumb,
                                segment: seg,
                                orientation: s.renderedOrientation ?? "landscape",
                                sessionID: s.id, isReady: ready))
        }
        return out
    }

    /// Whether any session has a clip on disk, without building the whole
    /// list — it stops at the first one it finds.
    var hasAnyClips: Bool {
        sessions.contains { s in
            guard let segments = s.segments, !segments.isEmpty else { return false }
            let cdir = clipsDir(s)
            for i in segments.indices {
                let cid = String(format: "clip_%02d", i + 1)
                if fm.fileExists(atPath: cdir.appendingPathComponent("\(cid).mp4").path)
                    || fm.fileExists(atPath: cdir.appendingPathComponent("\(cid).jpg").path) {
                    return true
                }
            }
            return false
        }
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
            // Counted here, not after processing: a force-quit mid-detect used
            // to leave the session on disk with the free allowance untouched.
            // `process` hands it back if the video turned out to have no
            // rallies in it — charging for a failed detection is how a new user
            // burns the free tier without ever seeing a clip.
            onSessionRegistered?()
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
    func setShotCounter(_ s: Session, _ on: Bool) {
        var v = s; v.shotCounter = on; save(v)
    }
    func setScoreboard(_ s: Session, _ on: Bool) {
        var v = s; v.scoreboard = on; save(v)
    }
    func setOpponent(_ s: Session, _ name: String) {
        var v = s
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        v.opponent = trimmed.isEmpty ? nil : trimmed
        save(v)
    }

    /// Who won one rally. Tagging changes the score on every rally after it,
    /// which is why the whole session is marked for a re-render rather than
    /// just this clip.
    func setWinner(_ clip: ClipInfo, _ winner: PointWinner?) {
        guard let s = sessions.first(where: { $0.id == clip.sessionID }),
              var segments = s.segments, clip.index < segments.count else { return }
        segments[clip.index].winner = winner
        mutate(s.id) { $0.segments = segments }
    }

    /// Starring is a library affordance, not an export setting: it must never
    /// mark the session as needing a re-render.
    func toggleFavourite(_ clip: ClipInfo) {
        guard let s = sessions.first(where: { $0.id == clip.sessionID }),
              var segments = s.segments, clip.index < segments.count else { return }
        segments[clip.index].favourite = !(segments[clip.index].favourite ?? false)
        mutate(s.id) { $0.segments = segments }
    }

    /// A rally the detector missed, added by hand. Rallies stay in timeline
    /// order, so this renumbers everything after it — which is also why the
    /// clip files are rebuilt rather than patched.
    @discardableResult
    func addRally(to session: Session, start: Double, end: Double) async -> Bool {
        guard !isBusy(session.id), end - start >= minClipSeconds,
              let live = sessions.first(where: { $0.id == session.id })
        else { return false }
        // The sheet was handed a snapshot; anything written while it was open
        // would be lost if we edited that copy.
        var segments = live.segments ?? []
        let seg = RallySegment(start: max(0, start),
                               end: min(session.duration, end),
                               hits: 0, score: nil, trimmed: true)
        let at = segments.firstIndex { $0.start > seg.start } ?? segments.count
        segments.insert(seg, at: at)
        mutate(session.id) {
            $0.segments = segments
            $0.hasHighlight = false
            // indices moved, so per-clip overrides no longer point at the
            // clips they were chosen for
            $0.clipTargets = shift($0.clipTargets, insertedAt: at)
            $0.renderedClipTargets = nil
        }
        try? fm.removeItem(at: highlightURL(session))
        await render(sessionID: session.id)
        return true
    }

    /// Cuts one rally in two at `at` seconds — for the point the detector ran
    /// together with the next one.
    @discardableResult
    func splitRally(_ clip: ClipInfo, at time: Double) async -> Bool {
        guard let session = sessions.first(where: { $0.id == clip.sessionID }),
              var segments = session.segments, clip.index < segments.count,
              !isBusy(session.id) else { return false }
        let seg = segments[clip.index]
        guard time - seg.start >= minClipSeconds,
              seg.end - time >= minClipSeconds else { return false }
        // Strikes and the crowd reaction belong to whichever half they land in;
        // the score is no longer meaningful for either, so both are unscored.
        let firstHits = (seg.hitTimes ?? []).filter { $0 < time }
        let secondHits = (seg.hitTimes ?? []).filter { $0 >= time }
        let first = RallySegment(start: seg.start, end: time,
                                 hits: firstHits.isEmpty ? seg.hits / 2 : firstHits.count,
                                 score: nil, trimmed: true,
                                 hitTimes: seg.hitTimes == nil ? nil : firstHits)
        var second = RallySegment(start: time, end: seg.end,
                                  hits: secondHits.isEmpty ? seg.hits - seg.hits / 2 : secondHits.count,
                                  score: nil, trimmed: true,
                                  hitTimes: seg.hitTimes == nil ? nil : secondHits,
                                  cheer: seg.cheer)
        // Both tags describe the point the user was looking at, and that point
        // is the one that ends where the original ended — the second half.
        // Splitting them across the two halves put the winner on a point the
        // user never judged.
        second.winner = seg.winner
        second.favourite = seg.favourite
        segments.replaceSubrange(clip.index...clip.index, with: [first, second])
        mutate(session.id) {
            $0.segments = segments
            $0.hasHighlight = false
            $0.clipTargets = shift($0.clipTargets, insertedAt: clip.index + 1)
            $0.renderedClipTargets = nil
        }
        try? fm.removeItem(at: highlightURL(session))
        await render(sessionID: session.id)
        return true
    }

    /// Moves per-clip overrides up by one from `insertedAt`, so they stay with
    /// the rally the user picked them for.
    private func shift(_ targets: [String: TargetPlayer]?,
                       insertedAt: Int) -> [String: TargetPlayer]? {
        guard let targets, !targets.isEmpty else { return targets }
        var out: [String: TargetPlayer] = [:]
        for (key, value) in targets {
            guard let i = Int(key) else { continue }
            out[String(i >= insertedAt ? i + 1 : i)] = value
        }
        return out
    }
    /// The burned-in score for one clip, matching what the last full render
    /// used. Every path that re-encodes a single clip has to pass this or the
    /// clip silently comes back without the scoreboard.
    private func scoreboardLine(_ s: Session, segments: [RallySegment], at index: Int) -> String? {
        guard s.renderedScoreboard ?? false else { return nil }
        return TennisScore.line(for: segments, sport: s.sport, lang: lang)[safe: index]
    }

    /// Rebuilds per-clip overrides after a delete: `survivors` lists the old
    /// indices that remain, in order, so each override moves to the position
    /// its rally now holds. Without this an override kept its old key and
    /// silently started following the wrong person on a different rally.
    private func remap(_ targets: [String: TargetPlayer]?,
                       survivors: [Int]) -> [String: TargetPlayer]? {
        guard let targets, !targets.isEmpty else { return targets }
        var out: [String: TargetPlayer] = [:]
        for (newIndex, oldIndex) in survivors.enumerated() {
            if let v = targets[String(oldIndex)] { out[String(newIndex)] = v }
        }
        return out
    }

    /// The in-app language, for strings burned into video (the counter's
    /// label, a caption's "Best #1").
    var lang: String { UserDefaults.standard.string(forKey: "rc_lang") ?? "en" }
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
              !isBusy(session.id) else { return }
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
        defer { clearProgressUnlessFailed(session.id) }
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
                caption: CaptionText.resolve(updated.renderedCaption, session: updated,
                                             segments: segments, index: clip.index, lang: lang),
                smartCrop: true,
                clipURL: dir.appendingPathComponent("\(base).mp4"),
                thumbURL: dir.appendingPathComponent("\(base).jpg"),
                targetPlayer: updated.target(forClip: clip.index),
                counter: (updated.renderedShotCounter ?? false)
                    ? ShotCounter.make(for: segments[clip.index],
                                       label: L.s("counter_label", lang)) : nil,
                // Without this the re-cut clip comes back with no score while
                // every other clip in the session still carries one.
                scoreboard: scoreboardLine(updated, segments: segments, at: clip.index))
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
        // Sessions detected before strike times were kept have nothing for the
        // counter to draw; a re-detect fills them in (trims are preserved).
        let lacksHitTimes = isPro && s.shotCounterEnabled
            && (s.segments ?? []).contains { $0.hitTimes == nil }
        // An empty result is not a finished job. Without the isEmpty case,
        // pressing Detect again on a session that found nothing did nothing at
        // all — the settings were unchanged, so neither branch fired and the
        // button looked dead exactly where the user most needs it to work.
        let foundNothing = s.segments?.isEmpty ?? false
        if s.segments == nil || foundNothing || s.needsRedetect || lacksHitTimes {
            await process(sessionID: sessionID)
        } else if s.needsRerender {
            await render(sessionID: sessionID)
        }
    }

    // MARK: - Pipeline

    func process(sessionID: UUID) async {
        guard let s = sessions.first(where: { $0.id == sessionID }),
              !isBusy(sessionID) else { return }
        // A previous failure is a message, not work in flight — clear it so the
        // run that the user just asked for is not blocked by it.
        progress[sessionID] = nil
        let task = beginBackgroundTask()
        defer { endBackgroundTask(task) }
        do {
            progress[sessionID] = .audio
            guard let source = await loadAsset(s) else {
                progress[sessionID] = .failed(missingSourceMessage)
                return
            }
            let sport = s.sport, sens = s.sensitivity, dur = s.duration
            // Scoped so the 16 kHz samples (≈345 MB on a 90-minute recording)
            // are freed before the render, which needs the memory for frames.
            let segments: [RallySegment] = try await {
                let samples = try await AudioLoader.loadMono16k(asset: source)
                progress[sessionID] = .detect
                return await Task.detached(priority: .userInitiated) {
                    RallyDetector.detect(samples: samples, sampleRate: AudioLoader.sampleRate,
                                         duration: dur, sensitivity: sens, sport: sport)
                }.value
            }()
            mutate(sessionID) {
                $0.segments = segments
                $0.detectedSport = sport
                $0.detectedSensitivity = sens
                $0.detectionFoundNothing = segments.isEmpty
            }
            // Nothing found means nothing to show, so the import is handed
            // back. Otherwise two unusable videos cost a new user two thirds of
            // the free tier before they have ever seen a clip.
            // Once per import, not once per detect: `process` also runs from
            // Apply, so refunding here unconditionally handed back an import
            // every time the user pressed Re-detect on a quiet video.
            if segments.isEmpty,
               sessions.first(where: { $0.id == sessionID })?.importRefunded != true {
                mutate(sessionID) { $0.importRefunded = true }
                onDetectionFoundNothing?()
            }
            await render(sessionID: sessionID, alreadyRunning: true)
        } catch {
            // The clips written before the throw are in the new shape while the
            // session still records the old one, which would make one session
            // hold two orientations. The source is in hand, so dropping them is
            // recoverable; leaving them is not.
            try? fm.removeItem(at: clipsDir(s))
            mutate(sessionID) { $0.renderedOrientation = nil }
            progress[sessionID] = .failed(error.localizedDescription)
        }
    }

    /// Work actually in flight. A `.failed` entry is a message left on screen,
    /// so it must not lock the session out of being retried.
    func isBusy(_ id: UUID) -> Bool {
        guard let stage = progress[id] else { return false }
        if case .failed = stage { return false }
        return true
    }

    /// Keeps a multi-minute export alive when the user leaves the app. Without
    /// it the export is killed mid-file and the session lands in `.failed`.
    /// Clears the progress entry unless it holds a failure. A plain
    /// `defer { progress[id] = nil }` wiped the message the same scope had just
    /// set, so every error from trim, re-target, merge and reel-build vanished
    /// before it could be drawn and the button looked like it did nothing.
    private func clearProgressUnlessFailed(_ id: UUID) {
        if case .failed = progress[id] { return }
        progress[id] = nil
    }

    /// How many sessions are actually working, as opposed to holding a failure
    /// message. Drives the idle timer.
    var busyCount: Int { progress.keys.filter { isBusy($0) }.count }

    private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
        // An empty expiration handler is a termination: iOS kills an app that
        // still holds a background task when the window closes, and `render`
        // has already deleted the session's old clips by then. Ending the task
        // in the handler lets the app be suspended normally instead.
        var id: UIBackgroundTaskIdentifier = .invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "VollioRender") {
            [weak self] in
            guard let self else { return }
            // No `.failed` here: the work usually finishes anyway, and the
            // paths that end through `clearProgressUnlessFailed` would then
            // preserve a failure message for a job that succeeded.
            self.endBackgroundTask(id)
            id = .invalid
        }
        return id
    }
    private func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }

    func render(sessionID: UUID, alreadyRunning: Bool = false) async {
        guard let s = sessions.first(where: { $0.id == sessionID }),
              let segments = s.segments else { return }
        if !alreadyRunning && isBusy(sessionID) { return }
        if !alreadyRunning { progress[sessionID] = nil }
        let bgTask = alreadyRunning ? UIBackgroundTaskIdentifier.invalid
                                    : beginBackgroundTask()
        defer { endBackgroundTask(bgTask) }
        // The source has to be in hand BEFORE the old clips are deleted: this
        // used to wipe every clip and only then discover the original was gone
        // from Photos, leaving the user with nothing at all.
        progress[sessionID] = .audio
        guard let source = await loadAsset(s) else {
            progress[sessionID] = .failed(missingSourceMessage)
            return
        }
        await awaitEntitlement?()

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
            let counterLabel = isPro && s.shotCounterEnabled ? L.s("counter_label", lang) : nil
            let scores = isPro && s.scoreboardEnabled
                ? TennisScore.line(for: segments, sport: s.sport, lang: lang)
                : []
            let winners = s.winnerTags
            let target = useSmartCrop ? s.targetPlayer : nil
            let perClip = useSmartCrop ? (s.clipTargets ?? [:]) : [:]
            // `renderedOrientation` is the record of a finished render, so it
            // is written only on the success path below. Setting it here made a
            // render that threw halfway look complete: needsRerender went false
            // and Apply then had nothing to do, stranding the session.
            mutate(sessionID) { $0.hasHighlight = false }
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
                    caption: CaptionText.resolve(caption, session: s, segments: segments,
                                                 index: i, lang: lang),
                    smartCrop: useSmartCrop,
                    clipURL: cdir.appendingPathComponent("\(base).mp4"),
                    // Replaces the source-aspect placeholder written above with
                    // a poster cut from the finished clip. Without this a
                    // portrait clip kept a 16:9 still, and the card had to
                    // stretch to hold it.
                    thumbURL: cdir.appendingPathComponent("\(base).jpg"),
                    targetPlayer: useSmartCrop ? s.target(forClip: i) : nil,
                    counter: counterLabel.flatMap { ShotCounter.make(for: seg, label: $0) },
                    scoreboard: i < scores.count ? scores[i] : nil)
            }
            mutate(sessionID) {
                $0.renderedOrientation = orient
                $0.renderedPro = pro
                $0.renderedCaption = caption
                $0.renderedSmartCrop = useSmartCrop
                $0.renderedShotCounter = counterLabel != nil
                $0.renderedScoreboard = !scores.isEmpty
                $0.renderedWinners = winners
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
              !isBusy(session.id) else { return }
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
        defer { clearProgressUnlessFailed(session.id) }
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
                caption: CaptionText.resolve(session.renderedCaption, session: session,
                                             segments: segments, index: clip.index, lang: lang),
                smartCrop: session.renderedSmartCrop ?? false,
                clipURL: dir.appendingPathComponent("\(base).mp4"),
                thumbURL: dir.appendingPathComponent("\(base).jpg"),
                targetPlayer: (session.renderedSmartCrop ?? false)
                    ? session.target(forClip: clip.index) : nil,
                counter: (session.renderedShotCounter ?? false)
                    ? ShotCounter.make(for: segment, label: L.s("counter_label", lang)) : nil,
                scoreboard: scoreboardLine(session, segments: segments, at: clip.index))
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
              !isBusy(sessionID) else { return }
        progress[sessionID] = nil       // clear a leftover .failed
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
    @discardableResult
    func deleteClips(_ ids: Set<String>, from session: Session) -> Bool {
        // A render renumbers the same files; deleting under it leaves clips
        // holding the wrong rally.
        guard !isBusy(session.id),
              var s = sessions.first(where: { $0.id == session.id }),
              let segments = s.segments else { return false }
        let cdir = clipsDir(s)
        let doomed = Set(clips(of: s).filter { ids.contains($0.id) }.map(\.index))
        guard !doomed.isEmpty else { return false }

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
        s.clipTargets = remap(s.clipTargets, survivors: survivors)
        s.renderedClipTargets = remap(s.renderedClipTargets, survivors: survivors)
        // the reel was built from the old set
        try? fm.removeItem(at: highlightURL(s))
        s.hasHighlight = false
        // The user removed these; a later empty screen must not blame detection.
        s.detectionFoundNothing = false
        save(s)
        return true
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
        defer { clearProgressUnlessFailed(session.id) }
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

    /// Finished reels, newest first.
    ///
    /// They used to be written under a name made from the settings, so building
    /// a second reel with the same platform and pace silently overwrote the
    /// first, and nothing in the app ever listed them: the one thing the app
    /// exists to make had no way back to it. Each reel now gets its own id and
    /// a small sidecar describing it.
    func reels() -> [ReelInfo] {
        guard let names = try? fm.contentsOfDirectory(atPath: reelsDir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { name -> ReelInfo? in
                let url = reelsDir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      var info = try? JSONDecoder().decode(ReelInfo.self, from: data)
                else { return nil }
                info.url = reelsDir.appendingPathComponent(info.id + ".mp4")
                info.thumbURL = reelsDir.appendingPathComponent(info.id + ".jpg")
                guard fm.fileExists(atPath: info.url.path) else { return nil }
                info.bytes = (try? fm.attributesOfItem(atPath: info.url.path)[.size] as? Int64)
                    .flatMap { $0 } ?? 0
                return info
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Bytes the finished reels take up, for the line that tells the user why
    /// their storage is filling.
    func reelsBytes() -> Int64 { reels().reduce(0) { $0 + $1.bytes } }

    func deleteReel(_ reel: ReelInfo) {
        for ext in ["mp4", "jpg", "json"] {
            try? fm.removeItem(at: reelsDir.appendingPathComponent(reel.id + "." + ext))
        }
        objectWillChange.send()
    }

    /// Builds one vertical reel out of the given clips, which may come from
    /// different sessions. Each rally is re-rendered from its own original so
    /// the vertical framing is chosen with the whole frame available.
    ///
    /// Returns the finished file and a report of what the platform cap cut.
    func buildReel(from pairs: [(session: Session, clip: ClipInfo)],
                   target: ReelTarget,
                   frame: OutputFrame = .vertical,
                   pace: ReelPace = .full,
                   preset: ReelPreset? = nil) async -> (url: URL, plan: ReelPlan)? {
        let ordered = pairs.sorted {
            ($0.session.playedAt, $0.clip.segment.start)
                < ($1.session.playedAt, $1.clip.segment.start)
        }
        guard !ordered.isEmpty else { return nil }
        let key = ordered[0].session.id
        guard !isBusy(key) else { return nil }
        // Same reason `render` waits: a reel started in the first seconds after
        // launch on a new device would otherwise bake a watermark into the best
        // thing a paying customer owns.
        await awaitEntitlement?()
        progress[key] = .reel(done: 0, total: ordered.count)
        // A reel re-renders every rally from its original, so it is the longest
        // job the app runs — and the one a user is most likely to walk away
        // from. Without this, switching to Instagram to wait killed it.
        let task = beginBackgroundTask()
        defer {
            clearProgressUnlessFailed(key)
            endBackgroundTask(task)
        }

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
            let styled = preset?.applied(to: pair.session.caption) ?? pair.session.caption
            items.append(ReelItem(asset: asset,
                                  segment: pair.clip.segment,
                                  caption: CaptionText.resolve(
                                      styled, session: pair.session,
                                      segments: pair.session.segments ?? [],
                                      index: pair.clip.index, lang: lang),
                                  smartCrop: useSmartCrop,
                                  targetPlayer: useSmartCrop
                                      ? pair.session.target(forClip: pair.clip.index) : nil,
                                  counterLabel: isPro && pair.session.shotCounterEnabled
                                      ? L.s("counter_label", lang) : nil,
                                  scoreboard: isPro && pair.session.scoreboardEnabled
                                      ? TennisScore.line(for: pair.session.segments ?? [],
                                                         sport: pair.session.sport,
                                                         lang: lang)[safe: pair.clip.index]
                                      : nil))
        }
        guard !items.isEmpty else {
            progress[key] = .failed(missingSourceMessage)
            return nil
        }

        // A fresh id per reel: the old settings-derived name meant a second
        // reel with the same platform and pace replaced the first. Declared out
        // here so the catch can remove the sidecar it wrote.
        let id = "reel_" + UUID().uuidString.prefix(8).lowercased()
        do {
            try? fm.createDirectory(at: reelsDir, withIntermediateDirectories: true)
            let out = reelsDir.appendingPathComponent(id + ".mp4")
            // The sidecar is what makes the reel visible and deletable, so it
            // is written first: a crash between the two used to leave a
            // several-hundred-megabyte file the app could neither show nor
            // remove. `reels()` drops entries whose mp4 never arrived.
            let placeholder = ReelInfo(id: id, createdAt: Date(), target: target.rawValue,
                                       frame: frame.rawValue, pace: pace.rawValue,
                                       preset: preset?.rawValue, rallies: 0, duration: 0,
                                       place: ordered.first?.session.placeName)
            try? JSONEncoder().encode(placeholder)
                .write(to: reelsDir.appendingPathComponent(id + ".json"))
            let plan = try await ReelBuilder.build(
                items: items, target: target, frame: frame, pace: pace,
                pro: isPro, to: out) { [weak self] done, total in
                    self?.progress[key] = .reel(done: done, total: total)
                }
            // Poster and sidecar, so the Reels tab can show it without opening
            // every file.
            try? ClipExporter.writeThumbnail(
                of: out, at: min(1.0, max(0, plan.duration - 0.2)),
                to: reelsDir.appendingPathComponent(id + ".jpg"))
            let info = ReelInfo(id: id, createdAt: Date(), target: target.rawValue,
                                frame: frame.rawValue, pace: pace.rawValue,
                                preset: preset?.rawValue,
                                rallies: plan.used, duration: plan.duration,
                                place: ordered.first?.session.placeName)
            try? JSONEncoder().encode(info)
                .write(to: reelsDir.appendingPathComponent(id + ".json"))
            objectWillChange.send()
            return (out, plan)
        } catch {
            // The sidecar is written before the video so a crash can't orphan
            // the file; a build that simply failed must take it with it.
            try? fm.removeItem(at: reelsDir.appendingPathComponent(id + ".json"))
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
        guard !isBusy(clip.sessionID),
              var s = sessions.first(where: { $0.id == clip.sessionID }),
              var segments = s.segments,
              clip.index < segments.count else { return }
        segments.remove(at: clip.index)
        s.segments = segments
        let kept = Array(0..<(segments.count + 1)).filter { $0 != clip.index }
        s.clipTargets = remap(s.clipTargets, survivors: kept)
        s.renderedClipTargets = remap(s.renderedClipTargets, survivors: kept)
        // the reel was built from the old set
        try? fm.removeItem(at: highlightURL(s))
        s.hasHighlight = false
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


extension Array {
    /// Bounds-checked lookup: a clip index can outrun a freshly re-detected
    /// session, and a crash there would take the whole reel down.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
