import AVKit
import Pow
import SwiftUI

// MARK: - Clip card

struct ClipCard: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    let clip: ClipInfo
    var showSession: String? = nil
    /// Forces every card in the grid to one shape. A session's own grid shares
    /// one orientation so it can size to the clip, but All Clips mixes them and
    /// a row is as tall as its tallest card — a wide clip beside a vertical one
    /// sat under a void twice its own height.
    var uniformAspect: CGFloat? = nil
    /// nil = not in selection mode
    var selected: Bool? = nil
    let onTap: () -> Void

    var body: some View {
        // Taps go through while the clip is still being made: the player
        // previews the rally from the original. Swallowing them left the user
        // looking at a grid of posters for the whole render with nothing to
        // watch. Callers that cannot preview keep their own `isReady` check.
        Button(action: onTap) {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    // The card takes its shape from a view that accepts any
                    // proposal, and the poster is laid inside it. Sizing on the
                    // poster instead let one whose aspect didn't match the clip
                    // — a stale one, or a session re-rendered to a new frame —
                    // grow the cell and overlap its neighbours in the grid.
                    Color.clear
                        .aspectRatio(uniformAspect
                                        ?? OutputFrame(clip.orientation).aspectRatio,
                                     contentMode: .fit)
                        // The poster fills the cell and is clipped, so a
                        // vertical rally in a wide cell shows its middle rather
                        // than sitting in black bars. The duration and time
                        // labels say what it is.
                        .overlay { thumb }
                        .clipped()
                    Text(fmtLen(clip.duration, lang))
                        .font(.caption2.bold())
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                    if !clip.isReady {
                        Color.black.opacity(0.45)
                        // Spinning only while something is making it. After a
                        // failed render the unmade clips spun forever.
                        if store.isBusy(clip.sessionID) {
                            // Centred: the ZStack's bottom-trailing alignment
                            // put it on top of the duration badge.
                            ProgressView().tint(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.warning)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                selected ? Color.black : Color.white,
                                selected ? Color.accentColor : Color.white.opacity(0.6))
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomLeading)
                    }
                    VStack {
                        HStack {
                            // Badges sit on a fixed-size thumbnail; scaling
                            // them made the rank and duration chips overlap.
                            Text("#" + String(clip.index + 1))
                                .font(.caption2.bold())
                                .dynamicTypeSize(...DynamicTypeSize.large)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.black.opacity(0.65),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .padding(6)
                            Spacer()
                            if clip.segment.isFavourite {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 4)
                                    .background(.black.opacity(0.65),
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .padding(6)
                            }
                            // Neutral, not a warning colour: it is a
                            // likely joined block, not an error.
                            if clip.segment.looksMerged {
                                Text(L.s("long_block", lang))
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(.black.opacity(0.65),
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .padding(6)
                            }
                            // One or the other: both on a narrow card
                            // overflowed the row.
                            if clip.segment.isLoud && !clip.segment.looksMerged {
                                Text("🔥 " + L.s("cheer_badge", lang))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.black.opacity(0.65),
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .padding(6)
                            }
                        }
                        // Every badge in this row sits on a thumbnail the grid
                        // sizes, so none of them may grow with the body text.
                        // The warning glyph was added without a cap and ate a
                        // third of the poster at the largest setting.
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        Spacer()
                    }
                }
                // narrow cards (vertical clips) stack instead of truncating
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { timeLabel; Spacer(minLength: 4); subLabel }
                    VStack(alignment: .leading, spacing: 2) { timeLabel; subLabel }
                }
                .padding(8)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, lineWidth: selected == true ? 3 : 0))
            .opacity(selected == false ? 0.55 : 1)
        }
        .buttonStyle(.plain)
    }

    // The grid fixes the cell width, so these two cannot grow with the type
    // size — unbounded they clipped to "00:02–0…", which is not a timestamp.
    private var timeLabel: some View {
        Text("\(fmtTs(clip.segment.start))–\(fmtTs(clip.segment.end))")
            .font(.caption2.monospacedDigit().bold())
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    private var subLabel: some View {
        Text(showSession ?? (String(clip.segment.hits) + " " + L.s("shots_n", lang)))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    @ViewBuilder private var thumb: some View {
        PosterImage(url: clip.thumbURL)
    }
}

// MARK: - Clip player

struct ClipPlayerSheet: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var pass: ProPass
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    let clip: ClipInfo
    @State private var player: AVPlayer?
    @State private var confirmDelete = false
    @State private var destination: Destination?
    @State private var message: String?
    /// Set the moment a delete is confirmed. The store then shifts the next
    /// rally into this index, and without the flag the sheet reloaded the
    /// player onto that rally's file on its way out.
    @State private var deleting = false
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Why the preview could not load, shown in the video's place.
    @State private var previewProblem: String?
    /// The "may be several rallies" explanation, with the way to split.
    @State private var explainLong = false

    /// The clip has no file yet, so the sheet plays the rally from the
    /// original instead. Read from the snapshot on purpose: swapping the
    /// player under the user the moment the encoder reaches this rally would
    /// restart what they are watching. Reopening picks the file up.
    private var preview: Bool { !clip.isReady }

    /// One sheet drives every modal, as on `SessionDetailView`. Stacking
    /// several `.sheet` modifiers on one view collides — a second one added
    /// here opened the first one's content instead of its own.
    private enum Destination: Identifiable {
        case trim
        case retarget
        case reel(ReelRequest)

        var id: String {
            switch self {
            case .trim: return "trim"
            case .retarget: return "retarget"
            case .reel(let r): return "reel-" + r.id.uuidString
            }
        }
    }

    /// Read back from the store rather than `clip`, which is the snapshot the
    /// sheet opened with — otherwise starring would not show until reopening.
    private var isFavourite: Bool {
        session?.segments?[safe: clip.index]?.isFavourite ?? false
    }

    private var session: Session? {
        store.sessions.first { $0.id == clip.sessionID }
    }
    /// The segment as the store holds it *now*. `clip` is the snapshot the
    /// sheet opened with, so after a trim applied from inside this sheet the
    /// title still read the original in/out points while the file on disk was
    /// already the shorter one.
    private var live: RallySegment {
        if deleting { return clip.segment }
        return session?.segments?[safe: clip.index] ?? clip.segment
    }
    /// `clip` with the store's current in/out points. Trim, retarget and the
    /// reel all take this, so a reel made after a trim cuts the trimmed rally
    /// rather than the range the sheet opened with.
    private var current: ClipInfo {
        ClipInfo(id: clip.id, index: clip.index, url: clip.url, thumbURL: clip.thumbURL,
                 segment: live, orientation: clip.orientation,
                 sessionID: clip.sessionID, isReady: clip.isReady)
    }

    /// A trim rewrites the clip at the same URL, so the existing `AVPlayer`
    /// keeps serving the old asset and its old duration. Replacing the item
    /// is the only way to pick the new file up without closing the sheet.
    private func reloadPlayer() {
        guard !deleting else { return }
        // A preview reloads through its `.task`, which is keyed on the range.
        guard !preview else { return }
        player?.pause()
        player = AVPlayer(url: clip.url)
    }

    /// A finished clip's player is made synchronously on appear: with the
    /// video as the sheet's main content, a nil player at first layout left
    /// the whole sheet blank. The preview has to load, so it comes from a
    /// `.task` instead.
    private func startPlayer() {
        guard player == nil, !deleting, !preview else { return }
        player = AVPlayer(url: clip.url)
    }

    /// Run from a `.task`, so closing the sheet cancels it — an iCloud original
    /// otherwise went on downloading for a sheet nobody was looking at, and
    /// then built a player for it.
    private func loadPreview() async {
        guard let session else { return }
        previewProblem = nil
        guard let asset = await store.loadAsset(session) else {
            if !Task.isCancelled { previewProblem = store.missingMessage(clip.sessionID) }
            return
        }
        guard !Task.isCancelled else { return }
        let item = await RallyPreview.item(from: asset, start: live.start,
                                           end: live.end, audio: true)
        guard !Task.isCancelled, !deleting else { return }
        guard let item else {
            // Never an endless spinner: say it, and the poster stays.
            previewProblem = L.s("preview_failed", lang)
            return
        }
        player?.pause()
        // A new instance, not `replaceCurrentItem`: ZoomableVideo re-attaches
        // its time observer when the player's identity changes, and only then.
        player = AVPlayer(playerItem: item)
    }

    /// The poster where the video will be, while the preview loads or when the
    /// original is out of reach.
    private var previewPlaceholder: some View {
        Color.clear
            .aspectRatio(OutputFrame(clip.orientation).aspectRatio, contentMode: .fit)
            .overlay { PosterImage(url: clip.thumbURL).opacity(0.6) }
            .clipped()
            .overlay {
                if let previewProblem {
                    Text(previewProblem)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 300)
    }
    /// Re-pointing only means anything where the crop can move: a portrait
    /// clip that was rendered with smart crop on, on a Pro entitlement.
    private var canRetarget: Bool {
        pass.isPro && OutputFrame(clip.orientation).isPortrait
            && (session?.renderedSmartCrop ?? false)
    }
    private var hasOwnTarget: Bool {
        session?.clipTargets?[String(clip.index)] != nil
    }

    var body: some View {
        // On an iPhone in landscape the vertical size class is compact. That is
        // the cue to give the whole screen to the video: the tracking and reel
        // controls are portrait work, and shrinking the rally to make room for
        // them is exactly what made rotating pointless.
        Group {
            if vSize == .compact {
                landscapePlayer
            } else {
                portraitPlayer
            }
        }
        // Applied out here, not inside the two variants: rotating swaps them,
        // and the departing variant's `onDisappear` would revoke the permission
        // the instant it was used, snapping the phone straight back to portrait.
        // Only a wide clip gains anything from turning the phone; a 9:16 rally
        // would just be letterboxed on its side. And not while a sheet is open
        // over the player: the landscape layout hid it completely, and its X
        // then dismissed player and sheet together, silently dropping the trim
        // the user was in the middle of.
        .allowsLandscape(!OutputFrame(clip.orientation).isPortrait && destination == nil)
        // On the Group, not the two layouts: rotating swaps them, and a task
        // on either would be cancelled and restarted by the turn.
        .task(id: preview ? "\(live.start)-\(live.end)" : "") {
            guard preview else { return }
            await loadPreview()
        }
    }

    private var landscapePlayer: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player { ZoomableVideo(player: player) }
            else if preview { previewPlaceholder.frame(maxHeight: .infinity) }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(L.s("done", lang))
            .padding(16)
        }
        .statusBarHidden()
        .onAppear { startPlayer() }
        .preferredColorScheme(.dark)
    }

    private var portraitPlayer: some View {
        NavigationStack {
            AdaptiveScroll(scrolls: typeSize.isAccessibilitySize) {
            VStack(spacing: 0) {
                if let player {
                    // Given its own aspect only when the stack scrolls: in the
                    // fixed layout the video takes the space the controls leave,
                    // which at accessibility sizes was none at all.
                    if typeSize.isAccessibilitySize {
                        // Capped, not just given its aspect: a 9:16 clip at its
                        // own ratio fills the phone, and the player's own pan
                        // gesture then swallows the drag that would scroll to
                        // the controls underneath it.
                        ZoomableVideo(player: player)
                            .aspectRatio(OutputFrame(clip.orientation).aspectRatio,
                                         contentMode: .fit)
                            .frame(maxHeight: 300)
                    } else {
                        ZoomableVideo(player: player)
                    }
                } else if preview {
                    previewPlaceholder
                }
                if preview {
                    // "Still being made" only while something is making it.
                    // After a failed render the clip waits for Apply, and
                    // promising it was on its way was simply untrue.
                    let making = store.isBusy(clip.sessionID)
                    Label(L.s(making ? "clip_preview_note" : "clip_unmade_note", lang),
                          systemImage: making ? "hourglass" : "film")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
                // A player picked once for the session is the right subject for
                // most rallies but not all — they change ends, or the rally
                // that matters is the opponent's. Re-pointing lives on the clip
                // because that is where you notice the wrong person is centred.
                // A block this long is usually several points joined. Said
                // where the user is watching it, with the fix next to it: the
                // split lives in the trim sheet. Not on a preview — trimming
                // works on the clip file.
                if live.looksMerged && !preview {
                    Button { explainLong = true } label: {
                        (Text(Image(systemName: "rectangle.split.2x1")) + Text("  ")
                         + Text(L.s("long_block_note", lang)).foregroundColor(.secondary)
                         + Text("  ·  ")
                         + Text(L.s("long_block_split", lang)).bold()
                            .foregroundColor(Theme.accent))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                // Both work on the clip file, which a preview does not have yet.
                if canRetarget && !preview {
                    HStack(spacing: 8) {
                        Button { destination = .retarget } label: {
                            Label(L.s("target_clip", lang),
                                  systemImage: hasOwnTarget
                                      ? "person.crop.circle.badge.checkmark"
                                      : "person.crop.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .rcSecondary()
                        if hasOwnTarget {
                            Button(L.s("target_clip_reset", lang)) {
                                Task { await store.setClipTarget(clip, nil) }
                            }
                            .rcSecondary()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                // one rally is the most common thing to post, so the route to a
                // reel sits on the clip itself rather than only behind selection
                if !preview {
                    Button {
                        guard let session else { return }
                        destination = .reel(ReelRequest(pairs: [(session, current)]))
                    } label: {
                        Label(L.s("reel_make", lang),
                              systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                            .frame(maxWidth: .infinity)
                    }
                    .rcPrimary()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }
            }
            .background(Color.black.ignoresSafeArea())
            .onAppear { startPlayer() }
            // A trim rewrites the file at the same URL, so neither `onAppear`
            // nor the URL changing brings the new length in. Rebuild the
            // player when the segment's bounds move; the header reads `live`
            // for the same reason.
            .onChange(of: live.start) { _, _ in reloadPlayer() }
            .onChange(of: live.end) { _, _ in reloadPlayer() }
            // Only a wide clip gains anything from turning the phone; a 9:16
            // rally would just be letterboxed on its side.
                .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Two lines, because "#1 · 00:02–00:20" on one does not fit
                // between a delete button and three trailing buttons — it
                // clipped to "00:0…" at every text size, not only large ones.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("#" + String(clip.index + 1)).font(.headline)
                        Text(fmtTs(live.start) + "–" + fmtTs(live.end))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                }
                // The landscape variant has its own X over the video; without
                // this the portrait sheet's only exit was a drag with no
                // affordance, and testers got stuck in the player.
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L.s("done", lang))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(L.s("delete_clip", lang))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.toggleFavourite(clip) } label: {
                        Image(systemName: isFavourite ? "star.fill" : "star")
                            .foregroundStyle(isFavourite ? Theme.accent : .secondary)
                            // A small burst on starring, so the tap reads as
                            // kept. Only on the way in, and never with Reduce
                            // Motion — Pow does not check that setting itself.
                            .changeEffect(.spray {
                                Image(systemName: "star.fill").foregroundStyle(Theme.accent)
                            }, value: isFavourite, isEnabled: isFavourite && !reduceMotion)
                    }
                    .accessibilityLabel(L.s("favourite", lang))
                }
                // Trim re-renders the clip file and Share hands it out; a
                // preview has no file for either. Starring is only a flag.
                if !preview {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { destination = .trim } label: {
                            Image(systemName: "timeline.selection")
                        }
                        .accessibilityLabel(L.s("trim_title", lang))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: clip.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(L.s("share", lang))
                    }
                }
            }
            .confirmationDialog(L.s("delete_clip", lang), isPresented: $confirmDelete) {
                Button(L.s("delete", lang), role: .destructive) {
                    // A busy session keeps the clip; closing regardless left
                    // a "deleted" clip in the list behind the sheet.
                    deleting = true
                    player?.pause()
                    if store.deleteClip(current) {
                        dismiss()
                    } else {
                        deleting = false
                        message = L.s("busy_wait", lang)
                    }
                }
            }
            .alert(message ?? "", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            }
            .alert(L.s("long_block_explain", lang), isPresented: $explainLong) {
                Button(L.s("split_rally", lang)) { destination = .trim }
                Button(L.s("cancel", lang), role: .cancel) {}
            }
            .sheet(item: $destination) { dest in
                switch dest {
                case .trim:
                    TrimSheet(clip: current)
                case .retarget:
                    if let session { TargetPlayerSheet(session: session, clip: current) }
                case .reel(let request):
                    ReelSheet(request: request)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Rally preview

/// A rally cut straight from the original, for clips the render has not
/// reached yet (the player sheet) and for the session screen's hero.
enum RallyPreview {
    /// A composition of just the rally rather than the whole original with a
    /// `forwardPlaybackEndTime`: the player's scrubber and clock then run over
    /// the rally's own 0…length instead of a spot deep inside an hour-long
    /// match, and the end of the item is the end of the rally, so looping is a
    /// seek to zero. The range is clamped to the asset's real length — a range
    /// past the end is what made AVAssetExportSession hang forever.
    /// `audio: false` leaves the sound track out entirely, for a muted
    /// autoplay that has no business touching the audio session.
    static func item(from asset: AVAsset, start: Double, end: Double,
                     audio: Bool) async -> AVPlayerItem? {
        guard let total = try? await asset.load(.duration).seconds,
              total.isFinite, total > 0 else { return nil }
        let from = max(0, min(start, total))
        let to = min(end, total)
        guard to - from > 0.1,
              let video = try? await asset.loadTracks(withMediaType: .video).first
        else { return nil }
        let range = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                end: CMTime(seconds: to, preferredTimescale: 600))
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        do {
            try vTrack.insertTimeRange(range, of: video, at: .zero)
            // Phone footage is stored sideways with a rotation; without it a
            // portrait recording previews lying on its side.
            vTrack.preferredTransform = try await video.load(.preferredTransform)
            if audio, let sound = try? await asset.loadTracks(withMediaType: .audio).first,
               let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid) {
                try aTrack.insertTimeRange(range, of: sound, at: .zero)
            }
        } catch {
            return nil
        }
        return AVPlayerItem(asset: comp)
    }
}

struct HighlightPlayerSheet: View {
    let url: URL
    let name: String
    /// The frame the session was rendered to. A vertical highlight gains
    /// nothing from turning the phone — it would just lie on its side inside
    /// black bars — so the same rule as the clip player applies here.
    var orientation: String? = nil
    /// Built up front rather than in `onAppear`. The video is this screen's
    /// only content, so a nil player left the navigation stack with nothing to
    /// lay out: the sheet came up empty, title bar and all, and stayed empty
    /// even once the player arrived.
    @State private var player: AVPlayer

    init(url: URL, name: String, orientation: String? = nil) {
        self.url = url
        self.name = name
        self.orientation = orientation
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            ZoomableVideo(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .allowsLandscape(!OutputFrame(orientation).isPortrait)
                .navigationTitle("✨ \(name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}
