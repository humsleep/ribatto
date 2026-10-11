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
    @Published var progress: [UUID: ProcessingStage] = [:] {
        didSet { syncBackground() }
    }
    /// Clips keep encoding with the app in the background (iOS 26, a device
    /// with background GPU, and the entitlement). Drives the progress card's
    /// "you can switch apps" line.
    @Published private(set) var rendersInBackground = false
    /// Mirrored from ProPass so the export path knows the tier.
    @Published var isPro = false

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

    init() {
        load()
        background.onChange = { [weak self] in
            guard let self else { return }
            self.rendersInBackground = self.background.canRenderInBackground
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pausedNotified = false
                BackgroundWork.withdraw(id: "paused")
            }
        }
    }

    // MARK: - Background

    /// How many times the app has left the screen. A clip whose encode spans
    /// a change in this count was cut off by iOS, not by the video: the
    /// encoder and the crop both run on the GPU, which iOS refuses to apps in
    /// the background, and the encode then fails with the generic "operation
    /// could not be completed". A 14-minute 4K match failed that way on clip 9
    /// (2026-10-01) — the same clip encodes fine on a Mac.
    private var backgroundTrips = 0

    /// Holds a render between clips while the app is in the background, so it
    /// does not start GPU work iOS will refuse. Once suspended this simply
    /// resumes on return.
    private func waitForForeground() async {
        while UIApplication.shared.applicationState == .background
                && !background.canRenderInBackground {
            background.pause()
            notifyPaused()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private let background = BackgroundWork()
    /// The session whose stage the system progress UI is showing.
    private var backgroundSessionID: UUID?
    private var pausedNotified = false

    private func didEnterBackground() {
        backgroundTrips += 1
        #if DEBUG
        DebugLog.write("entered background busy=\(busyCount) keeps=\(background.keepsRunning) gpu=\(background.canRenderInBackground)")
        #endif
        // Without a continued task iOS suspends the app within seconds, maybe
        // before the render loop reaches its wait — so say it now.
        if busyCount > 0 && !background.keepsRunning { notifyPaused() }
    }

    private func notifyPaused() {
        guard !pausedNotified else { return }
        pausedNotified = true
        BackgroundWork.notify(id: "paused", title: L.s("notif_paused_title", lang),
                              body: L.s("notif_paused_body", lang))
    }

    /// Starts the system's background progress for a pipeline run the user
    /// just asked for. Must be called while the app is in front.
    private func beginWork(_ id: UUID) {
        BackgroundWork.requestNotificationPermission()
        backgroundSessionID = id
        let subtitle = sessions.first { $0.id == id }.map { L.dateTime($0.playedAt, lang) } ?? ""
        background.begin(title: L.s("stage_audio", lang), subtitle: subtitle)
        syncBackground()
    }

    /// Ends it, and tells a user who has gone elsewhere how it turned out.
    private func endWork(_ id: UUID) {
        var ok = true
        if case .failed(let message) = progress[id] {
            ok = false
            BackgroundWork.notify(id: "failed-" + id.uuidString,
                                  title: L.s("notif_failed_title", lang), body: message)
        } else if let s = sessions.first(where: { $0.id == id }), s.segments != nil {
            let ready = clips(of: s).filter(\.isReady).count
            BackgroundWork.notify(
                id: "done-" + id.uuidString,
                title: L.s("notif_done_title", lang),
                body: ready > 0 ? String(format: L.s("notif_done_fmt", lang), ready)
                                : L.s("notif_none", lang))
        }
        if backgroundSessionID == id { backgroundSessionID = nil }
        background.end(success: ok)
    }

    /// Mirrors the running session's stage into the system progress UI.
    private func syncBackground() {
        guard let id = backgroundSessionID, let stage = progress[id],
              let s = sessions.first(where: { $0.id == id }) else { return }
        let fraction: Double, key: String
        switch stage {
        case .queued, .audio: fraction = 0.02; key = "stage_audio"
        case .detect: fraction = 0.08; key = "stage_detect"
        case .render(let d, let t):
            fraction = 0.1 + 0.9 * Double(d) / Double(max(t, 1)); key = "stage_render"
        default: return
        }
        background.update(fraction: fraction, title: L.s(key, lang),
                          subtitle: L.dateTime(s.playedAt, lang))
    }

    #if DEBUG
    /// Launched with `-diagRender`: encodes rallies 10–13 of the first session
    /// into tmp and traces memory and errors to Documents/debug.log, so a
    /// device failure can be read without anyone tapping through the app.
    func runDiagnostics() async {
        DebugLog.write("diag start availMB=\(ClipExporter.availableMB())")
        guard let s = sessions.first, let segs = s.segments,
              let source = await loadAsset(s) else {
            DebugLog.write("diag: no session/source"); return
        }
        DebugLog.write("diag asset \(type(of: source)) \((source as? AVURLAsset)?.url.lastPathComponent ?? "-")")
        ClipExporter.trace = { DebugLog.write($0) }
        let dir = fm.temporaryDirectory.appendingPathComponent("diag", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in [9, 10, 11, 12, segs.count - 1] where i < segs.count {
            let seg = segs[i]
            DebugLog.write("clip \(i + 1) \(seg.start)-\(seg.end) start availMB=\(ClipExporter.availableMB())")
            do {
                try await ClipExporter.export(
                    source: source, segment: seg, orientation: s.effectiveOrientation, pro: false,
                    caption: nil, smartCrop: false,
                    clipURL: dir.appendingPathComponent("d\(i + 1).mp4"), thumbURL: nil)
                DebugLog.write("clip \(i + 1) OK availMB=\(ClipExporter.availableMB())")
            } catch {
                let e = error as NSError
                DebugLog.write("clip \(i + 1) FAIL \(e.domain) \(e.code) \(e.userInfo)")
            }
        }
        // The heaviest path: pass quality, vertical, smart crop (frame
        // analysis on the 4K source right before the encode).
        for i in [10, segs.count - 1] where i < segs.count {
            DebugLog.write("pro clip \(i + 1) start availMB=\(ClipExporter.availableMB())")
            do {
                try await ClipExporter.export(
                    source: source, segment: segs[i], orientation: "vertical", pro: true,
                    caption: nil, smartCrop: true,
                    clipURL: dir.appendingPathComponent("p\(i + 1).mp4"), thumbURL: nil)
                DebugLog.write("pro clip \(i + 1) OK availMB=\(ClipExporter.availableMB())")
            } catch {
                let e = error as NSError
                DebugLog.write("pro clip \(i + 1) FAIL \(e.domain) \(e.code) \(e.userInfo)")
            }
        }
        DebugLog.write("diag end")
    }
    #endif

    /// Clears a failure message the user has dismissed.
    func dismissFailure(_ id: UUID) {
        if case .failed = progress[id] { progress[id] = nil }
    }

    // MARK: - Paths

    func dir(_ s: Session) -> URL { root.appendingPathComponent(s.id.uuidString) }
    func sourceURL(_ s: Session) -> URL { dir(s).appendingPathComponent("source.mov") }
    func posterURL(_ s: Session) -> URL { dir(s).appendingPathComponent("poster.jpg") }
    /// Where the removed "highlight reel" feature wrote its file; kept only so
    /// `load` can clear what an older build left behind.
    private func highlightURL(_ s: Session) -> URL { dir(s).appendingPathComponent("highlight.mp4") }
    func clipsDir(_ s: Session) -> URL { dir(s).appendingPathComponent("clips", isDirectory: true) }
    /// Where a re-render builds its clips before they replace the old ones.
    private func stagingDir(_ s: Session) -> URL { dir(s).appendingPathComponent("clips.staging", isDirectory: true) }
    private func metaURL(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("meta.json")
    }

    // MARK: - Persistence

    /// Folders whose meta.json will not decode. They hold clips and possibly a
    /// whole recording, so they are counted rather than silently ignored — the
    /// storage line can then explain where the space went.
    private(set) var unreadableSessions = 0

    func load() {
        guard let ids = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        var out: [Session] = []
        var unreadable = 0
        for idStr in ids {
            guard let id = UUID(uuidString: idStr) else { continue }
            guard let data = try? Data(contentsOf: metaURL(id)),
                  let s = try? JSONDecoder().decode(Session.self, from: data) else {
                // A folder that will not decode holds clips and possibly a whole
                // recording. Skipping it silently left gigabytes the user could
                // neither see nor free, so it is at least counted.
                unreadable += 1
                continue
            }
            out.append(s)
            purgeTemporaries(in: clipsDir(s))
            try? fm.removeItem(at: highlightURL(s))
            // A render killed mid-way leaves its half-built clips here.
            try? fm.removeItem(at: stagingDir(s))
        }
        unreadableSessions = unreadable
        sessions = out.sorted { $0.playedAt > $1.playedAt }
    }

    func save(_ s: Session) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[i] = s
        }
        // Atomic: a kill or a full disk part-way through this write used to
        // truncate the file, and `load` then dropped the session for good.
        try? JSONEncoder().encode(s).write(to: metaURL(s.id), options: .atomic)
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
                                // An unfinished render's clips are already in
                                // its frame; drawing them 16:9 squashed a
                                // half-made vertical session.
                                orientation: s.renderedOrientation
                                    ?? s.partialRender?.orientation ?? "landscape",
                                sessionID: s.id, isReady: ready))
        }
        return out
    }

    /// Whether any session has a clip on disk, without building the whole
    /// list — it stops at the first one it finds.
    /// Whether this session still has rendered clip files. One `stat`, not a
    /// directory listing: the Library card asks this for every session on every
    /// redraw. "Free up clip files" leaves the rallies behind, so the card was
    /// still advertising 13 clips with nothing on disk.
    func hasClipFiles(_ s: Session) -> Bool {
        guard let segments = s.segments, !segments.isEmpty else { return false }
        let first = clipsDir(s).appendingPathComponent("clip_01.mp4")
        return fm.fileExists(atPath: first.path)
    }

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
                _ = await MainActor.run { self.mutate(id) { $0.capturedAt = date } }
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
            _ = await MainActor.run { self.mutate(sessionID) { $0.placeName = name } }
        }
    }

    func setPlaceName(_ s: Session, _ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        mutate(s.id) { $0.placeName = (trimmed?.isEmpty ?? true) ? nil : trimmed }
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

    /// Why the original can't be read, as an L10n key. A Photos original
    /// that is merely out of reach — access turned off, or not in a limited
    /// selection — used to be reported as deleted, and a user told their
    /// match was gone may well delete the session.
    func sourceProblemKey(_ s: Session) -> String {
        guard s.assetIdentifier != nil else { return "source_missing" }
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return "source_missing"
        case .limited: return "photos_limited_missing"
        default: return "photos_access_needed"
        }
    }

    func missingMessage(_ id: UUID) -> String {
        guard let s = sessions.first(where: { $0.id == id }) else { return missingSourceMessage }
        let key = sourceProblemKey(s)
        return key == "source_missing" ? missingSourceMessage : L.s(key, lang)
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
    /// - Parameter detect: false registers the session and leaves detection to
    ///   the caller — a multi-video import registers everything first so every
    ///   match shows up at once, then detects them one after another.
    @discardableResult
    func importFromPhotos(identifier: String, fallback: URL?, name: String,
                          detect: Bool = true) async -> UUID? {
        let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let canReference = granted == .authorized || granted == .limited
        if canReference, let asset = await Self.photoAsset(identifier) {
            if let id = await register(name: name, assetIdentifier: identifier,
                                       asset: asset, localCopy: nil, detect: detect,
                                       rescue: false) {
                if let fallback { try? fm.removeItem(at: fallback) }
                return id
            }
            // referencing the library asset failed — fall through to the copy
        }
        if let fallback {
            return await importVideo(from: fallback, name: name, detect: detect)
        }
        return nil
    }

    /// Moves a file into the session folder — used for in-app recordings and
    /// when Photos access is unavailable. Returns true when a session was made.
    @discardableResult
    /// - Parameter rescue: true only for an in-app recording that exists
    ///   nowhere else. Every other copy has its original in Photos or Files.
    func importVideo(from temp: URL, name: String, detect: Bool = true,
                     rescue: Bool = false) async -> UUID? {
        await register(name: name, assetIdentifier: nil, asset: nil, localCopy: temp,
                       detect: detect, rescue: rescue)
    }

    /// Detects several freshly imported sessions one after another. Running
    /// them side by side would decode several originals at once for no gain.
    ///
    /// One queue for the whole store. Waiting sessions are marked `.queued`
    /// so they read as busy — they used to look undetected, and tapping Detect
    /// on one decoded a second original alongside the queue (the memory
    /// pressure that kills the media server). A second import while the queue
    /// runs joins it instead of starting a parallel one.
    func processQueued(_ ids: [UUID]) async {
        for id in ids where !detectQueue.contains(id) && !isBusy(id) {
            detectQueue.append(id)
            progress[id] = .queued
        }
        guard !queueRunning, let first = detectQueue.first else { return }
        queueRunning = true
        // One background task for the whole queue: a new one can only be
        // requested with the app in front, and by the second video the user
        // has usually left.
        beginWork(first)
        defer {
            queueRunning = false
            background.end(success: true)
        }
        while !detectQueue.isEmpty {
            let id = detectQueue.removeFirst()
            if case .queued = progress[id] { progress[id] = nil }
            // Deleted while waiting, or already detected some other way.
            guard let s = sessions.first(where: { $0.id == id }),
                  s.segments == nil else { continue }
            await process(sessionID: id)
        }
    }
    private var detectQueue: [UUID] = []
    private var queueRunning = false

    /// Puts an in-app recording into the Photos library and returns its
    /// identifier, so the session can reference it like any imported video.
    ///
    /// A recording used to live only inside the app — the camera picker does
    /// not write to Photos — so deleting its session deleted the match for
    /// good, and it took the app's storage twice over nothing.
    func saveRecordingToPhotos(_ url: URL) async -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        var identifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: url, options: options)
                identifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch { return nil }
        return identifier
    }

    @discardableResult
    private func register(name: String, assetIdentifier: String?,
                          asset: AVAsset?, localCopy: URL?, detect: Bool,
                          rescue: Bool) async -> UUID? {
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
            guard let source else { throw NSError(domain: "Ribatto", code: 40) }
            let info = try await VideoProbe.probe(
                asset: source, posterURL: sdir.appendingPathComponent("poster.jpg"))
            var s = Session(id: id, name: name, createdAt: Date(),
                            duration: info.duration,
                            width: info.width, height: info.height)
            if let sport = lastSport { s.sport = sport }
            s.assetIdentifier = assetIdentifier
            s.capturedAt = await captureDate(assetIdentifier: assetIdentifier,
                                             asset: source)
            if let coordinate = await coordinate(assetIdentifier: assetIdentifier,
                                                 asset: source) {
                s.latitude = coordinate.latitude
                s.longitude = coordinate.longitude
            }
            // Written before the session joins the list: if the encode fails
            // the folder is orphaned rather than shown once and lost on the
            // next launch.
            try JSONEncoder().encode(s).write(to: metaURL(id), options: .atomic)
            // Ordered by when the match was played, the same rule `load`
            // applies. Inserting at the front put an old import above newer
            // sessions until the next launch — and StatsView's share card takes
            // its backdrop from the first session, so the card used that old
            // match's poster.
            let at = sessions.firstIndex { $0.playedAt < s.playedAt } ?? sessions.count
            sessions.insert(s, at: at)
            resolvePlaceName(for: id)             // needs the network; don't block
            if detect { await process(sessionID: id) }   // auto-detect on import
            return id
        } catch {
            // An in-app recording lives nowhere else — UIImagePickerController
            // does not write to Photos — so deleting the session folder on a
            // failed probe destroyed a whole match. Put the movie somewhere
            // recoverable before the folder goes.
            // Only that recording: rescuing every failed copy (a Files import
            // that won't decode, a Photos fallback) filled this with movies
            // that could not be saved back to Photos and could not be removed.
            let moved = sdir.appendingPathComponent("source.mov")
            if rescue, fm.fileExists(atPath: moved.path) {
                let rescue = root.appendingPathComponent("recovered", isDirectory: true)
                try? fm.createDirectory(at: rescue, withIntermediateDirectories: true)
                try? fm.moveItem(
                    at: moved,
                    to: rescue.appendingPathComponent("\(id.uuidString).mov"))
            }
            try? fm.removeItem(at: sdir)
            return nil
        }
    }

    // MARK: - Recovered recordings

    /// Recordings a failed import moved aside (see `register`). Nothing in the
    /// app listed them, so a rescued match was as good as lost.
    var recoveredDir: URL { root.appendingPathComponent("recovered", isDirectory: true) }
    func recoveredRecordings() -> [URL] {
        ((try? fm.contentsOfDirectory(at: recoveredDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mov" }
    }

    /// Saves every rescued recording to Photos and removes the ones that made
    /// it. Returns how many were saved.
    func saveRecoveredToPhotos() async -> Int {
        var saved = 0
        for url in recoveredRecordings() where await saveToPhotos(url) {
            try? fm.removeItem(at: url)
            saved += 1
        }
        objectWillChange.send()
        return saved
    }

    /// Throws the rescued recordings away. A movie Photos refuses (it does not
    /// decode) could otherwise never leave the library screen.
    func discardRecovered() {
        for url in recoveredRecordings() { try? fm.removeItem(at: url) }
        objectWillChange.send()
    }

    // MARK: - Storage

    /// Bytes on disk for one session: its clips, and the original when the app
    /// holds its own copy (recordings, and imports without Photos access).
    func storage(of s: Session) -> (clips: Int64, original: Int64) {
        func size(_ url: URL) -> Int64 {
            (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
        }
        let files = (try? fm.contentsOfDirectory(at: clipsDir(s), includingPropertiesForKeys: nil)) ?? []
        return (files.reduce(0) { $0 + size($1) }, size(sourceURL(s)))
    }

    /// Deletes the rendered clip files and keeps everything else — the rallies,
    /// trims, favourites and settings — so Apply can make them again later.
    /// Weekly players fill a phone with clips they have already posted.
    @discardableResult
    func clearClipFiles(_ s: Session) -> Bool {
        guard !isBusy(s.id), !sourceMissing(s) else { return false }
        try? fm.removeItem(at: clipsDir(s))
        try? fm.removeItem(at: dir(s).appendingPathComponent("merged.mp4"))
        // Unrecorded render: Apply offers to make the clips again. The record
        // moves into `partialRender` first, marked cleared, so the screen can
        // say what happened instead of "settings changed" — and Apply, with
        // nothing changed, continues into the empty folder as a resume.
        mutate(s.id) {
            if let o = $0.renderedOrientation {
                $0.partialRender = RenderStamp(
                    orientation: o, pro: $0.renderedPro ?? false,
                    smartCrop: $0.renderedSmartCrop ?? false,
                    caption: $0.renderedCaption,
                    clipTargets: $0.renderedClipTargets ?? [:],
                    targetPlayer: $0.renderedTargetPlayer,
                    rallies: $0.segments ?? [], lang: nil, cleared: true)
            }
            $0.renderedOrientation = nil
        }
        return true
    }

    func deleteSession(_ s: Session) {
        // Marked before the files go: a render already in flight keeps writing
        // into the folder and re-creates it, leaving clips with no meta.json
        // that `load` skips forever and nothing can reclaim.
        deleted.insert(s.id)
        try? fm.removeItem(at: dir(s))
        sessions.removeAll { $0.id == s.id }
        progress[s.id] = nil
    }

    /// Sessions removed while work was still running. The pipeline checks this
    /// after each await and stops.
    private var deleted: Set<UUID> = []

    private func wasDeleted(_ id: UUID) -> Bool { deleted.contains(id) }

    // MARK: - Settings

    // Changing a setting only records the choice. Nothing is re-processed
    // until the user presses the apply button — picking three settings used to
    // kick off three full re-detects.
    //
    // Each writes one field onto the store's current copy. They used to save
    // the caller's whole snapshot, and a sheet holding an older `Session`
    // put back the rallies and render record from before a detect or render.

    func setSport(_ s: Session, _ sport: Sport) {
        mutate(s.id) { $0.sport = sport }
        lastSport = sport
    }

    /// The sport the next import is detected as: the one the user last chose.
    /// Every import used to start as tennis, so a badminton player's first
    /// detection of every match ran with the wrong strike profile.
    static let lastSportKey = "rc_sport"
    var lastSport: Sport? {
        get { UserDefaults.standard.string(forKey: Self.lastSportKey).flatMap(Sport.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: Self.lastSportKey) }
    }
    func setSensitivity(_ s: Session, _ sens: Sensitivity) {
        mutate(s.id) { $0.sensitivity = sens }
    }
    func setAspect(_ s: Session, _ aspect: AspectSetting) {
        mutate(s.id) { $0.aspect = aspect }
    }
    func setCaption(_ s: Session, _ caption: CaptionSettings) {
        mutate(s.id) { $0.caption = caption }
    }
    func setSmartCrop(_ s: Session, _ on: Bool) {
        mutate(s.id) { $0.smartCrop = on }
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
    /// Nil on success, otherwise the L10n key that says why. Every refusal
    /// used to show "Import failed", which explained none of them.
    func addRally(to session: Session, start: Double, end: Double) async -> String? {
        guard !isBusy(session.id) else { return "busy_wait" }
        guard end - start >= minClipSeconds else { return "add_rally_short" }
        guard let live = sessions.first(where: { $0.id == session.id }) else { return "render_failed" }
        guard !sourceMissing(live) else { return sourceProblemKey(live) }
        // A rally that lands on top of one already there is a double tap, not a
        // second point: the sheet opens at the same default position every time,
        // so accepting it twice produced two clips of the same moment. Split is
        // the tool for cutting an existing rally; this one is for a missed one.
        let existing = live.segments ?? []
        let overlapsExisting = existing.contains { seg in
            let overlap = min(seg.end, end) - max(seg.start, start)
            return overlap > 0.5 * min(seg.end - seg.start, end - start)
        }
        guard !overlapsExisting else { return "add_rally_overlap" }
        // The sheet was handed a snapshot; anything written while it was open
        // would be lost if we edited that copy.
        var segments = live.segments ?? []
        // The segment count before the list grows: every one of these must be
        // on disk for the renumber shortcut to be safe.
        let rendered = segments.count
        let seg = RallySegment(start: max(0, start),
                               end: min(session.duration, end),
                               hits: 0, score: nil, trimmed: true)
        let at = segments.firstIndex { $0.start > seg.start } ?? segments.count
        segments.insert(seg, at: at)
        mutate(session.id) {
            $0.segments = segments
            // indices moved, so per-clip overrides no longer point at the
            // clips they were chosen for
            $0.clipTargets = shift($0.clipTargets, insertedAt: at)
            $0.renderedClipTargets = nil
        }
        await renumberAndRender(session.id, segments: segments,
                                renderedCount: rendered, insertedAt: at,
                                newIndices: [at])
        return nil
    }


    /// True when the burned-in caption reads differently depending on where a
    /// rally sits in the session. Renumbering then means re-encoding, because
    /// the text is in the pixels.
    private func captionFollowsIndex(_ s: Session) -> Bool {
        guard let c = s.renderedCaption, c.enabled else { return false }
        return c.text.contains("{rally}") || c.text.contains("{rank}")
    }

    /// Moves rendered clips from `from` upward by one place so `clip_NN` lines
    /// up with the segment list again. Highest number first, so a move never
    /// lands on a file that has not been moved yet.
    ///
    /// Returns false — having changed nothing it cannot undo — if a file is
    /// missing or a move fails. The caller then falls back to the full render,
    /// which rebuilds every clip regardless of what is on disk.
    private func shiftClipFiles(_ s: Session, from: Int, count: Int) -> Bool {
        let dir = clipsDir(s)
        let fm = FileManager.default
        func url(_ i: Int, _ ext: String) -> URL {
            dir.appendingPathComponent(String(format: "clip_%02d.%@", i + 1, ext))
        }
        // Check first, move second: a half-finished shift is worse than not
        // starting, and this way the fallback is a clean full render. The whole
        // old set has to be present, not just the tail — a session with a gap
        // in it (a failed clip, a half-finished render) has to be rebuilt.
        let complete = (0..<count).allSatisfy {
            fm.fileExists(atPath: url($0, "mp4").path)
        }
        guard complete else { return false }
        guard from < count else { return true }
        for i in stride(from: count - 1, through: from, by: -1) {
            for ext in ["mp4", "jpg"] {
                let src = url(i, ext), dst = url(i + 1, ext)
                guard fm.fileExists(atPath: src.path) else { continue }
                try? fm.removeItem(at: dst)
                do { try fm.moveItem(at: src, to: dst) } catch { return false }
            }
        }
        return true
    }

    /// Inserting or splitting a rally renumbers the clips after it, but their
    /// pixels do not change — only their file names do. Renaming them and
    /// encoding just the new rallies turns a whole-session re-encode into one
    /// or two clips. Measured on a 13-clip session: 7.5 minutes to insert a
    /// single rally before this, seconds after.
    ///
    /// Falls back to `render` whenever the shortcut is not safe: nothing
    /// rendered yet, a caption whose text depends on the rally's position, or
    /// any file move that does not go through.
    private func renumberAndRender(_ sessionID: UUID, segments: [RallySegment],
                                   renderedCount: Int, insertedAt: Int,
                                   newIndices: [Int]) async {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        guard renderedCount > 0, !captionFollowsIndex(s), !isBusy(sessionID),
              shiftClipFiles(s, from: insertedAt, count: renderedCount)
        else {
            await render(sessionID: sessionID)
            return
        }
        let bgTask = beginBackgroundTask()
        defer { endBackgroundTask(bgTask) }
        for i in newIndices {
            guard await rerenderClip(s, segments: segments, index: i) else {
                // The shift already happened, so the only consistent way back
                // is to rebuild the session from the segment list.
                await render(sessionID: sessionID)
                return
            }
        }
        objectWillChange.send()
    }

    /// Cuts one rally in two at `at` seconds — for the point the detector ran
    /// together with the next one.
    @discardableResult
    func splitRally(_ clip: ClipInfo, at time: Double) async -> Bool {
        guard let session = sessions.first(where: { $0.id == clip.sessionID }),
              var segments = session.segments, clip.index < segments.count,
              !isBusy(session.id) else { return false }
        let rendered = segments.count
        let seg = segments[clip.index]
        guard time - seg.start >= minClipSeconds,
              seg.end - time >= minClipSeconds else { return false }
        // Strikes and the crowd reaction belong to whichever half they land in;
        // the score is no longer meaningful for either, so both are unscored.
        let firstHits = (seg.hitTimes ?? []).filter { $0 < time }
        let secondHits = (seg.hitTimes ?? []).filter { $0 >= time }
        var first = RallySegment(start: seg.start, end: time,
                                 hits: firstHits.isEmpty ? seg.hits / 2 : firstHits.count,
                                 score: nil, trimmed: true,
                                 hitTimes: seg.hitTimes == nil ? nil : firstHits)
        var second = RallySegment(start: time, end: seg.end,
                                  hits: secondHits.isEmpty ? seg.hits - seg.hits / 2 : secondHits.count,
                                  score: nil, trimmed: true,
                                  hitTimes: seg.hitTimes == nil ? nil : secondHits,
                                  cheer: seg.cheer)
        // The play verdict covered both halves; the reaction follows the end.
        first.racketConf = seg.racketConf
        second.racketConf = seg.racketConf
        second.crowdConf = seg.crowdConf
        // The star describes the point the user was looking at, and that point
        // is the one that ends where the original ended — the second half.
        second.favourite = seg.favourite
        segments.replaceSubrange(clip.index...clip.index, with: [first, second])
        mutate(session.id) {
            $0.segments = segments
            $0.clipTargets = shift($0.clipTargets, insertedAt: clip.index + 1)
            $0.renderedClipTargets = nil
        }
        // Everything after the cut shifts up one; the two halves are the only
        // clips whose pixels are actually new.
        await renumberAndRender(session.id, segments: segments,
                                renderedCount: rendered,
                                insertedAt: clip.index + 1,
                                newIndices: [clip.index, clip.index + 1])
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

    /// The in-app language, for strings burned into video (a caption's
    /// "Best #1").
    var lang: String { UserDefaults.standard.string(forKey: "rc_lang") ?? "en" }

    /// The message a failure leaves on screen. Errors the app raises itself
    /// carry English diagnostics meant for a log ("Unusable video settings"),
    /// which is not a sentence to show a Korean user; those become the
    /// localized "couldn't build that". System errors arrive localized already.
    /// System errors are mapped too: AVFoundation's own text for most of them
    /// is "The operation could not be completed", which tells the user nothing
    /// they can act on. The code is kept on the end for support.
    private func failureText(_ error: Error, interrupted: Bool = false) -> String {
        #if DEBUG
        print("[store] failed: \(error)")
        #endif
        let e = error as NSError
        if e.domain == "Ribatto" {
            return e.code == AudioLoader.noAudioCode ? L.s("no_audio", lang) : L.s("render_failed", lang)
        }
        if Self.isDiskFull(e) { return L.s("disk_full", lang) }
        if interrupted || Self.isInterruption(e) { return interruptedMessage }
        return L.s("process_failed", lang) + " (\(e.code))"
    }

    private static func isDiskFull(_ e: NSError) -> Bool {
        if e.domain == AVFoundationErrorDomain && e.code == AVError.Code.diskFull.rawValue { return true }
        if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
        if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) { return true }
        if let under = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(under) }
        return false
    }

    private static func isInterruption(_ e: NSError) -> Bool {
        e.domain == AVFoundationErrorDomain
            && e.code == AVError.Code.operationInterrupted.rawValue
    }
    /// Picking a player only matters through the smart-crop path, so turn that
    /// on with it; clearing the player leaves smart crop as the user had it.
    func setTargetPlayer(_ s: Session, _ target: TargetPlayer?) {
        mutate(s.id) {
            $0.targetPlayer = target
            if target != nil { $0.smartCrop = true }
        }
    }

    /// Points ONE clip at a different player, or back at the session's choice
    /// with nil, and re-cuts just that clip.
    ///
    /// Only one clip is re-encoded because only one changed — re-running the
    /// whole session for a single rally is minutes of work to redo seconds of
    /// it.
    /// Returns false when the session was busy and nothing was changed — the
    /// sheet used to dismiss as if it had saved. A render failure also returns
    /// false, with the message left in `progress` for the session card.
    @discardableResult
    func setClipTarget(_ clip: ClipInfo, _ target: TargetPlayer?) async -> Bool {
        guard let session = sessions.first(where: { $0.id == clip.sessionID }),
              let segments = session.segments,
              clip.index < segments.count,
              !isBusy(session.id) else { return false }
        let key = String(clip.index)
        mutate(session.id) {
            var targets = $0.clipTargets ?? [:]
            targets[key] = target                     // nil removes the override
            $0.clipTargets = targets
        }
        guard let updated = sessions.first(where: { $0.id == clip.sessionID }),
              updated.renderedSmartCrop == true else { return true }

        progress[session.id] = .render(done: clip.index, total: segments.count)
        defer { clearProgressUnlessFailed(session.id) }
        guard let source = await loadAsset(updated) else {
            progress[session.id] = .failed(missingMessage(session.id))
            return false
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
            return true
        } catch {
            progress[session.id] = .failed(failureText(error))
            return false
        }
    }

    /// Applies whatever the user changed: re-detect if the detection inputs
    /// moved, otherwise just re-render at the new aspect.
    func apply(sessionID: UUID) async {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        // An empty result is not a finished job. Without the isEmpty case,
        // pressing Detect again on a session that found nothing did nothing at
        // all — the settings were unchanged, so neither branch fired and the
        // button looked dead exactly where the user most needs it to work.
        let foundNothing = s.segments?.isEmpty ?? false
        if s.segments == nil || foundNothing || s.needsRedetect {
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
        beginWork(sessionID)
        defer { endWork(sessionID) }
        do {
            progress[sessionID] = .audio
            guard let source = await loadAsset(s) else {
                progress[sessionID] = .failed(missingMessage(sessionID))
                return
            }
            let sport = s.sport, sens = s.sensitivity, dur = s.duration
            // Scoped so the 16 kHz samples (≈345 MB on a 90-minute recording)
            // are freed before the render, which needs the memory for frames.
            let segments: [RallySegment] = try await {
                let samples = try await AudioLoader.loadMono16k(asset: source)
                progress[sessionID] = .detect
                return await Task.detached(priority: .userInitiated) {
                    let found = RallyDetector.detect(samples: samples,
                                                     sampleRate: AudioLoader.sampleRate,
                                                     duration: dur, sensitivity: sens, sport: sport)
                    // A second opinion from the built-in sound classifier, on
                    // the samples already in memory. If it cannot run, the
                    // detector's own answer stands.
                    guard let verdicts = SoundCheck.classify(samples: samples,
                                                             sampleRate: AudioLoader.sampleRate,
                                                             segments: found)
                    else { return found }
                    return SoundCheck.apply(verdicts, to: found)
                }.value
            }()
            // A re-detect that finds nothing must not replace finished clips
            // with an empty folder: the staged swap went through with zero
            // clips and wiped the session, trims and stars included.
            if segments.isEmpty && hasFinishedClips(s) {
                progress[sessionID] = .failed(L.s("redetect_none_kept", lang))
                return
            }
            await render(sessionID: sessionID, alreadyRunning: true,
                         detection: Detection(segments: segments, sport: sport, sensitivity: sens))
        } catch {
            // Only reading the audio or detecting can throw here — `render`
            // handles its own failures — so no clip has been touched yet. This
            // used to delete the clips folder, and a Photos original that would
            // not decode wiped every clip the session had.
            progress[sessionID] = .failed(failureText(error))
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
        id = UIApplication.shared.beginBackgroundTask(withName: "RibattoRender") {
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

    /// A fresh detection that has not been written to the session yet.
    struct Detection {
        var segments: [RallySegment]
        var sport: Sport
        var sensitivity: Sensitivity
    }

    /// Whether the session has at least one finished clip on disk — the thing
    /// a failed re-render must not take away.
    private func hasFinishedClips(_ s: Session) -> Bool {
        let files = (try? fm.contentsOfDirectory(atPath: clipsDir(s).path)) ?? []
        return files.contains { $0.hasSuffix(".mp4") }
    }

    private func commit(_ d: Detection, to id: UUID) {
        mutate(id) {
            // Per-clip players are keyed by index. New rallies at the same
            // index are different points, and the tracker followed whoever
            // stood where the old pick was.
            if $0.segments != d.segments {
                $0.clipTargets = nil
                $0.renderedClipTargets = nil
            }
            $0.segments = d.segments
            $0.detectedSport = d.sport
            $0.detectedSensitivity = d.sensitivity
            $0.detectionFoundNothing = d.segments.isEmpty
        }
    }

    /// Renders every clip of the session.
    ///
    /// When the session already has clips, the new ones are built in a staging
    /// folder and swapped in only once all of them exist, together with the
    /// detection that produced them. A render that failed part-way used to
    /// delete the old clips first and leave the session half empty — and when
    /// nothing was left to "apply", with no way to try again. A first render
    /// has nothing to lose, so it writes in place and the posters show up as
    /// they are cut.
    func render(sessionID: UUID, alreadyRunning: Bool = false,
                detection: Detection? = nil) async {
        guard let s = sessions.first(where: { $0.id == sessionID }),
              let segments = detection?.segments ?? s.segments else { return }
        if !alreadyRunning && isBusy(sessionID) { return }
        if !alreadyRunning { progress[sessionID] = nil }
        let bgTask = alreadyRunning ? UIBackgroundTaskIdentifier.invalid
                                    : beginBackgroundTask()
        defer { endBackgroundTask(bgTask) }
        if !alreadyRunning { beginWork(sessionID) }
        defer { if !alreadyRunning { endWork(sessionID) } }
        // The source has to be in hand BEFORE the old clips are deleted: this
        // used to wipe every clip and only then discover the original was gone
        // from Photos, leaving the user with nothing at all.
        progress[sessionID] = .audio
        guard var source = await loadAsset(s) else {
            progress[sessionID] = .failed(missingMessage(sessionID))
            return
        }
        let orient = s.effectiveOrientation
        let pro = isPro
        let caption = s.caption
        let useSmartCrop = isPro && s.effectiveSmartCrop
        let target = useSmartCrop ? s.targetPlayer : nil
        // A new detection's rallies don't line up with the old per-clip picks.
        let rallies = detection == nil || detection?.segments == s.segments
        let perClip = useSmartCrop && rallies ? (s.clipTargets ?? [:]) : [:]
        let stamp = RenderStamp(orientation: orient, pro: pro, smartCrop: useSmartCrop,
                                caption: caption, clipTargets: perClip,
                                targetPlayer: target, rallies: segments, lang: lang)
        // A first render that stopped part-way, with nothing changed since:
        // keep its clips and make only the missing ones. Redoing all of them
        // used to take as long as the first try and meet the same failure.
        let resuming = detection == nil && s.renderedOrientation == nil
            && s.partialRender?.matches(stamp) == true
        let staged = !resuming && hasFinishedClips(s)
        let cdir = staged ? stagingDir(s) : clipsDir(s)
        if !staged, let detection { commit(detection, to: sessionID) }
        if !staged { mutate(sessionID) { $0.partialRender = stamp } }
        do {
            if !resuming { try? fm.removeItem(at: cdir) }
            try fm.createDirectory(at: cdir, withIntermediateDirectories: true)
            purgeTemporaries(in: cdir)
            func clipURL(_ i: Int) -> URL {
                cdir.appendingPathComponent(String(format: "clip_%02d.mp4", i + 1))
            }
            // `renderedOrientation` is the record of a finished render, so it
            // is written only on the success path below. Setting it here made a
            // render that threw halfway look complete: needsRerender went false
            // and Apply then had nothing to do, stranding the session.
            // 1) posters for every rally (no encoding — takes a moment, not minutes)
            for (i, seg) in segments.enumerated() where !fm.fileExists(atPath: clipURL(i).path) {
                let base = String(format: "clip_%02d", i + 1)
                try? await ClipExporter.writePoster(
                    of: source, at: min(seg.start + 1.0, seg.end),
                    to: cdir.appendingPathComponent("\(base).jpg"))
            }
            objectWillChange.send()

            // 2) the actual clips
            var failed = 0
            var lastError: Error?
            var lastInterrupted = false
            for (i, seg) in segments.enumerated() {
                if wasDeleted(sessionID) { try? fm.removeItem(at: cdir); return }
                if resuming && fm.fileExists(atPath: clipURL(i).path) { continue }
                progress[sessionID] = .render(done: i, total: segments.count)
                let base = String(format: "clip_%02d", i + 1)
                // Two tries. The usual failure is iOS refusing the GPU after
                // the user left the app; waiting for them to come back and
                // encoding again succeeds where the first try could not.
                var attempt = 0
                while true {
                    await waitForForeground()
                    let trips = backgroundTrips
                    #if DEBUG
                    DebugLog.write("clip \(i + 1) start state=\(UIApplication.shared.applicationState.rawValue)")
                    #endif
                    do {
                        try await ClipExporter.export(
                            source: source, segment: seg, orientation: orient, pro: pro,
                            caption: CaptionText.resolve(caption, session: s, segments: segments,
                                                         index: i, lang: lang),
                            smartCrop: useSmartCrop,
                            clipURL: clipURL(i),
                            // Replaces the source-aspect placeholder written above with
                            // a poster cut from the finished clip. Without this a
                            // portrait clip kept a 16:9 still, and the card had to
                            // stretch to hold it.
                            thumbURL: cdir.appendingPathComponent("\(base).jpg"),
                            targetPlayer: useSmartCrop ? (perClip[String(i)] ?? target) : nil)
                        #if DEBUG
                        DebugLog.write("clip \(i + 1) done state=\(UIApplication.shared.applicationState.rawValue)")
                        #endif
                        break
                    } catch {
                        #if DEBUG
                        DebugLog.write("clip \(i + 1) FAILED state=\(UIApplication.shared.applicationState.rawValue) \(error)")
                        #endif
                        // A fresh asset before anything else touches it. When
                        // iOS resets the media server (-11819) the old one is
                        // dead for good — every later clip failed instantly on
                        // its tracks — and a second later a new one loads fine.
                        try? await Task.sleep(for: .seconds(1))
                        if let fresh = await loadAsset(s) { source = fresh }
                        attempt += 1
                        if attempt < 2 { continue }
                        // A re-render is all or nothing: the old clips stay
                        // until every new one exists.
                        if staged { throw error }
                        // A first render keeps going. One bad rally used to
                        // abort the session and leave the rest unmade.
                        failed += 1
                        lastError = error
                        lastInterrupted = backgroundTrips != trips
                        break
                    }
                }
            }
            if let lastError {
                purgeTemporaries(in: cdir)
                mutate(sessionID) { $0.renderedOrientation = nil }
                objectWillChange.send()
                progress[sessionID] = .failed(failed == segments.count
                    ? failureText(lastError, interrupted: lastInterrupted)
                    : String(format: L.s("clips_failed_fmt", lang), failed))
                return
            }
            if staged {
                try swapInStaged(s)
                if let detection { commit(detection, to: sessionID) }
            }
            mutate(sessionID) {
                $0.renderedOrientation = orient
                $0.renderedPro = pro
                $0.renderedCaption = caption
                $0.renderedSmartCrop = useSmartCrop
                $0.renderedTargetPlayer = target
                $0.renderedClipTargets = perClip
                $0.partialRender = nil
            }
            objectWillChange.send()
            progress[sessionID] = nil
        } catch {
            if staged {
                try? fm.removeItem(at: cdir)
            } else {
                // Partial clips in place: mark the render unfinished so Apply
                // stays available to run it again — and, with `partialRender`
                // still set, to continue it.
                purgeTemporaries(in: cdir)
                mutate(sessionID) { $0.renderedOrientation = nil }
            }
            progress[sessionID] = .failed(failureText(error))
        }
    }

    /// Replaces the clips folder with the staged one. If the move fails the old
    /// folder is put back, so the session never ends up with neither.
    private func swapInStaged(_ s: Session) throws {
        let live = clipsDir(s), staging = stagingDir(s)
        purgeTemporaries(in: staging)
        let old = dir(s).appendingPathComponent("clips.old", isDirectory: true)
        try? fm.removeItem(at: old)
        try fm.moveItem(at: live, to: old)
        do {
            try fm.moveItem(at: staging, to: live)
        } catch {
            try? fm.moveItem(at: old, to: live)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    /// Half-written exports the encoder leaves behind when it is interrupted
    /// ("tmp_clip_04.mp4", and the sandbox's own rename leftovers). They are
    /// invisible in the app and count against the phone's storage.
    private func purgeTemporaries(in folder: URL) {
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("tmp_") || url.lastPathComponent.contains(".sb-") {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Trim

    /// Moves one rally's in/out points and re-renders only that clip.
    ///
    /// Re-rendering the session for a trim would cost minutes to change one
    /// clip, so this writes the segment, drops the reel built from the old cut,
    /// and encodes the single file.
    /// Returns false when nothing was changed (the session was busy, most
    /// often with the previous clip's re-render) or the re-render failed.
    /// TrimSheet used to close on both as though the trim had taken.
    @discardableResult
    func trimClip(_ clip: ClipInfo, start: Double, end: Double) async -> Bool {
        guard let session = sessions.first(where: { $0.id == clip.sessionID }),
              var segments = session.segments,
              clip.index < segments.count,
              end - start >= minClipSeconds,
              !isBusy(session.id) else { return false }
        segments[clip.index].start = max(0, start)
        segments[clip.index].end = min(session.duration, end)
        segments[clip.index].trimmed = true
        let segment = segments[clip.index]
        mutate(session.id) {
            $0.segments = segments
        }

        // The encoder writes to a temporary file, so on failure the old clip is
        // still on disk. Put the old in/out points back with it — keeping the
        // new ones showed times the video did not match, and nothing flagged
        // the clip for Apply to fix.
        if await rerenderClip(session, segments: segments, index: clip.index) { return true }
        let old = session.segments?[clip.index]
        mutate(session.id) {
            guard let old, $0.segments?[safe: clip.index] == segment else { return }
            $0.segments?[clip.index] = old
        }
        return false
    }

    /// Renders one clip again with the settings the session was last rendered
    /// with. Every per-clip edit ends here,
    /// because what the user changed lives in pixels.
    @discardableResult
    private func rerenderClip(_ session: Session, segments: [RallySegment], index: Int) async -> Bool {
        let segment = segments[index]
        progress[session.id] = .render(done: index, total: segments.count)
        defer { clearProgressUnlessFailed(session.id) }
        guard let source = await loadAsset(session) else {
            progress[session.id] = .failed(missingMessage(session.id))
            return false
        }
        let base = String(format: "clip_%02d", index + 1)
        let dir = clipsDir(session)
        // A first render that has not finished has no `rendered*` record yet;
        // its clips are being made with the stamp's settings, so an edited
        // clip must match them — it used to come out uncaptioned and uncropped.
        let partial = session.renderedOrientation == nil ? session.partialRender : nil
        let smart = session.renderedSmartCrop ?? partial?.smartCrop ?? false
        do {
            try await ClipExporter.export(
                source: source, segment: segment,
                orientation: session.renderedOrientation ?? partial?.orientation
                    ?? session.effectiveOrientation,
                pro: session.renderedPro ?? partial?.pro ?? isPro,
                caption: CaptionText.resolve(session.renderedCaption ?? partial?.caption,
                                             session: session,
                                             segments: segments, index: index, lang: lang),
                smartCrop: smart,
                clipURL: dir.appendingPathComponent("\(base).mp4"),
                thumbURL: dir.appendingPathComponent("\(base).jpg"),
                targetPlayer: smart ? session.target(forClip: index) : nil)
            syncPartialStamp(session.id)
            objectWillChange.send()
            return true
        } catch {
            progress[session.id] = .failed(failureText(error))
            return false
        }
    }

    /// Shortest clip worth making — below this there is no rally to watch,
    /// only a strike and a cut.
    let minClipSeconds = 1.5

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
        // The user removed these; a later empty screen must not blame detection.
        s.detectionFoundNothing = false
        // Deleting the clips that failed is the obvious thing to do after a
        // partial render. The stamp follows the rallies, and when every
        // remaining clip exists the render is simply complete.
        if s.renderedOrientation == nil, var stamp = s.partialRender {
            stamp.rallies = s.segments ?? []
            s.partialRender = stamp
            let all = (s.segments ?? []).indices.allSatisfy {
                fm.fileExists(atPath: cdir.appendingPathComponent(
                    String(format: "clip_%02d.mp4", $0 + 1)).path)
            }
            if all {
                s.renderedOrientation = stamp.orientation
                s.renderedPro = stamp.pro
                s.renderedCaption = stamp.caption
                s.renderedSmartCrop = stamp.smartCrop
                s.renderedTargetPlayer = stamp.targetPlayer
                s.renderedClipTargets = stamp.smartCrop ? (s.clipTargets ?? [:]) : [:]
                s.partialRender = nil
            }
        }
        save(s)
        return true
    }

    /// After a single clip was re-cut in an unfinished render, the stamp
    /// takes the session's current rallies — a trim or split moved them, and
    /// a stale stamp turned the next Apply into a full re-render.
    private func syncPartialStamp(_ id: UUID) {
        mutate(id) {
            guard $0.renderedOrientation == nil, var stamp = $0.partialRender,
                  let segs = $0.segments else { return }
            stamp.rallies = segs
            $0.partialRender = stamp
        }
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
            progress[session.id] = .failed(failureText(error))
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
    /// - Parameters:
    ///   - caption: when set, replaces every session's own caption for this
    ///     reel. Nil keeps each session's, which is what building from the
    ///     session screen does.
    func buildReel(from pairs: [(session: Session, clip: ClipInfo)],
                   target: ReelTarget,
                   frame: OutputFrame = .vertical,
                   pace: ReelPace = .full,
                   preset: ReelPreset? = nil,
                   caption: CaptionSettings? = nil) async -> (url: URL, plan: ReelPlan)? {
        // The order is the caller's. ReelSheet seeds it by timeline and lets
        // the user drag rows around; sorting here again silently undid that
        // drag while the screen still said "Drag to reorder". `sources` is
        // recorded in this same order so a caption-only rebuild replays it.
        let ordered = pairs
        guard !ordered.isEmpty else { return nil }
        let key = ordered[0].session.id
        // Every session in the reel, not only the first: the others could be
        // re-rendered or trimmed under the build, renaming the files it reads.
        let involved = Set(ordered.map(\.session.id))
        guard !involved.contains(where: isBusy) else { return nil }
        for sid in involved { progress[sid] = .reel(done: 0, total: ordered.count) }
        // A reel re-renders every rally from its original, so it is the longest
        // job the app runs — and the one a user is most likely to walk away
        // from. Without this, switching to Instagram to wait killed it.
        let task = beginBackgroundTask()
        defer {
            for sid in involved { clearProgressUnlessFailed(sid) }
            endBackgroundTask(task)
        }
        // Read once, before the first await: a pass that ends while the
        // originals load must not make half the reel Pro and half free.
        let pro = isPro

        // one asset load per session, however many clips it contributes
        var assets: [UUID: AVAsset] = [:]
        var items: [ReelItem] = []
        for pair in ordered {
            let sid = pair.session.id
            if assets[sid] == nil {
                // All or nothing. Skipping a session whose original is gone
                // made a shorter reel without a word, and its sidecar still
                // listed the rallies that were never in it.
                guard let a = await loadAsset(pair.session) else {
                    progress[key] = .failed(missingMessage(sid))
                    return nil
                }
                assets[sid] = a
            }
            guard let asset = assets[sid] else { continue }
            let useSmartCrop = pro && pair.session.smartCropEnabled
            let base = caption ?? pair.session.caption
            let styled = preset?.applied(to: base) ?? base
            items.append(ReelItem(asset: asset,
                                  segment: pair.clip.segment,
                                  caption: CaptionText.resolve(
                                      styled, session: pair.session,
                                      segments: pair.session.segments ?? [],
                                      index: pair.clip.index, lang: lang),
                                  smartCrop: useSmartCrop,
                                  targetPlayer: useSmartCrop
                                      ? pair.session.target(forClip: pair.clip.index) : nil,
                                  sessionID: sid))
        }
        guard !items.isEmpty else {
            progress[key] = .failed(missingMessage(key))
            return nil
        }

        // A fresh id per reel: the old settings-derived name meant a second
        // reel with the same platform and pace replaced the first. Declared out
        // here so the catch can remove the sidecar it wrote.
        let id = "reel_" + UUID().uuidString.prefix(8).lowercased()
        let sources = ordered.map { ReelSource(sessionID: $0.session.id,
                                               clipIndex: $0.clip.index,
                                               start: $0.clip.segment.start,
                                               end: $0.clip.segment.end) }
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
                                       place: ordered.first?.session.placeName,
                                       sources: sources, caption: caption)
            try? JSONEncoder().encode(placeholder)
                .write(to: reelsDir.appendingPathComponent(id + ".json"), options: .atomic)
            let plan = try await ReelBuilder.build(
                items: items, target: target, frame: frame, pace: pace,
                pro: pro, to: out,
                reload: { [weak self] sid in
                    guard let self,
                          let s = self.sessions.first(where: { $0.id == sid }) else { return nil }
                    return await self.loadAsset(s)
                },
                waitUntilActive: {
                    while UIApplication.shared.applicationState == .background {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }) { [weak self] done, total in
                    for sid in involved { self?.progress[sid] = .reel(done: done, total: total) }
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
                                place: ordered.first?.session.placeName,
                                sources: sources, caption: caption)
            try? JSONEncoder().encode(info)
                .write(to: reelsDir.appendingPathComponent(id + ".json"), options: .atomic)
            objectWillChange.send()
            return (out, plan)
        } catch {
            // The sidecar is written before the video so a crash can't orphan
            // the file; a build that simply failed must take it with it.
            try? fm.removeItem(at: reelsDir.appendingPathComponent(id + ".json"))
            progress[key] = .failed(failureText(error))
            return nil
        }
    }

    /// Works out which rallies a reel was made from when its sidecar never
    /// recorded them.
    ///
    /// An old reel describes itself only by its settings and its length.
    /// Re-planning each session's rallies with those settings and comparing is
    /// enough to identify one: the planned duration is a fingerprint, exact to
    /// the millisecond, and planning touches no video files. A session that has
    /// been re-detected or trimmed since simply stops matching — which is the
    /// right answer, because rebuilding it from today's rallies would not be
    /// the reel the user is looking at.
    ///
    /// Returns nil when nothing matches, and also when more than one session
    /// does: two identical-length matches are indistinguishable, and guessing
    /// would rebuild the reel out of the wrong match.
    func recoverSources(for reel: ReelInfo) -> [ReelSource]? {
        if let known = reel.sources, !known.isEmpty { return known }
        let target = ReelTarget(rawValue: reel.target) ?? .reels
        let pace = ReelPace(rawValue: reel.pace) ?? .full

        func matches(among candidates: [Session]) -> [[ReelSource]] {
            var found: [[ReelSource]] = []
            for session in candidates {
                // A session imported after the reel was made cannot be in it.
                guard session.createdAt <= reel.createdAt.addingTimeInterval(60) else { continue }
                let ready = clips(of: session).filter(\.isReady)
                    .sorted { $0.segment.start < $1.segment.start }
                guard !ready.isEmpty else { continue }
                let planned = ReelBuilder.plan(segments: ready.map(\.segment),
                                               target: target, pace: pace).plan
                guard planned.used == reel.rallies,
                      abs(planned.duration - reel.duration) < 0.05 else { continue }
                found.append(ready.map {
                    ReelSource(sessionID: session.id, clipIndex: $0.index,
                               start: $0.segment.start, end: $0.segment.end)
                })
                if found.count > 1 { return found }
            }
            return found
        }

        // The court the reel recorded is the strongest discriminator: sessions
        // of the same shape plan to the same length, and on a phone that films
        // the same match every week that is the common case, not the corner.
        if let place = reel.place {
            let sameCourt = matches(among: sessions.filter { $0.placeName == place })
            if sameCourt.count == 1 { return sameCourt[0] }
        }
        let any = matches(among: sessions)
        return any.count == 1 ? any[0] : nil
    }

    /// The clip a reel source points at today. Matched by time: the rally that
    /// overlaps the recorded one the most, as long as it covers at least half
    /// of it — a trim still finds its rally, a deleted one finds nothing.
    private func clip(for source: ReelSource, in session: Session) -> ClipInfo? {
        let ready = clips(of: session).filter(\.isReady)
        guard let start = source.start, let end = source.end, end > start else {
            return ready.first { $0.index == source.clipIndex }
        }
        let best = ready.map { c -> (ClipInfo, Double) in
            (c, min(end, c.segment.end) - max(start, c.segment.start))
        }.max { $0.1 < $1.1 }
        guard let best, best.1 >= (end - start) * 0.5 else { return nil }
        return best.0
    }

    /// Rebuilds a finished reel with a different caption.
    ///
    /// The rally sources are re-resolved from the sidecar, so a session or a
    /// rally that has since been deleted stops the rebuild rather than
    /// producing a shorter reel than the one the user is looking at. The new
    /// reel is built under its own id and the old one is removed only once it
    /// has succeeded — a failed rebuild must not take the finished video with
    /// it.
    func rebuildReel(_ reel: ReelInfo,
                     caption: CaptionSettings?) async -> ReelInfo? {
        guard let sources = recoverSources(for: reel), !sources.isEmpty else { return nil }
        var pairs: [(session: Session, clip: ClipInfo)] = []
        for source in sources {
            guard let session = sessions.first(where: { $0.id == source.sessionID }) else {
                return nil
            }
            guard let clip = clip(for: source, in: session) else { return nil }
            pairs.append((session, clip))
        }
        guard await buildReel(from: pairs,
                              target: ReelTarget(rawValue: reel.target) ?? .reels,
                              frame: OutputFrame(reel.frame),
                              pace: ReelPace(rawValue: reel.pace) ?? .full,
                              preset: reel.preset.flatMap(ReelPreset.init(rawValue:)),
                              caption: caption) != nil
        else { return nil }
        deleteReel(reel)
        return reels().first
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

    /// Returns false when the session is busy and the clip was left alone —
    /// the player sheet used to close anyway, showing a "deleted" clip still
    /// in the list.
    @discardableResult
    func deleteClip(_ clip: ClipInfo) -> Bool {
        // The sheet holds a snapshot. If the rallies moved under it (re-detect,
        // a split elsewhere), the same index is now a different rally — refuse
        // rather than delete the wrong one.
        guard let seg = sessions.first(where: { $0.id == clip.sessionID })?
                .segments?[safe: clip.index],
              seg.start == clip.segment.start, seg.end == clip.segment.end,
              let s = sessions.first(where: { $0.id == clip.sessionID }) else { return false }
        // One path for both: the single delete used to skip the partial-render
        // stamp (next Apply re-rendered everything) and renamed onto existing
        // files without clearing them, misaligning clips with rallies.
        return deleteClips([clip.id], from: s)
    }
}


extension Array {
    /// Bounds-checked lookup: a clip index can outrun a freshly re-detected
    /// session, and a crash there would take the whole reel down.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
