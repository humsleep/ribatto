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
    /// before this was kept. Survives a trim, which only moves `start`/`end`.
    var hitTimes: [Double]? = nil
    /// Crowd reaction right after the point: peak voice-band energy over the
    /// rally's own median, so 1 is silence and 2 is a clear shout. nil before
    /// it was kept.
    var cheer: Double? = nil
    /// `SoundCheck`'s confidence that the rally sounds like racket play, 0…1.
    /// nil on rallies from before it existed, or where it could not run.
    var racketConf: Double? = nil
    /// `SoundCheck`'s confidence of a crowd reaction — cheering, applause,
    /// laughter — just after the point, 0…1.
    var crowdConf: Double? = nil
    /// The number the user sees — "#3". Given 1…n in time order when a
    /// detection lands and never reused after: deleting #2 used to relabel
    /// the old #3 as "#2" (the label was the position), which read as if the
    /// delete had taken the wrong clip. Gaps are fine. nil only in files
    /// written before it existed; `SessionStore.load` fills those in.
    var number: Int? = nil

    var duration: Double { end - start }

    /// Past this, a "rally" is usually several points the detector joined
    /// because the gaps between them were short — a 1:55 block read to users
    /// as a bug. Flagged, offered for splitting, and kept out of the
    /// automatic best picks; never removed or reordered.
    static let mergedLooking: Double = 60
    var looksMerged: Bool { duration > Self.mergedLooking }

    /// How strongly people reacted, on the classifier's 0…1 scale. Rallies
    /// detected before `SoundCheck` carry only the voice-band ratio, which is
    /// mapped so that both measures badge at the same point.
    var reaction: Double? {
        crowdConf ?? cheer.map { $0 * RallySegment.loudCrowd / RallySegment.loudCheer }
    }
    var isLoud: Bool { (reaction ?? 0) >= RallySegment.loudCrowd }
    /// The voice-band ratio that used to badge a rally: on a 26-minute
    /// courtside doubles the ratios ran 1.1–5.1 with a median near 3.
    static let loudCheer = 3.5
    /// Classifier confidence that badges a reaction. The two clear reactions
    /// measured came in at 0.34 and 0.49, over a 0.01–0.09 floor.
    static let loudCrowd = 0.3

    /// Strikes per minute of actual play — the padding the detector adds at
    /// each end is not play, so it comes off before the rate is taken. nil
    /// when there is too little rally to say anything honest.
    var tempo: Double? {
        let played = duration - RallyDetector.padStartS - RallyDetector.padEndS
        guard played >= 2, hits >= 2 else { return nil }
        return Double(hits) / played * 60
    }

    /// Starred by the user, for the one clip out of forty worth finding again.
    var favourite: Bool? = nil
    var isFavourite: Bool { favourite ?? false }

    /// Playback speed of this clip, set in the trim sheet. nil = 1×. Clips
    /// only: a reel keeps its own timing.
    var speed: Double? = nil
}

// MARK: - Look and sound

/// Colour grade burned into a match's clips.
enum ClipFilter: String, Codable, CaseIterable, Identifiable {
    case original, vivid, warm, cool, mono
    var id: String { rawValue }
}

/// What fills the bands above and below a wide frame in a free vertical clip.
enum Backdrop: String, Codable, CaseIterable, Identifiable {
    case blur, black
    var id: String { rawValue }
}

/// A match's look and sound, applied to every clip. The defaults are what
/// clips were before this existed, so nil and `ClipEdit()` mean the same.
struct ClipEdit: Codable, Equatable {
    var filter: ClipFilter = .original
    var backdrop: Backdrop = .blur
    /// Match sound: 1 as recorded, 0 silent.
    var volume: Double = 1

    init() {}

    // Field by field, so a key added later does not fail an older file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filter = (try? c.decodeIfPresent(ClipFilter.self, forKey: .filter)) ?? .original
        backdrop = (try? c.decodeIfPresent(Backdrop.self, forKey: .backdrop)) ?? .blur
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? 1
    }
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
        case .volt:  return (0.831, 1.0, 0.247)
        case .sun:   return (1.000, 0.780, 0.200)
        case .sky:   return (0.350, 0.720, 1.000)
        case .rose:  return (1.000, 0.420, 0.520)
        case .ink:   return (0.050, 0.060, 0.080)
        }
    }

    /// Bright enough that anything drawn on top of it has to be dark.
    var isLight: Bool {
        let c = rgb
        // 0.5, not 0.6: rose sat at 0.55 and got white text at 2.7:1.
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > 0.5
    }
}

enum CaptionFont: String, Codable, CaseIterable, Identifiable {
    case system     // SF Pro Heavy — neutral
    case condensed  // narrow and loud, the broadcast-graphic look
    case rounded    // SF Rounded — friendly, reads well on video
    case mono       // SF Mono — good for times and numbers
    case serif      // New York — editorial
    case anton      // Anton — the poster-weight sans reels are built on
    case bebas      // Bebas Neue — tall condensed caps, broadcast energy
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
    /// `RenderStamp.currentLook` of the last finished render; nil before the
    /// free mild zoom existed. A single-clip re-render matches it, so a trim
    /// in an old session does not drop one zoomed clip among unzoomed ones.
    var renderedLook: Int? = nil
    /// Colour, vertical background and sound for the clips, and what the last
    /// render used. Free for everyone.
    var edit: ClipEdit? = nil
    var renderedEdit: ClipEdit? = nil
    var effectiveEdit: ClipEdit { edit ?? ClipEdit() }
    /// What a render actually uses: the background only exists on a vertical
    /// frame, so on a wide one switching it changes no pixel and must not ask
    /// for a re-render of every clip.
    var renderEdit: ClipEdit {
        var e = effectiveEdit
        if !OutputFrame(effectiveOrientation).isPortrait { e.backdrop = .blur }
        return e
    }
    /// The burned-in caption carries `{rank}` and a delete has since changed
    /// the ranking, so the clips say "Best #3" about a rally that is now #2.
    /// Shown as an ordinary pending change; the next render clears it.
    var ranksStale: Bool? = nil
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
    /// What a first render that has not finished yet is making. Its clips are
    /// written in place, so when one of them fails — the app left the screen
    /// and iOS refused the GPU, most often — the ones already made are kept
    /// and the next Apply makes only the missing ones. nil once a render
    /// completes; a stamp that no longer matches the settings starts over.
    var partialRender: RenderStamp?

    /// The player to follow in one clip: its own override, else the session's.
    func target(forClip index: Int) -> TargetPlayer? {
        clipTargets?[String(index)] ?? targetPlayer
    }

    /// True when the last detection returned no rallies at all. On disk that
    /// is indistinguishable from the user having deleted every clip, and the
    /// two need different empty states — one is advice about detection, the
    /// other is not.
    var detectionFoundNothing: Bool? = nil

    var smartCropEnabled: Bool { smartCrop ?? true }

    /// 1-based place of a clip when the session's rallies are ranked by score;
    /// nil when the rally was detected before scoring existed.
    func rank(ofClip index: Int) -> Int? {
        guard let segs = segments, index < segs.count, segs[index].score != nil else { return nil }
        let order = segs.indices.sorted { (segs[$0].score ?? -1) > (segs[$1].score ?? -1) }
        return (order.firstIndex(of: index) ?? index) + 1
    }

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
            || ranksStale == true
            || (renderedCaption ?? CaptionSettings()) != (caption ?? CaptionSettings())
            || (renderedEdit ?? ClipEdit()) != renderEdit
            // Compared against what the last render was ALLOWED to do. A free
            // render can never satisfy a Pro flag, so comparing the raw setting
            // left every free session permanently claiming unapplied changes
            // and re-encoding on every press.
            || (proRendered && (renderedSmartCrop ?? false) != effectiveSmartCrop)
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

    /// Why clips are missing when the user changed nothing.
    enum RenderGap { case unfinished, cleared }

    /// `needsRerender` reads an unrecorded render (`renderedOrientation == nil`)
    /// as a change, which keeps Apply working — but an app killed mid-render
    /// and "free up clip files" both landed there too, and the screen then told
    /// the user "settings changed" and held the whole form open over a match
    /// they had not touched. Non-nil only when the stamp of what was being made
    /// still matches the settings, so a real edit keeps the old behaviour.
    var renderGap: RenderGap? {
        guard renderedOrientation == nil, segments?.isEmpty == false, !needsRedetect,
              let stamp = partialRender, stillDescribes(stamp) else { return nil }
        return stamp.cleared == true ? .cleared : .unfinished
    }

    /// The settings-side half of `RenderStamp.matches`. The tier is the one
    /// thing a session cannot know — it belongs to the pass — so the Pro-only
    /// settings are compared only when the stamp was made with them, as
    /// `needsRerender` does.
    private func stillDescribes(_ stamp: RenderStamp) -> Bool {
        let segs = segments ?? []
        return stamp.orientation == effectiveOrientation
            && (stamp.caption ?? CaptionSettings()) == (caption ?? CaptionSettings())
            && (stamp.edit ?? ClipEdit()) == renderEdit
            && (!stamp.pro || (stamp.smartCrop == effectiveSmartCrop
                               && (!stamp.smartCrop || stamp.targetPlayer == targetPlayer)))
            && stamp.rallies.count == segs.count
            && zip(stamp.rallies, segs).allSatisfy {
                abs($0.start - $1.start) < 1e-6 && abs($0.end - $1.end) < 1e-6
                    && ($0.speed ?? 1) == ($1.speed ?? 1)
            }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, capturedAt, duration, width, height,
             sport, sensitivity, aspect, segments, renderedOrientation,
             renderedPro, detectedSport, detectedSensitivity,
             assetIdentifier, latitude, longitude, placeName,
             caption, renderedCaption,
             smartCrop, renderedSmartCrop, detectionFoundNothing,
             targetPlayer, renderedTargetPlayer,
             clipTargets, renderedClipTargets, partialRender, renderedLook, ranksStale,
             edit, renderedEdit
    }
}

/// Everything a clip's pixels depend on. Two renders with equal stamps make
/// the same files, so a half-finished one can be continued instead of redone.
struct RenderStamp: Codable, Equatable {
    var orientation: String
    var pro: Bool
    var smartCrop: Bool
    var caption: CaptionSettings?
    var clipTargets: [String: TargetPlayer]
    var targetPlayer: TargetPlayer?
    var rallies: [RallySegment]
    /// Caption language — `{sport}`, "Best #1" and dates are burned in it.
    var lang: String? = nil
    /// Written by "free up clip files", which keeps the record of the last
    /// render here so the screen can say the files were cleared rather than
    /// that settings changed. Not part of `matches`: an Apply afterwards is a
    /// render of the same pixels into an empty folder.
    var cleared: Bool? = nil
    /// The renderer's framing generation. 2 = free portrait clips mildly
    /// zoomed on the play. Old stamps carry nil and never match a new one,
    /// so an unfinished render from before is redone whole on the next Apply
    /// rather than finished with clips of a different look.
    var look: Int? = nil
    static let currentLook = 2
    /// Colour, background and sound. nil on stamps from before; same as default.
    var edit: ClipEdit? = nil

    /// Whether a render with this look zooms the free frame.
    static func zooms(_ look: Int?) -> Bool { (look ?? 1) >= 2 }

    /// Same pixels, not same record: a favourite star, a hit count or a
    /// per-clip target override does not change the clips already made, and
    /// comparing whole segments sent a session back to a full re-render the
    /// moment the user starred a rally.
    func matches(_ other: RenderStamp) -> Bool {
        orientation == other.orientation && pro == other.pro && look == other.look
            && smartCrop == other.smartCrop && caption == other.caption
            && (edit ?? ClipEdit()) == (other.edit ?? ClipEdit())
            && targetPlayer == other.targetPlayer
            && (lang == nil || other.lang == nil || lang == other.lang)
            && rallies.count == other.rallies.count
            && zip(rallies, other.rallies).allSatisfy {
                abs($0.start - $1.start) < 1e-6 && abs($0.end - $1.end) < 1e-6
                    && ($0.speed ?? 1) == ($1.speed ?? 1)
            }
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
    /// Whether the reel opened with its hook title and ended on the slow
    /// winning-shot replay, so a caption-only rebuild makes the same reel.
    /// nil on reels made before either existed: rebuilt without them.
    var hook: Bool? = nil
    var replay: Bool? = nil
    /// Each session's colour, background and sound as built, by session id,
    /// so a caption-only rebuild does not pick up a later change. nil on reels
    /// from before: rebuilt with the sessions' current settings.
    var edits: [String: ClipEdit]? = nil

    // Filled in when listed; never written to the sidecar.
    var url: URL = URL(fileURLWithPath: "/")
    var thumbURL: URL = URL(fileURLWithPath: "/")
    var bytes: Int64 = 0

    /// True when this reel remembers where its rallies came from, which is what
    /// re-rendering it needs.
    var canRebuild: Bool { !(sources ?? []).isEmpty }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, target, frame, pace, preset, rallies, duration, place
        case sources, caption, hook, replay, edits
    }
}

/// One rally inside a reel, addressed the way it can still be found later: by
/// its session and where the rally sits in that recording.
///
/// The index alone went stale: deleting, adding or splitting a rally renumbers
/// the session, and a caption rebuild then quietly used a different rally.
/// `start`/`end` are the source times the reel was cut from and are what a
/// rebuild matches on; the index is only the fallback for sidecars written
/// before they were recorded.
struct ReelSource: Codable, Equatable {
    let sessionID: UUID
    let clipIndex: Int
    var start: Double? = nil
    var end: Double? = nil
}

extension Array where Element == RallySegment {
    /// A fresh detection: 1…n in time order.
    func numberedInOrder() -> [RallySegment] {
        enumerated().map { i, seg in
            var s = seg
            s.number = i + 1
            return s
        }
    }

    /// Fills in only the missing numbers, after the highest one present — an
    /// old session gets 1…n by its current order, once.
    func fillingNumbers() -> [RallySegment] {
        var next = (compactMap(\.number).max() ?? 0) + 1
        return map { seg in
            guard seg.number == nil else { return seg }
            var s = seg
            s.number = next
            next += 1
            return s
        }
    }

    /// The number a newly made rally (added by hand, or the second half of a
    /// split) takes: never one that was used before in this list.
    var nextNumber: Int { Swift.max(compactMap(\.number).max() ?? 0, count) + 1 }
}

extension Array where Element == RallySegment {
    /// The list with `seg` put back in time order, and where it went. nil
    /// when a rally with the same number is already there (undone twice).
    func restoring(_ seg: RallySegment) -> (segments: [RallySegment], at: Int)? {
        if let n = seg.number, contains(where: { $0.number == n }) { return nil }
        var out = self
        let at = out.firstIndex { $0.start > seg.start } ?? out.count
        out.insert(seg, at: at)
        return (out, at)
    }
}
