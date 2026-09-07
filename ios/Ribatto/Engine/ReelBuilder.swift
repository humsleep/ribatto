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
            // the winning shot lands shortly before the rally's padded end
            var lead = segment
            lead.start = max(segment.start, segment.end - RallyDetector.padEndS - Self.hookLead)
            lead.end = min(segment.end, lead.start + Self.hookLead)
            return [lead, segment]
        }
    }

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
    case broadcast      // scoreboard bar up top
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
    /// The word after the number in the burned-in shot counter; nil = no counter.
    var counterLabel: String? = nil
    /// Running score to burn top-left; nil or empty = none.
    var scoreboard: String? = nil
}

/// What actually made it in, so the UI can be honest about a cap that bit.
struct ReelPlan: Equatable {
    var used = 0
    var dropped = 0
    var trimmed = false
    var duration: Double = 0
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
    static func plan(segments: [RallySegment],
                     target: ReelTarget,
                     pace: ReelPace) -> (plan: ReelPlan, pieces: [PlannedPiece]) {
        var pieces: [PlannedPiece] = []
        var plan = ReelPlan()
        var remaining = target.maxDuration ?? .greatestFiniteMagnitude
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
                      to output: URL,
                      progress: @MainActor @escaping (Int, Int) -> Void) async throws -> ReelPlan {
        guard !items.isEmpty else {
            throw NSError(domain: "Ribatto", code: 50,
                          userInfo: [NSLocalizedDescriptionKey: "Nothing to build"])
        }

        // 1) Decide what fits.
        let (plan, pieces) = Self.plan(segments: items.map(\.segment),
                                       target: target, pace: pace)
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
        for (i, entry) in planned.enumerated() {
            await progress(i, planned.count)
            let seg = RallySegment(start: entry.segment.start,
                                   end: entry.segment.start + entry.seconds,
                                   hits: entry.segment.hits,
                                   hitTimes: entry.item.segment.hitTimes)
            let part = work.appendingPathComponent(String(format: "part_%03d.mp4", i))
            try await ClipExporter.export(source: entry.item.asset,
                                          segment: seg,
                                          orientation: frame.rawValue,
                                          pro: pro,
                                          caption: entry.item.caption,
                                          smartCrop: entry.item.smartCrop,
                                          clipURL: part,
                                          thumbURL: nil,
                                          targetPlayer: entry.item.targetPlayer,
                                          counter: entry.item.counterLabel.flatMap {
                                              ShotCounter.make(for: seg, label: $0) },
                                          scoreboard: entry.item.scoreboard)
            parts.append(part)
        }
        await progress(planned.count, planned.count)

        // 3) One file. A single part needs no merge pass at all.
        try? FileManager.default.removeItem(at: output)
        if parts.count == 1 {
            try FileManager.default.moveItem(at: parts[0], to: output)
        } else {
            try await HighlightMerger.merge(clips: parts, to: output)
        }
        return plan
    }
}
