import CoreGraphics
import Foundation

// MARK: - Sport

enum Sport: String, Codable, CaseIterable, Identifiable {
    case tennis, badminton, pickleball, padel
    var id: String { rawValue }

    /// Impact-sound frequency band (Hz). Racquet-string impacts sit higher
    /// than paddle "pops"; badminton exchanges are faster than tennis points.
    var band: (lo: Float, hi: Float) {
        switch self {
        case .tennis:     return (1500, 7000)
        case .badminton:  return (2000, 7800)
        case .pickleball, .padel: return (700, 4500)
        }
    }
    /// The shortest interval two strikes of the *same* exchange can have. The
    /// ball has to cross the court and come back, so anything faster is two
    /// sources — the usual one being the next court over, whose strikes
    /// interleave with ours. Measured on a courtside recording: pairs 0.15 s
    /// apart appeared inside a rally whose own strikes were 0.8–2 s apart.
    var minExchangeS: Double {
        switch self {
        case .tennis: return 0.30
        case .badminton: return 0.22
        case .pickleball, .padel: return 0.28
        }
    }
    /// Max in-rally gap between hits (s).
    var gap: Double {
        switch self {
        case .tennis: return 3.5
        case .badminton: return 2.5
        case .pickleball, .padel: return 3.0
        }
    }
    /// Rallies closer than this are merged (s).
    var mergeGap: Double {
        switch self {
        case .tennis: return 5.0
        case .badminton: return 4.0
        case .pickleball, .padel: return 4.5
        }
    }
    var emoji: String {
        switch self {
        case .tennis, .padel: return "🎾"
        case .badminton: return "🏸"
        case .pickleball: return "🥎"
        }
    }
}

// MARK: - Sensitivity

enum Sensitivity: String, Codable, CaseIterable, Identifiable {
    case low, normal, high
    var id: String { rawValue }

    /// (loose flux percentile, strong flux percentile, min hit span s, min hits)
    var params: (loosePct: Double, strongPct: Double, minSpan: Double, minHits: Int) {
        switch self {
        case .high:   return (98.5, 99.3, 1.2, 3)
        case .normal: return (99.0, 99.5, 2.0, 3)
        case .low:    return (99.3, 99.6, 3.0, 4)
        }
    }
}

// MARK: - Aspect

enum AspectSetting: String, Codable, CaseIterable, Identifiable {
    case auto, landscape, vertical, portrait45
    var id: String { rawValue }
}

/// The shape a clip is rendered into. Carried around as a string because
/// `Session.renderedOrientation` has always been one, and sessions saved
/// before 4:5 existed still have to decode.
///
/// Why 4:5 is here: a 9:16 crop of a 16:9 source keeps only
/// (9/16)÷(16/9) = 31.6% of its width. Rendering a real rally both ways put the
/// opponent at 96% of that width — inside the frame, but on its edge, and gone
/// the moment either player moves. 4:5 keeps 45% and leaves real margin, which
/// is what a doubles or baseline-to-baseline exchange needs.
enum OutputFrame: String {
    case landscape      // 16:9
    case vertical       // 9:16
    case portrait45     // 4:5

    /// Unknown strings fall back to landscape, matching the old default.
    init(_ raw: String?) { self = OutputFrame(rawValue: raw ?? "") ?? .landscape }

    /// width : height of the rendered frame.
    var ratio: (w: CGFloat, h: CGFloat) {
        switch self {
        case .landscape:  return (16, 9)
        case .vertical:   return (9, 16)
        case .portrait45: return (4, 5)
        }
    }

    /// Taller than wide, so the crop cuts horizontally and panning/tracking
    /// have something to choose.
    var isPortrait: Bool { self != .landscape }

    /// How much of a 16:9 source's width survives this crop.
    var widthKeptFrom169: CGFloat { (ratio.w / ratio.h) / (16.0 / 9.0) }

    /// width ÷ height, for SwiftUI's `.aspectRatio`.
    var aspectRatio: CGFloat { ratio.w / ratio.h }

    var label: String {
        switch self {
        case .landscape:  return "16:9"
        case .vertical:   return "9:16"
        case .portrait45: return "4:5"
        }
    }
}

// MARK: - Rally segment

struct RallySegment: Codable, Equatable {
    var start: Double
    var end: Double
    var hits: Int
    /// How good a point this looked, 0…1, from shot count, crowd reaction and
    /// length. nil on rallies detected before scoring existed — sorting treats
    /// those as unscored rather than as zero.
    var score: Double? = nil
    /// True once the user has dragged the trim handles, so a re-detect knows
    /// not to quietly throw their edit away.
    var trimmed: Bool? = nil
    /// When each strike landed, in source seconds. nil on rallies detected
    /// before this was kept. Drives the burned-in shot counter and survives a
    /// trim, which only moves `start`/`end`.
    var hitTimes: [Double]? = nil
    /// Crowd reaction right after the point: peak voice-band energy over the
    /// rally's own median, so 1 is silence and 2 is a clear shout. nil before
    /// it was kept.
    var cheer: Double? = nil
    /// Peak band level of each strike, parallel to `hitTimes`. Kept so a count
    /// the user corrects drops the quietest strikes rather than the last ones.
    var hitStrengths: [Double]? = nil
    /// Set when the strikes fall into two clearly separated loudness groups.
    /// That is what a second court audible in the recording looks like: our own
    /// strikes in one group, theirs — quieter, from further away — in the
    /// other. The count is not trustworthy while it holds.
    var hitsUncertain: Bool? = nil
    /// The count the user typed after checking the clip. It wins over anything
    /// detection has to say, and settles the uncertainty above.
    var hitsOverride: Int? = nil

    var duration: Double { end - start }

    /// What the app should show and burn in: what the user said, else what was
    /// detected.
    var effectiveHits: Int { hitsOverride ?? hits }

    /// True while the detector's count is in doubt and nobody has corrected it.
    var countIsUncertain: Bool { (hitsUncertain ?? false) && hitsOverride == nil }

    /// Strike times to drive the burned-in counter with, or nil to leave the
    /// counter off. Two sources mixed together means a wrong number, and a
    /// wrong number burned into a video is worse than no number.
    var counterTimes: [Double]? {
        guard let all = hitTimes, !all.isEmpty else { return nil }
        guard let want = hitsOverride else { return countIsUncertain ? nil : all }
        if want >= all.count { return all }
        guard want > 0 else { return [] }
        // Drop the quietest strikes first — those are the ones that came from
        // somewhere else. Without levels, thin the list evenly so the counter
        // still climbs across the whole rally.
        if let str = hitStrengths, str.count == all.count {
            let keep = Set(zip(all, str).sorted { $0.1 > $1.1 }.prefix(want).map(\.0))
            return all.filter { keep.contains($0) }
        }
        let step = Double(all.count) / Double(want)
        return (0..<want).map { all[min(all.count - 1, Int(Double($0) * step))] }
    }

    /// Loud enough to badge. The detector's own scoring already normalises
    /// within a session; this absolute floor is for "the crowd actually
    /// reacted". On a 26-minute courtside doubles the ratios ran 1.1–5.1 with
    /// a median near 3, so 3.5 badges the top third rather than every point.
    var isLoud: Bool { (cheer ?? 0) >= RallySegment.loudCheer }
    static let loudCheer = 3.5

    /// Strikes per minute of actual play — the padding the detector adds at
    /// each end is not play, so it comes off before the rate is taken. nil
    /// when there is too little rally to say anything honest.
    var tempo: Double? {
        let played = duration - RallyDetector.padStartS - RallyDetector.padEndS
        guard played >= 2, effectiveHits >= 2 else { return nil }
        return Double(effectiveHits) / played * 60
    }

    /// Who won the point, when the user has said. Scoring stays blank until
    /// then rather than guessing: a wrong score is worse than no score.
    var winner: PointWinner? {
        get { PointWinner(rawValue: winnerRaw ?? "") }
        set { winnerRaw = newValue?.rawValue }
    }
    /// Stored as a string so a future value can't fail to decode.
    var winnerRaw: String? = nil
    /// Starred by the user, for the one clip out of forty worth finding again.
    var favourite: Bool? = nil
    var isFavourite: Bool { favourite ?? false }
}

/// Which side took the point. "Me" is whoever is holding the phone's session —
/// doubles teams count as one side, which is what a shared reel needs.
enum PointWinner: String, Codable, CaseIterable, Identifiable {
    case me, them
    var id: String { rawValue }
    var key: String { self == .me ? "winner_me" : "winner_them" }
    var other: PointWinner { self == .me ? .them : .me }
}

// MARK: - Target player

/// A specific person the user picked to keep centred when a wide match is
/// cropped to vertical — the "that's me" of a personal highlight reel.
///
/// The box is normalized (0…1 on each axis) in the source's *display* space:
/// after `preferredTransform`, origin at the top-left. That's the same space
/// `SmartCrop`/`PlayerTracker` and the picker UI all work in, so it survives a
/// change of resolution and needs no rotation handling downstream.
struct TargetPlayer: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// Source time (s) of the frame the box was drawn on. The tracker seeds
    /// from the nearest sampled frame and walks outward.
    var pickedAt: Double

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(rect: CGRect, pickedAt: Double) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
        self.pickedAt = pickedAt
    }
}


// MARK: - Caption

enum CaptionStyle: String, Codable, CaseIterable, Identifiable {
    case plain      // tinted text with a soft shadow
    case bar        // tinted text on a translucent black pill
    case accent     // solid pill in the chosen colour, text inverted onto it
    case outline    // tinted text with a hard contrasting edge
    var id: String { rawValue }
}

/// The palette a caption can be tinted with.
///
/// Fixed swatches rather than a free colour picker: each of these was chosen to
/// stay legible burned over court video — grass, hard court and sky all sit in
/// the middle of the range — and to survive a platform re-encode, which eats
/// saturated reds and thin strokes first.
enum CaptionColor: String, Codable, CaseIterable, Identifiable {
    case white, volt, sun, sky, rose, ink
    var id: String { rawValue }

    /// Components in 0…1, matching `Theme` where they overlap.
    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .white: return (1.000, 1.000, 1.000)
        case .volt:  return (0.784, 0.965, 0.243)
        case .sun:   return (1.000, 0.780, 0.200)
        case .sky:   return (0.350, 0.720, 1.000)
        case .rose:  return (1.000, 0.420, 0.520)
        case .ink:   return (0.050, 0.060, 0.080)
        }
    }

    /// Bright enough that anything drawn on top of it has to be dark.
    var isLight: Bool {
        let c = rgb
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > 0.6
    }
}

enum CaptionFont: String, Codable, CaseIterable, Identifiable {
    case system     // SF Pro Heavy — neutral
    case condensed  // narrow and loud, the broadcast-graphic look
    case rounded    // SF Rounded — friendly, reads well on video
    case mono       // SF Mono — good for times and scores
    case serif      // New York — editorial
    case anton      // Anton — the poster-weight sans reels are built on
    case bebas      // Bebas Neue — tall condensed caps, scoreboard energy
    var id: String { rawValue }

    /// PostScript name of the bundled face, or nil for a system one.
    ///
    /// Neither bundled face carries Hangul or Kana; CoreText and SwiftUI both
    /// substitute a system font for the glyphs they lack, so a Korean caption
    /// set in Anton renders rather than showing tofu.
    var bundledName: String? {
        switch self {
        case .anton: return "Anton-Regular"
        case .bebas: return "BebasNeue-Regular"
        default: return nil
        }
    }
}

struct CaptionSettings: Codable, Equatable {
    var enabled = false
    var text = ""
    /// A filled pill in ink, white letters — the default has to be readable
    /// over footage nobody screened. A translucent bar takes its contrast from
    /// whatever is behind it: white text on it measures 4.8:1 against a blown
    /// out sky and 18:1 against an indoor court, and the sky is the one people
    /// film. Filled, it is 19:1 everywhere. The picker still offers the bar for
    /// anyone who would rather see the court through it.
    var style: CaptionStyle = .accent
    var color: CaptionColor = .ink
    var font: CaptionFont = .rounded
    /// font size multiplier, 1.0 = 4.5% of the frame height
    var size: Double = 1.0
    /// centre of the caption, normalized in the frame with y measured from the
    /// top, so it can sit anywhere the user drags it
    var x: Double = 0.5
    var y: Double = 0.88

    var isVisible: Bool { enabled && !text.trimmingCharacters(in: .whitespaces).isEmpty }

    init() {}

    /// Hand-written so captions saved before free positioning existed still
    /// decode — a throw here would take the whole session down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        // Deliberately not the property defaults above: a caption written
        // before these keys existed looked like a translucent bar in white, and
        // changing what the app defaults to must not restyle it.
        style = try c.decodeIfPresent(CaptionStyle.self, forKey: .style) ?? .bar
        color = try c.decodeIfPresent(CaptionColor.self, forKey: .color) ?? .white
        font = try c.decodeIfPresent(CaptionFont.self, forKey: .font) ?? .rounded
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1.0
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.88
    }
}

// MARK: - Session

struct Session: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// When the video was imported into the app.
    var createdAt: Date
    /// When the match was actually filmed, from the video's own metadata.
    /// nil on sessions imported before this was read, and on sources that
    /// carry no capture date at all.
    var capturedAt: Date? = nil
    var duration: Double
    var width: Int
    var height: Int
    var sport: Sport = .tennis
    var sensitivity: Sensitivity = .normal
    var aspect: AspectSetting = .auto
    var segments: [RallySegment]? = nil
    var renderedOrientation: String? = nil   // OutputFrame raw value
    /// nil on sessions rendered before tiered export existed = free tier
    var renderedPro: Bool? = nil
    /// what the current segments were detected with — nil = never detected
    var detectedSport: Sport? = nil
    var detectedSensitivity: Sensitivity? = nil
    /// user-composed caption burned into the clips
    /// Photos asset this session reads from. When set the video is never
    /// copied into the app — a 30-minute 4K match would cost ~8 GB twice over.
    var assetIdentifier: String? = nil
    /// Where the match was filmed, read from the video's own metadata.
    var latitude: Double? = nil
    var longitude: Double? = nil
    var placeName: String? = nil
    var caption: CaptionSettings? = nil
    var renderedCaption: CaptionSettings? = nil
    /// Pro: follow the players when cropping to vertical. nil = on by default.
    var smartCrop: Bool? = nil
    var renderedSmartCrop: Bool? = nil
    /// Pro: burn a running strike count into every clip. nil = off.
    var shotCounter: Bool? = nil
    var renderedShotCounter: Bool? = nil
    /// Who the match was against, as the user typed it. Free text rather than a
    /// contact: no account, no permissions, and "Wednesday group" is a real
    /// answer. Powers per-opponent stats and the {opponent} caption token.
    var opponent: String? = nil
    /// Burn a running game score into the clips. Needs at least one tagged
    /// point to show anything.
    var scoreboard: Bool? = nil
    var renderedScoreboard: Bool? = nil
    /// Pro: one specific person to keep centred in the vertical crop. nil means
    /// use SmartCrop's aggregate-motion framing. Only takes effect on a vertical
    /// crop of a wider source, with smart crop on.
    var targetPlayer: TargetPlayer? = nil
    var renderedTargetPlayer: TargetPlayer? = nil
    /// Per-clip overrides of `targetPlayer`, keyed by clip index as a string
    /// (an Int-keyed dictionary encodes as a flat array, which is unreadable
    /// in the session file). A clip with no entry follows the session-wide
    /// choice: picking once covers the whole match, and only a rally where the
    /// wrong person was followed needs re-pointing.
    ///
    /// Optional, not a defaulted dictionary: the synthesized decoder calls
    /// plain `decode` for a non-optional property, so adding one throws on
    /// every session file written before it existed — and a throw here loses
    /// the whole session, exactly as `CaptionSettings` warns.
    var clipTargets: [String: TargetPlayer]?
    var renderedClipTargets: [String: TargetPlayer]?
    /// The winner tags as they were when the clips were last rendered, so
    /// re-tagging a point is recognised as a change that needs a re-render.
    /// Raw strings, empty for an untagged rally.
    var renderedWinners: [String]? = nil

    /// The player to follow in one clip: its own override, else the session's.
    func target(forClip index: Int) -> TargetPlayer? {
        clipTargets?[String(index)] ?? targetPlayer
    }

    /// True when the last detection returned no rallies at all. On disk that
    /// is indistinguishable from the user having deleted every clip, and the
    /// two need different empty states — one is advice about detection, the
    /// other is not.
    var detectionFoundNothing: Bool? = nil
    /// True once a failed detection has handed its free import back, so a
    /// re-detect on the same session cannot claim another one.
    var importRefunded: Bool? = nil

    var smartCropEnabled: Bool { smartCrop ?? true }
    var shotCounterEnabled: Bool { shotCounter ?? false }
    var scoreboardEnabled: Bool { scoreboard ?? false }
    /// Points the user has actually judged. The scoreboard needs one before it
    /// can say anything.
    var taggedPoints: Int { (segments ?? []).filter { $0.winner != nil }.count }
    var winnerTags: [String] { (segments ?? []).map { $0.winnerRaw ?? "" } }

    /// 1-based place of a clip when the session's rallies are ranked by score;
    /// nil when the rally was detected before scoring existed.
    func rank(ofClip index: Int) -> Int? {
        guard let segs = segments, index < segs.count, segs[index].score != nil else { return nil }
        let order = segs.indices.sorted { (segs[$0].score ?? -1) > (segs[$1].score ?? -1) }
        return (order.firstIndex(of: index) ?? index) + 1
    }
    var hasHighlight: Bool = false

    /// The date the user means when they say "that match" — the day they
    /// played, not the evening they got round to importing it. Everything
    /// user-facing (cards, stats, sorting) reads this.
    var playedAt: Date { capturedAt ?? createdAt }

    /// True when the import happened on a different day than the match, which
    /// is the only case where showing both dates tells the user anything.
    var importDiffersFromCapture: Bool {
        guard let capturedAt else { return false }
        return !Calendar.current.isDate(capturedAt, inSameDayAs: createdAt)
    }

    var sourceOrientation: String { height > width ? "vertical" : "landscape" }
    var effectiveOrientation: String {
        aspect == .auto ? sourceOrientation : aspect.rawValue
    }

    /// Settings changed since the clips were made — needs a re-detect.
    var needsRedetect: Bool {
        guard segments != nil else { return false }
        return detectedSport != sport || detectedSensitivity != sensitivity
    }

    /// Only the aspect changed — a re-render is enough, no re-detect.
    var needsRerender: Bool {
        guard segments != nil, !needsRedetect else { return false }
        return renderedOrientation != effectiveOrientation
            || (renderedCaption ?? CaptionSettings()) != (caption ?? CaptionSettings())
            // Compared against what the last render was ALLOWED to do. A free
            // render can never satisfy a Pro flag, so comparing the raw setting
            // left every free session permanently claiming unapplied changes
            // and re-encoding on every press.
            || (proRendered && (renderedSmartCrop ?? false) != effectiveSmartCrop)
            || (proRendered && (renderedShotCounter ?? false) != shotCounterEnabled)
            || (proRendered && (renderedScoreboard ?? false) != scoreboardEnabled)
            || (proRendered && scoreboardEnabled && renderedWinners != winnerTags)
            || (proRendered && effectiveSmartCrop && renderedTargetPlayer != targetPlayer)
            || (proRendered && effectiveSmartCrop
                && (renderedClipTargets ?? [:]) != (clipTargets ?? [:]))
    }

    /// Whether the last render ran with Pro. The Pro-only settings are compared
    /// only when it did: a free render legitimately ignores them, so treating
    /// the difference as "unapplied" made the banner permanent.
    private var proRendered: Bool { renderedPro ?? false }

    /// Smart crop only does something on a portrait crop of a wider source —
    /// 4:5 crops horizontally too, so it counts.
    var effectiveSmartCrop: Bool {
        smartCropEnabled && OutputFrame(effectiveOrientation).isPortrait
    }

    var hasPendingChanges: Bool { needsRedetect || needsRerender }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, capturedAt, duration, width, height,
             sport, sensitivity, aspect, segments, renderedOrientation,
             renderedPro, detectedSport, detectedSensitivity,
             assetIdentifier, latitude, longitude, placeName,
             caption, renderedCaption,
             smartCrop, renderedSmartCrop, detectionFoundNothing, importRefunded,
             shotCounter, renderedShotCounter,
             opponent, scoreboard, renderedScoreboard, renderedWinners,
             targetPlayer, renderedTargetPlayer,
             clipTargets, renderedClipTargets, hasHighlight
    }
}

// MARK: - Processing state

enum ProcessingStage: Equatable {
    case queued
    case audio
    case detect
    case render(done: Int, total: Int)
    case merge
    case reel(done: Int, total: Int)
    case failed(String)
}

// MARK: - Finished reels

/// A reel the user built and the app kept.
///
/// Reels are the app's headline output, so they get a record of their own
/// rather than living as anonymous files: the Reels tab needs to show what a
/// reel is without decoding the video, and the user needs to be able to delete
/// one when storage fills.
struct ReelInfo: Codable, Identifiable, Equatable {
    let id: String
    let createdAt: Date
    /// `ReelTarget` / `OutputFrame` / `ReelPace` raw values, kept as strings so
    /// a future case can't fail to decode an old sidecar.
    let target: String
    let frame: String
    let pace: String
    let preset: String?
    let rallies: Int
    let duration: Double
    /// Court of the first session that went in, when it had one.
    let place: String?
    /// The rallies this reel was built from, so it can be built again with a
    /// different caption instead of asking the user to pick the clips twice.
    /// Optional: reels made before this existed have no record of their source.
    var sources: [ReelSource]? = nil
    /// The caption burned into this reel, when it was given one here rather
    /// than inherited from each session.
    var caption: CaptionSettings? = nil

    // Filled in when listed; never written to the sidecar.
    var url: URL = URL(fileURLWithPath: "/")
    var thumbURL: URL = URL(fileURLWithPath: "/")
    var bytes: Int64 = 0

    /// True when this reel remembers where its rallies came from, which is what
    /// re-rendering it needs.
    var canRebuild: Bool { !(sources ?? []).isEmpty }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, target, frame, pace, preset, rallies, duration, place
        case sources, caption
    }
}

/// One rally inside a reel, addressed the way it can still be found later: by
/// its session and its index in that session's segments.
struct ReelSource: Codable, Equatable {
    let sessionID: UUID
    let clipIndex: Int
}
