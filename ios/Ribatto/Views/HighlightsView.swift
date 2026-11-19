import AVFoundation
import SwiftUI

/// Every finished rally from every match, one full screen at a time, swiped
/// like a short-video feed. Opened from the Challenges tab — everything, or
/// just the rallies behind one challenge.
///
/// Between matches the one thing players actually do with their footage is
/// watch their good points again. The session screen is for managing one
/// match; this is for watching all of them. It fills from the first import —
/// no setup, nothing to type — and rallies not yet seen come first, so each
/// open starts somewhere new.
///
/// Only finished clip files play: decoding a 4K or iCloud original here
/// would fight the encoder for memory, the same reason the hero does not.
struct HighlightsView: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    /// Keys of rallies already shown, newest last.
    @AppStorage("rc_hl_seen") private var seenText = ""
    @AppStorage("rc_hl_muted") private var muted = true
    @Environment(\.scenePhase) private var scenePhase
    /// Only these rallies (feed keys); nil plays everything.
    var only: Set<String>? = nil
    let onClose: () -> Void
    /// Closes the feed and shows that match. The match screen is not pushed
    /// in here: it carries the ad banner, and a banner claimed inside a cover
    /// never goes back to the tab underneath when the cover closes.
    let openMatch: (UUID) -> Void

    @State private var items: [Item] = []
    /// The order fixed when the tab was opened. Marking a rally seen must not
    /// move it while the user is still scrolling past it.
    @State private var order: [String: Int] = [:]
    @State private var current: String?
    @State private var player = AVPlayer()
    @State private var loop: NSObjectProtocol?

    struct Item: Identifiable {
        let clip: ClipInfo
        let session: Session
        /// Stable across deletes: the rally's own number, not its position.
        var id: String { clip.sessionID.uuidString + "/" + String(clip.number) }
    }

    private var feed: [Item] {
        items.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    /// Most shots in any rally on file: the clip that holds it gets a badge.
    private var recordID: String? {
        items.filter { $0.clip.segment.hits >= 5 }
            .max { $0.clip.segment.hits < $1.clip.segment.hits }?.id
    }

    private var watching: Bool { scenePhase == .active }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(title: L.s("hl_tab", lang)) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.title3.weight(.semibold))
                }
                .tint(Theme.primaryText)
                .accessibilityLabel(L.s("done", lang))
            }
            if items.isEmpty {
                EmptyStateBox {
                    VStack(spacing: 10) {
                        Image(systemName: "play.square.stack")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Theme.secondaryText)
                        Text(L.s("hl_empty", lang))
                            .font(.subheadline).foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                }
            } else {
                pages
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { reopen() }
        .onChange(of: store.sessions) { _, _ in rebuild() }
        .onChange(of: current) { _, id in
            if let id { markSeen(id) }
            load()
        }
        .onChange(of: watching) { _, _ in load() }
        .onChange(of: muted) { _, m in player.isMuted = m }
        .onDisappear { stop() }
    }

    private var pages: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(feed) { item in
                        page(item)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            // Pages are exactly the visible height; the automatic inset for
            // the floating tab bar would leave each one a little off.
            .contentMargins(0, for: .scrollContent)
        }
        // To the bottom edge: stopping at the home indicator's safe area left
        // the next page's top showing under each one.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: Page

    private func page(_ item: Item) -> some View {
        let frame = OutputFrame(item.clip.orientation)
        let live = item.id == current
        return ZStack {
            Theme.letterbox
            Color.clear
                .aspectRatio(frame.aspectRatio, contentMode: .fit)
                .overlay { PosterImage(url: item.clip.thumbURL) }
                .overlay {
                    if live {
                        PlayerLayerView(player: player).allowsHitTesting(false)
                    }
                }
                .clipped()
        }
        .overlay {
            // A 55% scrim under the type, never less (palette rule).
            LinearGradient(stops: [
                .init(color: .clear, location: 0.55),
                .init(color: .black.opacity(0.55), location: 0.8),
                .init(color: .black.opacity(0.7), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) { caption(item) }
        .overlay(alignment: .bottomTrailing) { actions(item) }
        .overlay(alignment: .topTrailing) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.45), in: Circle())
                .padding(12)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { muted.toggle() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: L.s(muted ? "hl_unmute" : "hl_mute", lang)) { muted.toggle() }
    }

    /// White only: on video, the secondary grey falls to 2.2:1.
    private func caption(_ item: Item) -> some View {
        let seg = item.clip.segment
        let s = item.session
        var line = "#\(item.clip.number) · \(seg.hits) \(L.s("shots_n", lang)) · "
            + fmtLen(item.clip.duration, lang)
        if seg.isLoud { line += " · 🔥" }
        return VStack(alignment: .leading, spacing: 4) {
            if item.id == recordID {
                Label(L.s("hl_record", lang), systemImage: "trophy.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
            }
            Text(s.placeName ?? s.name)
                .font(.headline).lineLimit(1)
            Text(L.dateOnly(s.capturedAt ?? s.createdAt, lang))
                .font(.subheadline)
            Text(line)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        // It sits on the picture; unbounded it would cover the rally.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.leading, 16).padding(.trailing, 90).padding(.bottom, 34)
        .accessibilityElement(children: .combine)
    }

    private func actions(_ item: Item) -> some View {
        let fav = item.clip.segment.isFavourite
        return VStack(spacing: 18) {
            Button { store.toggleFavourite(item.clip) } label: {
                action(fav ? "star.fill" : "star", L.s("favourite", lang))
                    .foregroundStyle(fav ? Theme.accent : .white)
            }
            .accessibilityAddTraits(fav ? .isSelected : [])
            ShareLink(item: item.clip.url, message: Text(L.shareMessage(lang))) {
                action("square.and.arrow.up", L.s("share", lang))
            }
            Button { openMatch(item.session.id) } label: {
                action("rectangle.stack", L.s("hl_match", lang))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .padding(.trailing, 12).padding(.bottom, 34)
    }

    private func action(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 48, height: 40)
                .shadow(color: .black.opacity(0.5), radius: 4)
            Text(title).font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .frame(minWidth: 60)
        .contentShape(Rectangle())
    }

    // MARK: Feed

    private func rebuild() {
        items = store.sessions.flatMap { s in
            store.clips(of: s)
                // Long blocks are several points glued together; they are
                // kept out of every automatic best pick, and out of here.
                .filter { $0.isReady && !$0.segment.looksMerged }
                .map { Item(clip: $0, session: s) }
        }
        if let only { items = items.filter { only.contains($0.id) } }
        if let c = current, !items.contains(where: { $0.id == c }) { current = nil }
        if current == nil { current = feed.first?.id }
    }

    /// Opening the tab: not-yet-seen rallies first — this week's matches, then
    /// starred, crowd-loud and high-scoring ones. Once everything has been
    /// seen the order is shuffled, so the tab is never the same twice.
    private func reopen() {
        rebuild()
        let seen = Set(seenText.split(separator: "\n").map(String.init))
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let ranked = items.map { item -> (String, Double) in
            let seg = item.clip.segment
            let fresh = (item.session.capturedAt ?? item.session.createdAt) > weekAgo
            var p = (seg.score ?? 0) + (seg.isLoud ? 1 : 0) + (seg.isFavourite ? 2 : 0)
            if seen.contains(item.id) { p += Double.random(in: 0..<4) } else { p += 10 + (fresh ? 3 : 0) }
            return (item.id, p)
        }
        .sorted { $0.1 > $1.1 }
        order = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1.0, $0) })
        current = ranked.first?.0
        load()
    }

    private func markSeen(_ id: String) {
        var seen = seenText.split(separator: "\n").map(String.init)
        guard !seen.contains(id) else { return }
        seen.append(id)
        // shortcut: capped at 2000 keys; a heavier user would want a set on disk.
        seenText = seen.suffix(2000).joined(separator: "\n")
    }

    // MARK: Player

    /// One player for the whole feed, moved to whichever page is in view.
    private func load() {
        stop()
        guard watching, let id = current,
              let item = items.first(where: { $0.id == id }) else { return }
        let next = AVPlayerItem(url: item.clip.url)
        player.replaceCurrentItem(with: next)
        player.isMuted = muted
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        player.actionAtItemEnd = .none
        loop = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: next,
            queue: .main) { [weak player] _ in player?.seek(to: .zero) }
        player.play()
    }

    private func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let loop { NotificationCenter.default.removeObserver(loop) }
        loop = nil
    }
}
