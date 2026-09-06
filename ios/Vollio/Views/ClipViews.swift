import AVKit
import SwiftUI

// MARK: - Clip card

struct ClipCard: View {
    @AppStorage("rc_lang") private var lang = "en"
    let clip: ClipInfo
    var showSession: String? = nil
    /// nil = not in selection mode
    var selected: Bool? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: { if clip.isReady { onTap() } }) {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    // The card takes its shape from a view that accepts any
                    // proposal, and the poster is laid inside it. Sizing on the
                    // poster instead let one whose aspect didn't match the clip
                    // — a stale one, or a session re-rendered to a new frame —
                    // grow the cell and overlap its neighbours in the grid.
                    Color.clear
                        .aspectRatio(OutputFrame(clip.orientation).aspectRatio,
                                     contentMode: .fit)
                        .overlay { thumb }
                        .clipped()
                    Text(String(Int(clip.duration)) + L.s("sec", lang))
                        .font(.caption2.bold())
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                    if !clip.isReady {
                        Color.black.opacity(0.45)
                        ProgressView().tint(.white)
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
                            if clip.segment.isLoud {
                                Text("🔥 " + L.s("cheer_badge", lang))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.black.opacity(0.65),
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .padding(6)
                            }
                        }
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
            .font(.caption2).foregroundStyle(.secondary)
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
    @EnvironmentObject var purchases: PurchaseManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    let clip: ClipInfo
    @State private var player: AVPlayer?
    @State private var confirmDelete = false
    @State private var destination: Destination?
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.dynamicTypeSize) private var typeSize

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

    /// The winner of this rally as currently stored — read back from the store
    /// rather than held locally, so tagging updates every screen at once.
    private var winner: PointWinner? {
        session?.segments?[safe: clip.index]?.winner
    }
    private var isFavourite: Bool {
        session?.segments?[safe: clip.index]?.isFavourite ?? false
    }

    private var session: Session? {
        store.sessions.first { $0.id == clip.sessionID }
    }
    /// Re-pointing only means anything where the crop can move: a portrait
    /// clip that was rendered with smart crop on, on a Pro entitlement.
    private var canRetarget: Bool {
        purchases.isPro && OutputFrame(clip.orientation).isPortrait
            && (session?.renderedSmartCrop ?? false)
    }
    private var hasOwnTarget: Bool {
        session?.clipTargets?[String(clip.index)] != nil
    }

    var body: some View {
        // On an iPhone in landscape the vertical size class is compact. That is
        // the cue to give the whole screen to the video: the tagging and reel
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
    }

    private var landscapePlayer: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player { ZoomableVideo(player: player) }
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
        .onAppear { if player == nil { player = AVPlayer(url: clip.url) } }
        .preferredColorScheme(.dark)
    }

    private var portraitPlayer: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let player {
                    ZoomableVideo(player: player)
                }
                // A player picked once for the session is the right subject for
                // most rallies but not all — they change ends, or the rally
                // that matters is the opponent's. Re-pointing lives on the clip
                // because that is where you notice the wrong person is centred.
                if canRetarget {
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

                // Who won this point. The score is only ever what the user
                // says: tagging here is the whole input to the scoreboard.
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.s("who_won", lang))
                        .font(.caption).foregroundStyle(.secondary)
                    AdaptiveButtonRow {
                        ForEach(PointWinner.allCases) { side in
                            Button {
                                store.setWinner(clip, winner == side ? nil : side)
                            } label: {
                                Text(L.s(side.key, lang))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .chip(active: winner == side)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                // one rally is the most common thing to post, so the route to a
                // reel sits on the clip itself rather than only behind selection
                Button {
                    guard let session else { return }
                    destination = .reel(ReelRequest(pairs: [(session, clip)]))
                } label: {
                    Label(L.s("reel_make", lang),
                          systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                        .frame(maxWidth: .infinity)
                }
                .rcPrimary()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .background(Color.black.ignoresSafeArea())
            .onAppear { if player == nil { player = AVPlayer(url: clip.url) } }
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
                        Text(fmtTs(clip.segment.start) + "–" + fmtTs(clip.segment.end))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.large)
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
                    }
                    .accessibilityLabel(L.s("favourite", lang))
                }
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
            .confirmationDialog(L.s("delete_clip", lang), isPresented: $confirmDelete) {
                Button(L.s("delete", lang), role: .destructive) {
                    store.deleteClip(clip)
                    dismiss()
                }
            }
            .sheet(item: $destination) { dest in
                switch dest {
                case .trim:
                    TrimSheet(clip: clip)
                case .retarget:
                    if let session { TargetPlayerSheet(session: session, clip: clip) }
                case .reel(let request):
                    ReelSheet(request: request)
                }
            }
        }
        .preferredColorScheme(.dark)
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

// MARK: - All clips tab

struct AllClipsView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var purchases: PurchaseManager
    @AppStorage("rc_lang") private var lang = "en"
    @State private var sort: ClipSort = .time
    @State private var playing: ClipInfo?
    @State private var search = ""
    @State private var sportFilter: Sport?
    @State private var minSeconds = 0
    @State private var placeFilter: String?
    @State private var whenFilter: WhenFilter?
    @State private var shapeFilter: String?      // OutputFrame raw value
    @State private var minHits = 0
    @State private var filtersOpen = false
    @State private var reel: ReelRequest?
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var confirmDelete = false
    @State private var saveMessage: String?
    @State private var showPaywall = false
    @State private var favesOnly = false

    /// Relative windows rather than a date picker — "that match last month" is
    /// how people actually look for a clip, and it needs no calendar UI.
    enum WhenFilter: String, CaseIterable, Identifiable {
        case week, month, q, year
        var id: String { rawValue }

        var key: String {
            switch self {
            case .week: return "when_week"
            case .month: return "when_month"
            case .q: return "when_90"
            case .year: return "when_year"
            }
        }

        func contains(_ date: Date, _ cal: Calendar = .current) -> Bool {
            let now = Date()
            switch self {
            case .week:  return cal.isDate(date, equalTo: now, toGranularity: .weekOfYear)
            case .month: return cal.isDate(date, equalTo: now, toGranularity: .month)
            case .q:
                guard let from = cal.date(byAdding: .day, value: -90, to: now) else { return true }
                return date >= from
            case .year:  return cal.isDate(date, equalTo: now, toGranularity: .year)
            }
        }
    }

    /// Sport chip, a minimum length, and free text over the session name.
    private func matching(_ items: [(session: Session, clip: ClipInfo)])
        -> [(session: Session, clip: ClipInfo)] {
        items.filter { pair in
            if let sportFilter, pair.session.sport != sportFilter { return false }
            if let placeFilter, pair.session.placeName != placeFilter { return false }
            if let whenFilter, !whenFilter.contains(pair.session.playedAt) { return false }
            if let shapeFilter, pair.clip.orientation != shapeFilter { return false }
            if favesOnly && !pair.clip.segment.isFavourite { return false }
            if pair.clip.segment.hits < minHits { return false }
            if Int(pair.clip.duration) < minSeconds { return false }
            guard !search.isEmpty else { return true }
            let haystack = [L.s(pair.session.sport.rawValue, lang),
                            L.dateTime(pair.session.playedAt, lang),
                            pair.session.placeName ?? "",
                            pair.session.name].joined(separator: " ").lowercased()
            return haystack.contains(search.lowercased())
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            TabHeader(title: L.s("all_clips", lang)) {
                // Cheap check: `allClips()` here meant a second full scan of
                // every session's clip directory on every body pass.
                if store.hasAnyClips {
                    Button(selecting ? L.s("done", lang) : L.s("select", lang)) {
                        selecting.toggle()
                        selection.removeAll()
                    }
                    .font(.subheadline.bold())
                }
            }
            Group {
                let all = store.allClips()
                let items = sorted(matching(all))
                // Empty state only when there is nothing at all: a filter that
                // matches nothing must keep the filter bar so it can be cleared.
                if all.isEmpty {
                    VStack(spacing: 10) {
                        Text("🎬").font(.system(size: 44))
                        Text(L.s("all_clips_empty", lang))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    ScrollView {
                        SearchField(prompt: L.s("search_clips", lang), text: $search)
                            .padding(.horizontal)
                            .padding(.bottom, 10)
                        HStack {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(L.s("clips_title", lang)).font(.headline)
                                Text(String(items.count))
                                    .font(.subheadline.bold()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            SortMenu(sort: $sort)
                        }
                        .padding(.horizontal)
                        // Collapsed, the panel is a single row, so it earns its
                        // place as soon as there are enough clips to sift —
                        // period and length matter even inside one session.
                        if items.count >= 4 || activeFilterCount > 0 {
                            filterBar
                        }
                        if items.isEmpty {
                            Text(L.s("no_match", lang))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .padding(.vertical, 40)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)],
                                  spacing: 10) {
                            ForEach(items, id: \.clip.id) { pair in
                                ClipCard(clip: pair.clip,
                                         showSession: pair.session.placeName
                                             ?? L.dateOnly(pair.session.playedAt, lang),
                                         selected: selecting ? selection.contains(pair.clip.id) : nil) {
                                    if selecting {
                                        if selection.contains(pair.clip.id) {
                                            selection.remove(pair.clip.id)
                                        } else {
                                            selection.insert(pair.clip.id)
                                        }
                                    } else if pair.clip.isReady {
                                        playing = pair.clip
                                    }
                                }
                            }
                        }
                        .padding()
                        // clear the floating tab bar
                        Color.clear.frame(height: 62)
                    }
                    // Pinned, not appended: at the end of the scroll a user who
                    // ticked two clips at the top had to scroll past every
                    // remaining clip to find out what selecting them does.
                    .safeAreaInset(edge: .bottom) {
                        if selecting {
                            selectionBar
                                .padding(.horizontal)
                                .padding(.bottom, 62)
                        }
                    }
                }
            }
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog(String(format: L.s(selection.count == 1 ? "delete_one_clip"
                                                                     : "delete_n_clips", lang),
                                    selection.count),
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L.s("delete", lang), role: .destructive) { deleteSelected() }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(feature: L.s("feat_saveall", lang))
            }
            .alert(saveMessage ?? "", isPresented: Binding(
                get: { saveMessage != nil }, set: { if !$0 { saveMessage = nil } })) {
                Button("OK", role: .cancel) { saveMessage = nil }
            }
            .sheet(item: $playing) { clip in
                ClipPlayerSheet(clip: clip)
            }
            .sheet(item: $reel) { ReelSheet(request: $0) }
        }
    }

    /// Collapsible filter panel.
    ///
    /// With six conditions, laying them all out flat cost more screen than the
    /// clips did. Collapsed it is one row that still shows what is active, so
    /// the current filter is never hidden from the user — only the controls are.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.18)) { filtersOpen.toggle() } } label: {
                HStack(spacing: 8) {
                    Label(L.s("filter", lang), systemImage: "line.3.horizontal.decrease")
                        .font(.subheadline.bold())
                    if activeFilterCount > 0 {
                        Text(String(activeFilterCount))
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(Theme.onAccent)
                    }
                    Spacer()
                    if activeFilterCount > 0 {
                        Text(L.s("clear", lang))
                            .font(.caption.bold())
                            .foregroundStyle(Theme.accent)
                            .onTapGesture { clearFilters() }
                    }
                    Image(systemName: filtersOpen ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if filtersOpen {
                filterGroup(L.s("f_when", lang)) {
                    ForEach(WhenFilter.allCases) { w in
                        chipButton(L.s(w.key, lang), active: whenFilter == w) {
                            whenFilter = whenFilter == w ? nil : w
                        }
                    }
                }
                filterGroup(L.s("sport", lang)) {
                    ForEach(Sport.allCases) { sp in
                        chipButton("\(sp.emoji) \(L.s(sp.rawValue, lang))",
                                   active: sportFilter == sp) {
                            sportFilter = sportFilter == sp ? nil : sp
                        }
                    }
                }
                let places = store.knownPlaces()
                if !places.isEmpty {
                    filterGroup(L.s("place", lang)) {
                        ForEach(places, id: \.self) { place in
                            chipButton(place, active: placeFilter == place, icon: "mappin.and.ellipse") {
                                placeFilter = placeFilter == place ? nil : place
                            }
                        }
                    }
                }
                filterGroup(L.s("f_shape", lang)) {
                    ForEach([OutputFrame.landscape, .vertical, .portrait45],
                            id: \.rawValue) { frame in
                        chipButton(frame.label, active: shapeFilter == frame.rawValue) {
                            shapeFilter = shapeFilter == frame.rawValue ? nil : frame.rawValue
                        }
                    }
                }
                filterGroup(L.s("f_len", lang)) {
                    ForEach([5, 10, 15], id: \.self) { secs in
                        chipButton(String(format: L.s("len_fmt", lang), secs),
                                   active: minSeconds == secs) {
                            minSeconds = minSeconds == secs ? 0 : secs
                        }
                    }
                }
                filterGroup(L.s("f_hits", lang)) {
                    ForEach([4, 6, 10], id: \.self) { h in
                        chipButton(String(format: L.s("hits_fmt", lang), h),
                                   active: minHits == h) {
                            minHits = minHits == h ? 0 : h
                        }
                    }
                    chipButton(L.s("f_fav", lang), active: favesOnly, icon: "star.fill") {
                        favesOnly.toggle()
                    }
                }
            } else if activeFilterCount > 0 {
                activeSummary
            }
        }
        .padding(14)
        .rcCard()
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// One labelled, horizontally scrolling row of chips.
    private func filterGroup<C: View>(_ title: String,
                                      @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { content() }.padding(.horizontal, 1)
            }
        }
    }

    private func chipButton(_ title: String, active: Bool,
                            icon: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Label(title, systemImage: icon) } else { Text(title) }
            }
            .lineLimit(1)
            .chip(active: active)
        }
        .buttonStyle(.plain)
    }

    /// What is filtering right now, readable without opening the panel.
    private var activeSummary: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(activeLabels, id: \.self) { text in
                    Text(text)
                        .font(.caption2.bold())
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var activeLabels: [String] {
        var out: [String] = []
        if let whenFilter { out.append(L.s(whenFilter.key, lang)) }
        if let sportFilter { out.append(L.s(sportFilter.rawValue, lang)) }
        if let placeFilter { out.append(placeFilter) }
        if let shapeFilter { out.append(OutputFrame(shapeFilter).label) }
        if minSeconds > 0 { out.append(String(format: L.s("len_fmt", lang), minSeconds)) }
        if minHits > 0 { out.append(String(format: L.s("hits_fmt", lang), minHits)) }
        return out
    }

    private var activeFilterCount: Int {
        (sportFilter == nil ? 0 : 1) + (minSeconds == 0 ? 0 : 1)
            + (placeFilter == nil ? 0 : 1) + (whenFilter == nil ? 0 : 1)
            + (shapeFilter == nil ? 0 : 1) + (minHits == 0 ? 0 : 1)
            + (favesOnly ? 1 : 0)
    }

    private func clearFilters() {
        sportFilter = nil; minSeconds = 0; placeFilter = nil
        whenFilter = nil; shapeFilter = nil; minHits = 0; favesOnly = false
    }

    private var selectionBar: some View {
        VStack(spacing: 10) {
            Text(String(format: L.s("selected_fmt", lang), selection.count))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Clips picked across sessions still make one reel, joined in the
            // order they were played.
            Button {
                let picked = store.allClips().filter {
                    selection.contains($0.clip.id) && $0.clip.isReady
                }
                guard !picked.isEmpty else { return }
                reel = ReelRequest(pairs: picked)
            } label: {
                Label(L.s("reel_make", lang),
                      systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                    .frame(maxWidth: .infinity)
            }
            .rcPrimary()
            .disabled(selection.isEmpty)

            HStack(spacing: 10) {
                Button {
                    guard purchases.isPro || selection.count <= 1 else {
                        showPaywall = true; return
                    }
                    Task { await saveSelected() }
                } label: {
                    HStack(spacing: 6) {
                        Label(L.s("save", lang),
                              systemImage: purchases.isPro || selection.count <= 1
                                  ? "square.and.arrow.down" : "lock.fill")
                        if !purchases.isPro && selection.count > 1 { ProBadge() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .rcSecondary()
                .disabled(selection.isEmpty)

                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L.s("delete", lang), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .rcSecondary(destructive: true)
                .disabled(selection.isEmpty)
            }
        }
        .padding(14)
        .rcCard()
    }

    /// Selected clips can span sessions, so the work is grouped per session
    /// before it reaches the store.
    private func deleteSelected() {
        let grouped = Dictionary(grouping: store.allClips().filter {
            selection.contains($0.clip.id)
        }, by: { $0.session.id })
        for (sessionID, pairs) in grouped {
            guard let session = store.sessions.first(where: { $0.id == sessionID }) else { continue }
            store.deleteClips(Set(pairs.map(\.clip.id)), from: session)
        }
        selection.removeAll()
        selecting = false
    }

    private func saveSelected() async {
        let grouped = Dictionary(grouping: store.allClips().filter {
            selection.contains($0.clip.id)
        }, by: { $0.session.id })
        var saved = 0
        var denied = false
        for (sessionID, pairs) in grouped {
            guard let session = store.sessions.first(where: { $0.id == sessionID }) else { continue }
            if let n = await store.saveClipsToPhotos(session, ids: Set(pairs.map(\.clip.id))) {
                saved += n
            } else { denied = true }
        }
        saveMessage = denied ? L.s("photos_denied", lang)
                             : String(format: L.s("saved_n_fmt", lang), saved)
    }

    private func sorted(_ items: [(session: Session, clip: ClipInfo)])
        -> [(session: Session, clip: ClipInfo)] {
        switch sort {
        case .time:
            return items.sorted {
                ($0.session.playedAt, $0.clip.segment.start)
                    > ($1.session.playedAt, $1.clip.segment.start)
            }
        default:
            return items.sorted { sort.precedes($0.clip, $1.clip) }
        }
    }
}
