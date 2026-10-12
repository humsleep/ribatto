import AVFoundation
import Foundation

/// Where the finished vertical reel is headed. The only thing that actually
/// differs is the length each platform accepts in one upload.
enum ReelTarget: String, Codable, CaseIterable, Identifiable {
    case reels      // Instagram Reels
    case shorts     // YouTube Shorts
    case tiktok     // TikTok
    case full       // no cap — just make it vertical

    var id: String { rawValue }

    var maxDuration: Double? {
        switch self {
        case .reels:  return 90
        case .shorts: return 60
        case .tiktok: return 180
        case .full:   return nil
        }
    }

    var symbol: String {
        switch self {
        case .reels:  return "camera.aperture"
        case .shorts: return "play.rectangle.fill"
        case .tiktok: return "music.note"
        case .full:   return "rectangle.portrait"
        }
    }
}

/// How much of each rally to use.
///
/// A 30-shot rally becomes a 45-second clip, and Shorts retention falls off a
/// cliff long before that. These trade completeness for the shape short-form
/// actually rewards.
enum ReelPace: String, Codable, CaseIterable, Identifiable {
    case full       // the rally as detected
    case impact     // just the finish
    case hook       // the finish first, then the whole rally

    var id: String { rawValue }

    /// Seconds of the rally's end that count as "the finish" — roughly the
    /// last three or four shots at tennis pacing.
    static let impactTail = 6.0
    /// Length of the teaser a hook puts up front.
    static let hookLead = 0.8

    var symbol: String {
        switch self {
        case .full:   return "rectangle"
        case .impact: return "bolt.fill"
        case .hook:   return "arrow.uturn.left.circle.fill"
        }
    }

    /// What this pace turns one rally into: the pieces to render, in order.
    /// A hook is two pieces cut from the same rally.
    func pieces(of segment: RallySegment) -> [RallySegment] {
        let length = segment.duration
        switch self {
        case .full:
            return [segment]
        case .impact:
            guard length > Self.impactTail + 1 else { return [segment] }
            var tail = segment
            tail.start = segment.end - Self.impactTail
            return [tail]
        case .hook:
            guard length > Self.hookLead + 2 else { return [segment] }
            // The teaser ends on the winning shot: the last strike when the
            // detector kept them, else where the padding puts it. A reel's
            // rallies are cut to their strikes (`playTrimmed`), so their end
            // is no longer one padding past the last shot — measuring from it
            // put the teaser two seconds early, on a ball still in the air.
            let winner = segment.hitTimes?.filter { $0 > segment.start && $0 <= segment.end }.max()
                ?? segment.end - RallyDetector.padEndS
            var lead = segment
            lead.start = max(segment.start, winner - Self.hookLead)
            lead.end = min(segment.end, lead.start + Self.hookLead)
            return [lead, segment]
        }
    }

    /// Seconds of the rally kept before the first strike and after the last
    /// in a reel. Enough to see the serve toss and the ball land; the rest of
    /// the detector's padding is players walking.
    static let leadIn = 0.5
    static let tailOut = 1.5

    /// Seconds one rally contributes at this pace, for the estimate the sheet
    /// shows before committing the user to a render.
    func estimatedLength(of segment: RallySegment) -> Double {
        pieces(of: segment).reduce(0) { $0 + $1.duration }
    }
}

/// A named starting point for a reel: how each rally is cut, what shape it is
/// rendered into, and how the caption looks while it is in there.
///
/// A preset never touches what a caption SAYS — the text stays whatever the
/// session set, because that is the user's content. It only restyles it, so
/// trying a different look costs one tap and loses nothing.
enum ReelPreset: String, CaseIterable, Identifiable {
    case clean          // the rally, plainly
    case broadcast      // caption as a bar up top
    case highlight      // the finish, shouted
    case teaser         // hook first, feed-shaped

    var id: String { rawValue }

    var pace: ReelPace {
        switch self {
        case .clean, .broadcast: return .full
        case .highlight: return .impact
        case .teaser: return .hook
        }
    }

    /// 4:5 for the one meant to sit in a feed; 9:16 for the ones meant to fill
    /// a phone.
    var frame: OutputFrame {
        self == .teaser ? .portrait45 : .vertical
    }

    /// The look laid over each session's own caption.
    var look: (style: CaptionStyle, color: CaptionColor, font: CaptionFont,
               size: Double, y: Double) {
        switch self {
        case .clean:
            return (.plain, .white, .rounded, 1.00, 0.90)
        case .broadcast:
            return (.accent, .volt, .bebas, 1.05, 0.11)
        case .highlight:
            return (.outline, .sun, .anton, 1.30, 0.15)
        case .teaser:
            return (.bar, .rose, .anton, 1.15, 0.86)
        }
    }

    /// The session's caption, restyled. Returns nil when there was no caption
    /// to restyle, so a preset never puts words on a clip that had none.
    func applied(to caption: CaptionSettings?) -> CaptionSettings? {
        guard var c = caption else { return nil }
        let l = look
        c.style = l.style
        c.color = l.color
        c.font = l.font
        c.size = l.size
        c.y = l.y
        c.x = 0.5
        return c
    }
}

/// One rally to put in the reel, described by where it came from rather than
/// by the clip file — going back to the original lets the vertical framing be
/// computed from full-width footage instead of re-cropping a finished crop.
struct ReelItem {
    let asset: AVAsset
    let segment: RallySegment
    let caption: CaptionSettings?
    let smartCrop: Bool
    let targetPlayer: TargetPlayer?
    /// Which session the asset came from, so a dead one can be reloaded.
    var sessionID: UUID? = nil
    /// The reel's opening title if this rally ends up first. Per item, because
    /// the first rally asked for is not always the first one placed — one too
    /// short for the cap is dropped, and the title must describe what plays.
    var hookTitle: (line1: String, line2: String?)? = nil
}

/// What actually made it in, so the UI can be honest about a cap that bit.
struct ReelPlan: Equatable {
    var used = 0
    var dropped = 0
    var trimmed = false
    var duration: Double = 0
    /// The slow winning-shot replay made it in.
    var replayed = false
}

enum ReelBuilder {

    /// The least of a rally that still counts as having made the reel.
    static let minPlacedSeconds = 1.0

    /// One piece of the running order: which rally it came from, the part of
    /// that rally to take, and how many seconds of it survive the cap.
    struct PlannedPiece {
        let rally: Int
        let segment: RallySegment
        let seconds: Double
    }

    /// What would go into a reel, without touching a single video file.
    ///
    /// Rallies are taken in order; the piece that straddles the limit is
    /// trimmed, and anything after it is reported as dropped rather than
    /// silently discarded. `dropped` counts rallies, not pieces, so the number
    /// matches what the user picked.
    ///
    /// Separate from `build` because the answer is worth having on its own: it
    /// is how a finished reel whose sidecar predates source tracking is matched
    /// back to the rallies it was made from.
    /// `reserve` is held back from the platform cap for something appended
    /// after the rallies — the slow replay — so the finished reel still fits.
    static func plan(segments: [RallySegment],
                     target: ReelTarget,
                     pace: ReelPace,
                     reserve: Double = 0) -> (plan: ReelPlan, pieces: [PlannedPiece]) {
        var pieces: [PlannedPiece] = []
        var plan = ReelPlan()
        var remaining = (target.maxDuration ?? .greatestFiniteMagnitude) - reserve
        for (i, segment) in segments.enumerated() {
            let before = pieces.count
            var placed = 0.0
            for piece in pace.pieces(of: segment) {
                let length = piece.duration
                if remaining <= 0.5 { break }
                if length > remaining {
                    pieces.append(PlannedPiece(rally: i, segment: piece, seconds: remaining))
                    plan.trimmed = true
                    placed += remaining
                    remaining = 0
                } else {
                    pieces.append(PlannedPiece(rally: i, segment: piece, seconds: length))
                    placed += length
                    remaining -= length
                }
            }
            // A sliver is not a rally. Under `hook` the first piece is a 0.8s
            // lead, so a cap that ran out mid-lead used to leave a sub-second
            // flash on the end of the reel and still count it in "3 rallies".
            // Below a second it is dropped instead.
            if placed >= minPlacedSeconds {
                plan.used += 1
            } else {
                pieces.removeSubrange(before...)
                remaining += placed
                plan.dropped += 1
            }
        }
        plan.duration = pieces.reduce(0) { $0 + $1.seconds }
        return (plan, pieces)
    }

    /// Renders each rally vertically from its original source, then joins them.
    ///
    /// Re-rendering rather than concatenating the existing clips costs time but
    /// is the only way a wide session can become a good vertical reel: the
    /// rally-centred crop needs the full frame to choose from, and a clip that
    /// has already been cropped no longer has it.
    static func build(items: [ReelItem],
                      target: ReelTarget,
                      frame: OutputFrame = .vertical,
                      pace: ReelPace = .full,
                      pro: Bool,
                      hook: Bool = false,
                      replay: Bool = false,
                      to output: URL,
                      reload: ((UUID) async -> AVAsset?)? = nil,
                      waitUntilActive: (@MainActor () async -> Void)? = nil,
                      progress: @MainActor @escaping (Int, Int) -> Void) async throws -> ReelPlan {
        guard !items.isEmpty else {
            throw NSError(domain: "Ribatto", code: 50,
                          userInfo: [NSLocalizedDescriptionKey: "Nothing to build"])
        }

        // 1) Decide what fits.
        let (plan, pieces) = Self.plan(segments: items.map(\.segment),
                                       target: target, pace: pace,
                                       reserve: replay ? replaySeconds : 0)
        let planned = pieces.map { (item: items[$0.rally], segment: $0.segment,
                                    seconds: $0.seconds) }

        // Every rally dropped means there is nothing to merge, and
        // `HighlightMerger` asserts on an empty list — a trap the caller's
        // catch cannot see. Fail as an error instead.
        guard !planned.isEmpty else {
            throw NSError(domain: "Ribatto", code: 22, userInfo:
                            [NSLocalizedDescriptionKey: "No rally was long enough to include"])
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 2) Render every piece to the chosen portrait frame.
        var parts: [URL] = []
        // Assets replaced after a failure. When the media server resets, the
        // asset every remaining piece of that session shares is dead, so
        // without this one failure took the rest of the reel with it.
        var fresh: [UUID: AVAsset] = [:]
        // Where each part starts in the finished reel, for the hook title.
        var elapsed = 0.0
        for (i, entry) in planned.enumerated() {
            // From the rally that actually opens the reel.
            let partHook = (hook ? planned.first?.item.hookTitle : nil)
                .flatMap { h -> ClipExporter.ReelHook? in
                    elapsed < ClipExporter.hookShown + ClipExporter.hookFade
                        ? ClipExporter.ReelHook(line1: h.line1, line2: h.line2, startsAt: elapsed)
                        : nil
                }
            elapsed += entry.seconds
            await progress(i, planned.count)
            let seg = RallySegment(start: entry.segment.start,
                                   end: entry.segment.start + entry.seconds,
                                   hits: entry.segment.hits,
                                   hitTimes: entry.item.segment.hitTimes)
            let part = work.appendingPathComponent(String(format: "part_%03d.mp4", i))
            let sid = entry.item.sessionID
            func attempt(_ asset: AVAsset) async throws {
                try await ClipExporter.export(source: asset,
                                              segment: seg,
                                              orientation: frame.rawValue,
                                              pro: pro,
                                              caption: entry.item.caption,
                                              smartCrop: entry.item.smartCrop,
                                              clipURL: part,
                                              thumbURL: nil,
                                              targetPlayer: entry.item.targetPlayer,
                                              hook: partHook)
            }
            let asset = sid.flatMap { fresh[$0] } ?? entry.item.asset
            // Encoding is GPU work iOS refuses in the background. Each piece
            // waits for the app to come back instead of failing — leaving to
            // check Instagram mid-build used to throw the whole reel away.
            await waitUntilActive?()
            do {
                try await attempt(asset)
            } catch {
                guard let sid, let reload else { throw error }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await waitUntilActive?()
                guard let replacement = await reload(sid) else { throw error }
                fresh[sid] = replacement
                try await attempt(replacement)
            }
            parts.append(part)
        }
        // 2b) The winning shot again, slowly — after the last rally only, so
        // the reel stays short. Never fatal: a reel without the replay beats
        // no reel.
        var result = plan
        if replay, let last = planned.last {
            let sid = last.item.sessionID
            let part = work.appendingPathComponent("part_replay.mp4")
            func attempt(_ asset: AVAsset) async throws -> Double? {
                try await slowReplay(of: last.item, piece: last.segment,
                                     seconds: last.seconds, asset: asset,
                                     frame: frame, pro: pro, to: part)
            }
            // The same care as a rally part: wait for the foreground, and one
            // retry on a fresh asset if the media server went away.
            await waitUntilActive?()
            var added: Double?
            do {
                added = try await attempt(sid.flatMap { fresh[$0] } ?? last.item.asset)
            } catch {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await waitUntilActive?()
                if let sid, let reload, let replacement = await reload(sid) {
                    fresh[sid] = replacement
                    added = try? await attempt(replacement)
                }
            }
            if let added {
                parts.append(part)
                result.duration += added
                result.replayed = true
            }
        }
        await progress(planned.count, planned.count)

        // 3) One file. A single part needs no merge pass at all.
        try? FileManager.default.removeItem(at: output)
        if parts.count == 1 {
            try FileManager.default.moveItem(at: parts[0], to: output)
        } else {
            try await HighlightMerger.merge(clips: parts, to: output)
        }
        return result
    }
}

extension ReelBuilder {
    /// Seconds either side of the winning shot in the replay, and its speed.
    static let replayHalfSpan = 0.8
    static let replayRate = 0.5
    /// Below this the slowed frames stutter: half speed of 30 fps is 15.
    static let replayMinFPS: Float = 50
    /// Seconds a replay adds to a reel.
    static var replaySeconds: Double { replayHalfSpan * 2 / replayRate }

    /// Renders the last strike of `piece` at half speed into `url` and returns
    /// its length, or nil when there is nothing to replay — no strike times,
    /// or footage under 50 fps.
    ///
    /// The slowing is a composition scaled in time, handed to the exporter
    /// like any source, so the frame, watermark and caption match the rest of
    /// the reel. Video only: half-speed audio is a groan, and the reel's
    /// sound simply pauses for it.
    static func slowReplay(of item: ReelItem, piece: RallySegment, seconds: Double,
                           asset: AVAsset, frame: OutputFrame, pro: Bool,
                           to url: URL) async throws -> Double? {
        // The rally's real last strike, and only if it made the reel: when
        // the cap cut the final piece short, an earlier strike would be
        // replayed as "the winning shot".
        let end = piece.start + seconds
        guard let hit = item.segment.hitTimes?
                .filter({ $0 >= item.segment.start && $0 <= item.segment.end }).max(),
              hit >= piece.start, hit <= end,
              let track = try await asset.loadTracks(withMediaType: .video).first,
              try await track.load(.nominalFrameRate) >= replayMinFPS else { return nil }
        let total = try await asset.load(.duration).seconds
        let from = max(0, hit - replayHalfSpan)
        let to = min(total, hit + replayHalfSpan)
        guard to - from > 0.4 else { return nil }
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let source = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                 end: CMTime(seconds: to, preferredTimescale: 600))
        try video.insertTimeRange(source, of: track, at: .zero)
        video.preferredTransform = try await track.load(.preferredTransform)
        let slowed = (to - from) / replayRate
        comp.scaleTimeRange(CMTimeRange(start: .zero, duration: source.duration),
                            toDuration: CMTime(seconds: slowed, preferredTimescale: 600))
        // The composition's own clock: the winning shot sits at its middle.
        let seg = RallySegment(start: 0, end: slowed, hits: 0)
        // A picked player is followed here too, on the replay's own clock:
        // the tracker seeds at the start of `seg`, which is the composition's
        // zero. Its usual reacquisition finds them if they moved since.
        try await ClipExporter.export(source: comp, segment: seg,
                                      orientation: frame.rawValue, pro: pro,
                                      caption: item.caption, smartCrop: item.smartCrop,
                                      clipURL: url, thumbURL: nil,
                                      targetPlayer: item.smartCrop ? item.targetPlayer : nil)
        return slowed
    }
}

extension RallySegment {
    /// The rally cut to its strikes for a reel: from just before the first to
    /// just after the last. The detector pads every rally by 2 s in front and
    /// 3.5 s behind, which suits a clip someone scrubs through and is dead air
    /// in a 30-second reel. Clips are unchanged. Left whole with fewer than
    /// two strikes — one hit is no evidence of where the point starts.
    var playTrimmed: RallySegment {
        let hits = (hitTimes ?? []).filter { $0 >= start && $0 <= end }.sorted()
        guard hits.count >= 2, let first = hits.first, let last = hits.last else { return self }
        var cut = self
        cut.start = max(start, first - ReelPace.leadIn)
        cut.end = min(end, last + ReelPace.tailOut)
        return cut.end - cut.start > 1 ? cut : self
    }
}
