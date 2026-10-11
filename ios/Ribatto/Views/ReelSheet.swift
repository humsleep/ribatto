import AVKit
import StoreKit
import SwiftUI

/// The clips a reel is being built from. Wrapped in a type so it can drive a
/// `.sheet(item:)` — an array of tuples can't.
struct ReelRequest: Identifiable {
    let id = UUID()
    let pairs: [(session: Session, clip: ClipInfo)]
    /// How the reel starts out. The session's one-tap highlight opens on the
    /// hook; a hand-picked selection on the whole rallies the user chose.
    var pace: ReelPace = .full
    /// The caller already put the rallies in the order it wants — the
    /// highlight leads with its best one. Otherwise they are played in the
    /// order they happened.
    var keepOrder = false
    /// Rallies listed under Edit but left out of the first build, so the
    /// user can add one the automatic pick skipped. Appended after `pairs`,
    /// in the order given.
    var extras: [(session: Session, clip: ClipInfo)] = []
}

extension ClipInfo {
    /// This clip with a different range — what a reel actually plays. The
    /// clip file is untouched; a reel renders from the original.
    func with(segment: RallySegment) -> ClipInfo {
        ClipInfo(id: id, index: index, url: url, thumbURL: thumbURL, segment: segment,
                 orientation: orientation, sessionID: sessionID, isReady: isReady)
    }

    /// Cut to its strikes for a reel (`RallySegment.playTrimmed`).
    var forReel: ClipInfo { with(segment: segment.playTrimmed) }
}

/// Turns one or more rallies into a single vertical video, then hands it off
/// to Instagram, Photos or the share sheet.
///
/// There is no setup screen. The sheet builds with sensible defaults the
/// moment it opens and lands on the result: a screen of platform, look, pace
/// and frame choices stood between the user and a reel most of them never
/// changed. Everything that mattered is one tap away under Edit.
struct ReelSheet: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var ads: AdsManager
    @EnvironmentObject var pass: ProPass
    @AppStorage("rc_lang") private var lang = "en"
    /// Set once the rating prompt has been offered, so it is asked for at
    /// most once from here — Apple rations it further on its own.
    @AppStorage("rc_review_asked") private var reviewAsked = false
    @Environment(\.requestReview) private var requestReview
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// A row is two lines of text; held at 52pt the list showed one rally of
    /// four at accessibility sizes and hid the rest behind a scroll.
    @ScaledMetric(relativeTo: .subheadline) private var reelRowHeight: CGFloat = 52
    let request: ReelRequest

    /// Kept internally, no longer offered: the platforms differed only in
    /// their length cap, and Reels' 90 seconds is the one people post to.
    private let target: ReelTarget = .reels
    @State private var frame: OutputFrame = .vertical
    @State private var pace: ReelPace
    /// Off replaces every session's caption with a hidden one for this reel
    /// only; on keeps each session's own.
    @State private var captionOn = true
    @State private var building = false
    /// The automatic first build has been started. `onAppear`-style hooks fire
    /// again when a sheet over this one closes, and a second build would
    /// throw away the first.
    @State private var started = false
    @State private var editing = false
    /// Why the last build failed, shown in place of the result.
    @State private var failure: String?
    /// Loops the built reel. Owned by an object rather than torn down in
    /// `onDisappear`: a full-screen ad over the sheet fires that, and the reel
    /// came back from the ad no longer looping.
    @State private var looper = Looper()
    /// "Photos access is off" comes with the way to turn it on.
    @State private var offerSettings = false
    @State private var done: (url: URL, plan: ReelPlan)?
    @State private var player: AVPlayer?
    @State private var message: String?
    @State private var savedToPhotos = false
    @State private var showPass = false
    @State private var reviewPending = false
    /// The running order, with each rally's own in/out switch. Seeded from the
    /// request and then owned by this screen, so reordering and excluding
    /// don't have to reach back into the selection that made it.
    @State private var entries: [Entry] = []
    /// What the reel on screen was built from. Rebuilding with nothing
    /// changed makes the same file again, so the button only appears — and
    /// only takes the primary style — once something differs.
    @State private var builtWith: String?
    /// The frame of the reel on screen, which the edit panel may have moved on
    /// from before a rebuild.
    @State private var builtFrame: OutputFrame = .vertical

    private var currentRecipe: String {
        chosen.map(\.id).joined(separator: ",") + "|" + pace.rawValue + "|"
            + frame.rawValue + "|" + String(captionOn)
    }
    private var changed: Bool { builtWith != currentRecipe }

    init(request: ReelRequest) {
        self.request = request
        _pace = State(initialValue: request.pace)
    }

    struct Entry: Identifiable {
        let id: String
        let session: Session
        let clip: ClipInfo
        var included = true
    }

    private var chosen: [Entry] { entries.filter(\.included) }

    /// Seconds the reel will run at the current pace, before the platform cap.
    private var totalSeconds: Double {
        chosen.reduce(0) { $0 + pace.estimatedLength(of: $1.clip.segment) }
    }

    /// How much of that the cap will actually take.
    private var cappedSeconds: Double {
        guard let max = target.maxDuration else { return totalSeconds }
        return Swift.min(totalSeconds, max)
    }
    private var overCap: Bool {
        guard let max = target.maxDuration else { return false }
        return totalSeconds > max + 0.5
    }

    /// Whether any rally here would carry a caption. The switch is noise for
    /// the common case of a session with none.
    private var hasCaptions: Bool {
        entries.contains { $0.session.caption?.isVisible == true }
    }

    /// The one rally marked "Best" in the list, by score. A badge instead of
    /// the raw score: "★ 0.73" meant nothing to anyone but the detector.
    private var bestID: String? {
        guard entries.count > 1 else { return nil }
        let scored = entries.filter { $0.clip.segment.score != nil }
        let single = scored.filter { !$0.clip.segment.looksMerged }
        return (single.isEmpty ? scored : single)
            .max { ($0.clip.segment.score ?? -1) < ($1.clip.segment.score ?? -1) }?.id
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        // Progress and failure come before the result: a rebuild
                        // kept showing the old reel with no sign anything was
                        // happening, and a failed one changed nothing visible.
                        // While building the result is hidden entirely, which
                        // also takes Post, Save and Share out of reach.
                        VStack(spacing: 18) {
                            if building || (done == nil && failure == nil) {
                                buildingView
                            } else {
                                if let failure { failureView(failure) }
                                if let done { resultView(done) }
                            }
                        }
                        .id("top")
                        if editing && !building { editPanel }
                    }
                    .padding(20)
                }
                .onChange(of: done?.url) { _, _ in
                    withAnimation { proxy.scrollTo("top", anchor: .top) }
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(L.s("reel_title", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L.s("close", lang))
                        .tint(.secondary)
                        .disabled(building)
                }
            }
            .alert(message ?? "", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } })) {
                if offerSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button(L.s("photos_open_settings", lang)) {
                        offerSettings = false
                        message = nil
                        UIApplication.shared.open(url)
                    }
                }
                Button("OK", role: .cancel) {
                    offerSettings = false
                    message = nil
                    if reviewPending {
                        reviewPending = false
                        reviewAsked = true
                        requestReview()
                    }
                }
            }
            .sheet(isPresented: $showPass) { ProPassView() }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(building)
        .task {
            guard !started else { return }
            started = true
            entries = (request.keepOrder ? request.pairs : request.pairs
                .sorted { ($0.session.playedAt, $0.clip.segment.start)
                        < ($1.session.playedAt, $1.clip.segment.start) })
                // Every rally cut to its strikes, whoever chose it. The cut
                // range is what gets built and what the sidecar records, so a
                // caption-only rebuild from the Reels tab makes the same reel.
                // Idempotent: the highlight's picks arrive already cut.
                .map { Entry(id: $0.session.id.uuidString + "-" + $0.clip.id,
                             session: $0.session, clip: $0.clip.forReel) }
                + request.extras.map { Entry(id: $0.session.id.uuidString + "-" + $0.clip.id,
                                             session: $0.session, clip: $0.clip.forReel,
                                             included: false) }
            await build()
        }
    }

    // MARK: - Building

    /// The first rally's poster under the progress, so the wait already looks
    /// like the thing being made.
    private var buildingView: some View {
        VStack(spacing: 14) {
            Color.clear
                .aspectRatio(frame.aspectRatio, contentMode: .fit)
                .frame(maxHeight: typeSize.isAccessibilitySize ? 220 : 360)
                .overlay {
                    if let first = chosen.first { PosterImage(url: first.clip.thumbURL) }
                }
                .overlay { Color.black.opacity(0.35) }
                .overlay { ProgressView().controlSize(.large).tint(.white) }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity)
            VStack(spacing: 8) {
                if let p = buildProgress {
                    ProgressView(value: Double(p.done), total: Double(p.total))
                        .tint(Theme.accent)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                }
                Text(buildingLabel)
                    .font(.subheadline.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                // Leaving the app is what stops a long build, so it is said
                // in readable text, not a footnote.
                Label(L.s("keep_awake", lang), systemImage: "iphone.gen3")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buildProgress: (done: Int, total: Int)? {
        // The store keys progress on the first rally actually built, which is
        // the first *included* row in the user's order — not the first of the
        // original request, which may have been dragged down or switched off.
        guard let key = chosen.first?.session.id,
              case .reel(let d, let t)? = store.progress[key], t > 0 else { return nil }
        return (d, t)
    }

    private var buildingLabel: String {
        if let p = buildProgress { return L.s("reel_building", lang) + "  \(p.done)/\(p.total)" }
        return L.s("reel_building", lang)
    }

    private func failureView(_ text: String) -> some View {
        VStack(spacing: 12) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { Task { await build() } } label: {
                Label(L.s("try_again", lang), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .rcPrimary()
            .disabled(chosen.isEmpty)
            // With a reel still on screen below, its own Edit button serves.
            if done == nil { editButton }
        }
        .padding(14)
        .rcCard()
    }

    // MARK: - Result

    private func resultView(_ done: (url: URL, plan: ReelPlan)) -> some View {
        VStack(spacing: 14) {
            if let player {
                // Shorter at accessibility sizes so the post button is on the
                // first screen rather than under a phone-high video. Narrowed
                // to the reel's own shape: at full width a 9:16 reel sat in a
                // wide black box and looked small, like a bug.
                let height: CGFloat = typeSize.isAccessibilitySize ? 300 : 420
                let controls: CGFloat = 64
                ZoomableVideo(player: player)
                    .frame(width: max(240, (height - controls) * builtFrame.aspectRatio),
                           height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(String(format: L.s(done.plan.used == 1 ? "reel_used_one_fmt" : "reel_used_fmt", lang),
                             done.plan.used, fmtDur(done.plan.duration)),
                      systemImage: "film")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if done.plan.trimmed {
                    Label(L.s("reel_trimmed", lang), systemImage: "scissors")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                if done.plan.dropped > 0 {
                    Label(String(format: L.s(done.plan.dropped == 1 ? "reel_dropped_one_fmt" : "reel_dropped_fmt", lang),
                                 done.plan.dropped),
                          systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Posting is why the reel exists, so it leads. Instagram takes a
            // video from the camera roll, so the button saves it first and then
            // opens the app with it at the top of the picker.
            // Steps down while an edited, not yet rebuilt reel is pending:
            // two primaries on screen and the one that posts the OLD reel
            // looked like the next step.
            if editing && changed {
                instagramButton(done.url).rcSecondary()
            } else {
                instagramButton(done.url).rcPrimary()
            }

            // Side by side where they fit; stacked where "Save to Photos" and
            // "Share" would otherwise break mid-word.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { saveButton(done.url); shareButton(done.url) }
                VStack(spacing: 10) { saveButton(done.url); shareButton(done.url) }
            }

            editButton

            if !pass.isPro && ads.showing { passLine }
        }
    }

    private func instagramButton(_ url: URL) -> some View {
        Button { postToInstagram(url) } label: {
            Label(L.s("reel_post_ig", lang), systemImage: "camera.aperture")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    private func saveButton(_ url: URL) -> some View {
        Button {
            Task {
                let result = await store.saveVideoToPhotos(url)
                savedToPhotos = result == .saved
                report(result)
            }
        } label: {
            Label(savedToPhotos ? L.s("reel_saved", lang) : L.s("reel_save", lang),
                  systemImage: savedToPhotos ? "checkmark" : "square.and.arrow.down")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .rcSecondary()
    }

    private func shareButton(_ url: URL) -> some View {
        ShareLink(item: url) {
            Label(L.s("share", lang), systemImage: "square.and.arrow.up")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .rcSecondary()
    }

    private var editButton: some View {
        Button {
            withAnimation(.snappy) { editing.toggle() }
        } label: {
            Label(L.s(editing ? "done" : "reel_edit", lang),
                  systemImage: editing ? "chevron.up" : "slider.horizontal.3")
                .frame(maxWidth: .infinity)
        }
        .rcSecondary()
        .disabled(building)
    }

    /// The reel is what gets posted, so this is where a watermark costs the
    /// user the most — and where the one-hour pass is worth the most to them.
    /// One quiet line: it used to be a card, and an offer that loud above a
    /// finished reel read as the price of the reel.
    private var passLine: some View {
        // The pass sheet plays an ad of its own; the reel kept going under it.
        Button { player?.pause(); showPass = true } label: {
            (Text(Image(systemName: "sparkles")) + Text("  ")
             + Text(L.s("reel_pass_line", lang))
             + Text("  ") + Text(Image(systemName: "chevron.right")).font(.caption2))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Edit

    private var editPanel: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text(String(format: L.s("reel_included_fmt", lang),
                            chosen.count, entries.count)
                     + " · " + fmtDur(cappedSeconds))
                    .font(.headline)
                    .foregroundStyle(chosen.isEmpty ? Theme.warning : .primary)
                if overCap {
                    Label(L.s("reel_over_cap", lang) + " · " + fmtDur(totalSeconds),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if entries.count > 1 { runningOrderCard }
            paceCard
            frameCard
            if hasCaptions {
                Toggle(isOn: $captionOn) {
                    Text(L.s("show_caption", lang)).font(.subheadline)
                }
                .tint(Theme.accent)
                .padding(14)
                .rcCard()
            }
            // Only once something differs from the reel on screen; after a
            // failure there is no reel, so it is always offered.
            if changed || done == nil {
                Button { Task { await build() } } label: {
                    Label(L.s("reel_rebuild", lang), systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .rcPrimary()
                .disabled(chosen.isEmpty)
            }
        }
    }

    /// The running order, with a switch per rally and a shortcut that keeps
    /// only the best-scoring ones. Picking which fifteen seconds to post is the
    /// actual work in a 26-minute match, so the shortcut leads.
    /// Title and the keep-the-best shortcuts. Side by side the shortcuts claim
    /// the width at accessibility sizes and squeeze the title into a one-word
    /// column, so there they sit on their own line.
    @ViewBuilder private var reorderHeader: some View {
        let hasShortcuts = entries.count > 3
            && entries.contains(where: { $0.clip.segment.score != nil })
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.s("reel_reorder", lang)).font(.subheadline.bold())
                if hasShortcuts {
                    HStack(spacing: 16) { topShortcuts }
                }
            }
        } else {
            HStack {
                Text(L.s("reel_reorder", lang)).font(.subheadline.bold())
                Spacer()
                if hasShortcuts { topShortcuts }
            }
        }
    }

    private var topShortcuts: some View {
        ForEach([3, 5], id: \.self) { n in
            Button(String(format: L.s("reel_pick_top", lang), n)) { keepTop(n) }
                .font(.caption.bold())
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runningOrderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            reorderHeader
            List {
                ForEach($entries) { $entry in
                    HStack(spacing: 10) {
                        Button { entry.included.toggle() } label: {
                            Image(systemName: entry.included
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(entry.included ? Theme.accent
                                                 : Color.secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        // VoiceOver read a bare "button" per row with no hint of
                        // which rally or whether it was in the reel.
                        .accessibilityLabel("#\(entry.clip.index + 1) · "
                            + fmtDur(pace.estimatedLength(of: entry.clip.segment))
                            + (entry.id == bestID ? " · " + L.s("best_rally", lang) : ""))
                        .accessibilityAddTraits(entry.included ? .isSelected : [])
                        VStack(alignment: .leading, spacing: 1) {
                            Text("#\(entry.clip.index + 1) · "
                                 + fmtDur(pace.estimatedLength(of: entry.clip.segment)))
                                .font(.subheadline.weight(.medium))
                            HStack(spacing: 6) {
                                Text(String(entry.clip.segment.hits) + " " + L.s("shots_n", lang))
                                    .font(.caption2).foregroundStyle(.secondary)
                                if entry.id == bestID {
                                    Text(L.s("best_rally", lang))
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.6)))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        }
                        Spacer(minLength: 0)
                    }
                    .opacity(entry.included ? 1 : 0.45)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Color.secondary.opacity(0.2))
                }
                .onMove { from, to in entries.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Tall enough for the whole reel where it fits, scrollable where
            // it doesn't. Capping at 320pt with scrolling off meant a 20-rally
            // reel showed six rows and silently hid the rest — they were in the
            // reel, but could not be seen, reordered or deselected.
            .environment(\.editMode, .constant(.active))
            .frame(height: min(CGFloat(entries.count) * reelRowHeight + 8, 520))
        }
        .padding(14)
        .rcCard()
        .disabled(building)
    }

    /// Keeps the `n` best-scoring rallies switched on. Unscored rallies (from
    /// sessions detected before scoring existed) rank last rather than at zero.
    private func keepTop(_ n: Int) {
        let best = entries.sorted { ($0.clip.segment.score ?? -1) > ($1.clip.segment.score ?? -1) }
            .prefix(n).map(\.id)
        for i in entries.indices { entries[i].included = best.contains(entries[i].id) }
    }

    /// Segmented where all three names fit, which in English they do; as rows
    /// where they don't — "Ganzer Ballwechsel · Nur der Schluss · Hook" does
    /// not fit three ways across a phone in German.
    private var paceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.s("reel_pace", lang))
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                Picker("", selection: $pace) {
                    ForEach(ReelPace.allCases) { p in
                        Text(L.s("pace_" + p.rawValue, lang)).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                VStack(spacing: 10) {
                    ForEach(ReelPace.allCases) { p in
                        Button { pace = p } label: {
                            selectableRow(
                                badge: Image(systemName: p.symbol)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(pace == p ? Theme.onAccent : Theme.accent)
                                    .frame(width: 26, height: 26)
                                    .background(pace == p ? Theme.accent : Theme.surfaceHigh,
                                                in: Circle()),
                                title: L.s("pace_" + p.rawValue, lang),
                                detail: "",
                                selected: pace == p)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(L.s("pace_" + pace.rawValue + "_d", lang))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .rcCard()
    }

    /// 9:16 vs 4:5. Worth a choice rather than a constant: 9:16 keeps 31.6% of
    /// a wide match's width, which on real footage leaves the opponent right on
    /// the edge; 4:5 keeps 45% and holds both players with margin.
    private var frameCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.s("reel_frame", lang))
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: $frame) {
                Text(OutputFrame.vertical.label).tag(OutputFrame.vertical)
                Text(OutputFrame.portrait45.label).tag(OutputFrame.portrait45)
            }
            .pickerStyle(.segmented)
            Text(L.s(frame == .vertical ? "frame_916_d" : "frame_45_d", lang))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .rcCard()
    }

    /// A pick-one row. The badge and the selection mark hold fixed columns, and
    /// at accessibility sizes what is left is narrower than the longest word —
    /// "Instagram Reels" broke as "Instagra / m Reels". There the two glyphs
    /// share a line and the text owns the width below them.
    @ViewBuilder
    private func selectableRow<Badge: View>(badge: Badge, title: String,
                                            detail: String, selected: Bool) -> some View {
        let mark = Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.5))
        let text = VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.subheadline.bold())
            if !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack { badge; Spacer(minLength: 6); mark }
                text
            }
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 12) { badge; text; Spacer(minLength: 6); mark }
                .contentShape(Rectangle())
        }
    }

    // MARK: - Actions

    /// Builds the reel from the current choices. A rebuild replaces what is on
    /// screen only once it has succeeded; the reel it replaces stays in the
    /// Reels tab, where the store filed it when it was made.
    private func build() async {
        guard !building else { return }
        building = true
        failure = nil
        defer { building = false }
        let pairs = chosen.map { (session: $0.session, clip: $0.clip) }
        // Never a silent return: with nothing to show, the screen sat on its
        // spinner forever.
        guard !pairs.isEmpty else {
            failure = L.s("render_failed", lang)
            return
        }
        // Read before the await: a toggle flipped during the build must still
        // count as a change against what was actually built.
        let recipe = currentRecipe
        // A busy session used to report that the user's original video was
        // gone from Photos, which is the most alarming thing the app can say
        // and was untrue.
        if pairs.contains(where: { store.isBusy($0.session.id) }) {
            failure = L.s("busy_wait", lang)
            return
        }
        guard let out = await store.buildReel(from: pairs, target: target,
                                              frame: frame, pace: pace,
                                              preset: nil,
                                              caption: captionOn ? nil : CaptionSettings())
        else {
            failure = pairs.first(where: { store.sourceMissing($0.session) })
                .map { L.s(store.sourceProblemKey($0.session), lang) }
                ?? L.s("render_failed", lang)
            return
        }
        player?.pause()
        let next = AVPlayer(url: out.url)
        // Loops: the result screen is where the user decides whether to post
        // it, usually after watching it more than once. With the default the
        // transport button claimed to play at the end and nothing moved.
        next.actionAtItemEnd = .none
        looper.watch(next)
        player = next
        builtWith = recipe
        builtFrame = frame
        savedToPhotos = false
        editing = false
        // The reel this sheet made before "Make again" was a draft the user
        // just replaced; left in the library, every tweak piled up another
        // copy. Only this sheet's own previous build (`done` is only ever set
        // here), and only now that its replacement exists — a failed rebuild
        // returned above and kept it. A copy already saved to Photos stays.
        if let previous = done?.url, previous != out.url {
            let id = previous.deletingPathExtension().lastPathComponent
            if let info = store.reels().first(where: { $0.id == id }) {
                store.deleteReel(info)
            }
        }
        done = out
        // Owed, not shown: an ad the moment the reel appeared covered the
        // first look at it. The screen that opened this sheet shows it once
        // the sheet is closed.
        ads.markInterstitialDue()
    }

    private func postToInstagram(_ url: URL) {
        Task {
            if !savedToPhotos {
                let result = await store.saveVideoToPhotos(url)
                savedToPhotos = result == .saved
                guard savedToPhotos else { report(result); return }
            }
            open("instagram://app", "Instagram")
        }
    }

    private func report(_ result: SessionStore.PhotoSave) {
        switch result {
        case .saved:
            message = L.s("reel_saved", lang)
            // The first reel that made it to the camera roll is the moment the
            // app has just done its whole job. Asked once the alert is closed.
            if !reviewAsked { reviewPending = true }
        case .denied:
            offerSettings = true
            message = L.s("photos_denied", lang)
        case .failed:
            message = L.s("photos_save_failed", lang)
        }
    }

    /// iOS reports whether the target app was there, so a missing app gets a
    /// real message instead of a button that quietly does nothing.
    private func open(_ scheme: String, _ name: String) {
        guard let url = URL(string: scheme) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok { message = String(format: L.s("app_missing_fmt", lang), name) }
        }
    }
}

/// Seeks a player back to the start whenever its item ends. A class so the
/// observer goes with the sheet's state rather than with `onDisappear`, which
/// also fires while an ad covers the sheet.
private final class Looper {
    private var token: NSObjectProtocol?

    func watch(_ player: AVPlayer) {
        stop()
        token = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak player] _ in
                player?.seek(to: .zero)
            }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }

    deinit { stop() }
}
