import AVKit
import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var purchases: PurchaseManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.horizontalSizeClass) private var hSize
    let sessionID: UUID

    @State private var sort: ClipSort = .time
    @State private var destination: Destination?
    @State private var confirmDeleteSession = false
    @State private var selecting = false
    @State private var selection: Set<String> = []

    @State private var saveMessage: String?
    @State private var editingPlace = false
    @State private var placeDraft = ""

    enum ClipSort { case time, best, long, short }

    /// Every modal this screen can show, so a single .sheet drives them all.
    private enum Destination: Identifiable {
        case clip(ClipInfo)
        case highlight
        case merged(URL)
        case paywall(feature: String?)
        case caption
        case targetPlayer
        case reel(ReelRequest)

        var id: String {
            switch self {
            case .clip(let c): return "clip-" + c.id
            case .highlight: return "highlight"
            case .merged(let u): return "merged-" + u.lastPathComponent
            case .paywall(let f): return "paywall-" + (f ?? "")
            case .caption: return "caption"
            case .targetPlayer: return "target-player"
            case .reel(let r): return "reel-" + r.id.uuidString
            }
        }
    }

    private var session: Session? { store.sessions.first { $0.id == sessionID } }
    private var statColumns: Int { hSize == .compact ? 2 : 4 }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func content(_ session: Session) -> some View {
        let clips = sorted(store.clips(of: session))
        let busy = store.progress[sessionID] != nil

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsCard(session, busy: busy)

                if let stage = store.progress[sessionID] {
                    progressCard(stage)
                }

                if !clips.isEmpty {
                    if purchases.isPro && session.renderedPro != true {
                        upgradeBanner()
                    }
                    if session.hasHighlight { highlightCard(session) }
                    statsRow(clips)
                    toolbar(session, busy: busy)
                    clipGrid(clips)
                    if selecting {
                        selectionBar(session, busy: busy)
                    } else {
                        saveAllButton(session, busy: busy)
                    }
                    // clear the floating tab bar
                    Color.clear.frame(height: 62)
                } else if !busy {
                    VStack(spacing: 10) {
                        Image(systemName: "film")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(L.s("empty_clips", lang))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding()
        }
        .navigationTitle(L.dateTime(session.playedAt, lang))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !clips.isEmpty {
                    Button(selecting ? L.s("done", lang) : L.s("select", lang)) {
                        selecting.toggle()
                        selection.removeAll()
                    }
                    .font(.subheadline.bold())
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { confirmDeleteSession = true } label: {
                        Label(L.s("delete_session", lang), systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert(L.s("place", lang), isPresented: $editingPlace) {
            TextField(L.s("place_placeholder", lang), text: $placeDraft)
            Button(L.s("apply", lang)) { store.setPlaceName(session, placeDraft) }
            Button(L.s("cancel", lang), role: .cancel) {}
        }
        .confirmationDialog(L.s("delete_session", lang),
                            isPresented: $confirmDeleteSession) {
            Button(L.s("delete", lang), role: .destructive) {
                store.deleteSession(session)
            }
        }
        .sheet(item: $destination) { dest in
            switch dest {
            case .clip(let clip):
                ClipPlayerSheet(clip: clip)
            case .highlight:
                HighlightPlayerSheet(url: store.highlightURL(session),
                                     name: L.dateTime(session.playedAt, lang))
            case .merged(let url):
                HighlightPlayerSheet(url: url, name: L.s("merged", lang))
            case .paywall(let feature):
                PaywallView(feature: feature)
            case .caption:
                CaptionEditorView(session: session)
            case .targetPlayer:
                TargetPlayerSheet(session: session)
            case .reel(let request):
                ReelSheet(request: request)
            }
        }
    }

    // MARK: - Settings
    // Grid sizes the label column to the widest label, so the controls stay
    // aligned in every language and at every Dynamic Type size.

    private func settingsCard(_ session: Session, busy: Bool) -> some View {
        VStack(spacing: 14) {
            // the place comes from the video's metadata, but reverse geocoding
            // needs a network — so it stays editable by hand
            Button {
                placeDraft = session.placeName ?? ""
                editingPlace = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                    Text(session.placeName ?? L.s("add_place", lang))
                        .foregroundStyle(session.placeName == nil ? .secondary : .primary)
                    Image(systemName: "pencil")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                .font(.subheadline.weight(.medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The card title already shows when the match was filmed; this only
            // appears when the video was imported on a different day, which is
            // the only time the second date tells the user anything.
            if session.importDiffersFromCapture {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                    Text(L.s("imported", lang) + " · "
                         + L.dateOnly(session.createdAt, lang))
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    label(L.s("sport", lang))
                    Picker("", selection: Binding(
                        get: { session.sport },
                        set: { v in store.setSport(session, v) })) {
                        ForEach(Sport.allCases) { sp in
                            Text("\(sp.emoji) \(L.s(sp.rawValue, lang))").tag(sp)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    label(L.s("aspect", lang))
                    Picker("", selection: Binding(
                        get: { session.aspect },
                        set: { v in store.setAspect(session, v) })) {
                        Text(L.s("auto", lang)).tag(AspectSetting.auto)
                        Text(L.s("wide", lang)).tag(AspectSetting.landscape)
                        Text("9:16").tag(AspectSetting.vertical)
                        Text("4:5").tag(AspectSetting.portrait45)
                    }
                    .pickerStyle(.segmented)
                }
                GridRow {
                    label(L.s("sensitivity", lang))
                    Picker("", selection: Binding(
                        get: { session.sensitivity },
                        set: { v in store.setSensitivity(session, v) })) {
                        Text(L.s("strict", lang)).tag(Sensitivity.low)
                        Text(L.s("normal", lang)).tag(Sensitivity.normal)
                        Text(L.s("loose", lang)).tag(Sensitivity.high)
                    }
                    .pickerStyle(.segmented)
                }
            }

            // panning only matters on a portrait crop, so keep it out of the
            // way when the session is wide
            if OutputFrame(session.effectiveOrientation).isPortrait {
                cropWidthHint(session)
                Toggle(isOn: Binding(
                    get: { purchases.isPro && session.smartCropEnabled },
                    set: { on in
                        guard purchases.isPro else {
                            destination = .paywall(feature: L.s("smart_crop", lang))
                            return
                        }
                        store.setSmartCrop(session, on)
                    })) {
                    HStack(spacing: 6) {
                        Text(L.s("smart_crop", lang)).font(.subheadline)
                        if !purchases.isPro { ProBadge() }
                    }
                }
                .tint(Theme.accent)
                hint(L.s("smart_crop_d", lang))

                targetPlayerRow(session)
                hint(L.s("target_player_d", lang))
                // Only once a player is picked: before that it is a caveat
                // about a feature the user has not chosen yet.
                if session.targetPlayer != nil || !(session.clipTargets ?? [:]).isEmpty {
                    hint(L.s("target_lose_note", lang))
                }
            }

            // free users still see what the export would look like on Pro
            HStack(spacing: 6) {
                Text(L.s("export_quality", lang))
                    .font(.subheadline)
                if !purchases.isPro { ProBadge() }
                Spacer()
                Button {
                    guard !purchases.isPro else { return }
                    destination = .paywall(feature: L.s("feat_quality", lang))
                } label: {
                    Text(purchases.isPro ? L.s("quality_source", lang)
                                         : L.s("quality_720", lang))
                        .font(.caption.bold())
                        .foregroundStyle(purchases.isPro ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            Button { destination = .caption } label: {
                HStack {
                    Label(L.s("edit_caption", lang), systemImage: "textformat")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(session.caption?.isVisible == true
                         ? session.caption!.text : L.s("off", lang))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                // without this the Spacer in the middle of the row swallows taps
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if session.hasPendingChanges {
                Label(L.s("apply_hint", lang), systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if store.sourceMissing(session) {
                Label(L.s("source_missing", lang), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Settings only record a choice — nothing re-processes until this
            // button is pressed — so they stay editable while a render runs.
            // Only the button locks: starting a second pipeline run is the one
            // thing that must not happen. Disabling the whole card instead used
            // to swallow taps on the aspect picker for the first minute after
            // an import, with nothing on screen saying it was locked.
            Button {
                Task { await store.apply(sessionID: sessionID) }
            } label: {
                Text(session.segments == nil ? L.s("detect", lang) : L.s("redetect", lang))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .rcPrimary()
            .disabled(busy || store.sourceMissing(session))
        }
        .padding(14)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    /// One line under a control saying what it actually does. The labels alone
    /// ("Frame the rally") name the feature without explaining it, and both of
    /// these change how every clip is cut.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// How much of a wide frame this crop actually keeps — worth saying before
    /// a render that takes minutes. 9:16 keeps 31.6%, which on court-side
    /// footage puts the opponent on the edge; 4:5 keeps 45%.
    @ViewBuilder
    private func cropWidthHint(_ session: Session) -> some View {
        let frame = OutputFrame(session.effectiveOrientation)
        if session.sourceOrientation == "landscape" {
            // With a player picked the crop stops being "this much of the
            // width" and becomes "this player, close up" — quoting a width
            // then would be wrong.
            let zoomed = purchases.isPro && session.effectiveSmartCrop
                && session.targetPlayer != nil
            let kept = Int((frame.widthKeptFrom169 * 100).rounded())
            Label(zoomed
                    ? L.s("crop_zoomed", lang)
                    : String(format: L.s("crop_keeps_fmt", lang), frame.label, kept),
                  systemImage: zoomed ? "person.fill.viewfinder"
                      : (frame == .vertical ? "person.fill" : "person.2.fill"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Track a player" — opens the picker, or routes free users to the paywall.
    /// Sits under the smart-crop toggle since it rides the same crop path.
    @ViewBuilder
    private func targetPlayerRow(_ session: Session) -> some View {
        let picked = session.targetPlayer != nil
        HStack(spacing: 6) {
            Button {
                guard purchases.isPro else {
                    destination = .paywall(feature: L.s("target_player", lang))
                    return
                }
                destination = .targetPlayer
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: picked
                          ? "person.crop.circle.badge.checkmark"
                          : "person.crop.circle.badge.questionmark")
                        .foregroundStyle(picked ? Theme.accent : .secondary)
                    Text(picked ? L.s("target_change", lang) : L.s("target_pick", lang))
                        .font(.subheadline)
                    if !purchases.isPro { ProBadge() }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if picked {
                Button(L.s("target_clear", lang)) {
                    store.setTargetPlayer(session, nil)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.warning)
            }
        }
    }

    private func progressCard(_ stage: ProcessingStage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StageLabel(stage: stage)
            if case .render(let d, let t) = stage, t > 0 {
                ProgressView(value: Double(d), total: Double(t))
            } else if case .failed = stage {
                EmptyView()
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if case .failed = stage {} else {
                Label(L.s("keep_awake", lang), systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Highlight

    private func highlightCard(_ session: Session) -> some View {
        let title = HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title3).foregroundStyle(.tint)
            Text(L.s("highlight_ready", lang))
                .font(.subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)
        }
        let actions = HStack(spacing: 10) {
            Button(L.s("play", lang)) { destination = .highlight }
                .rcPrimary()
            ShareLink(item: store.highlightURL(session)) {
                Image(systemName: "square.and.arrow.up")
            }
            .rcSecondary()
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { title; Spacer(minLength: 12); actions }
            VStack(alignment: .leading, spacing: 12) {
                title
                actions.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.06, green: 0.15, blue: 0.11),
                                    Color(red: 0.07, green: 0.13, blue: 0.19)],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Pro

    private func upgradeBanner() -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(L.s("pro_rerender_t", lang)).font(.subheadline.bold())
                Text(L.s("pro_rerender_d", lang))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L.s("rerender", lang)) {
                Task { await store.render(sessionID: sessionID) }
            }
            .rcSecondary()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func saveAllButton(_ session: Session, busy: Bool) -> some View {
        Button {
            guard purchases.isPro else {
                destination = .paywall(feature: L.s("save_all", lang))
                return
            }
            Task {
                if let n = await store.saveClipsToPhotos(session) {
                    saveMessage = String(format: L.s("saved_n_fmt", lang), n)
                } else {
                    saveMessage = L.s("photos_denied", lang)
                }
            }
        } label: {
            Label(L.s("save_all", lang),
                  systemImage: purchases.isPro ? "square.and.arrow.down.on.square" : "lock.fill")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .rcSecondary()
        .disabled(busy)
        .padding(.top, 2)
    }

    // MARK: - Selection

    private func selectionBar(_ session: Session, busy: Bool) -> some View {
        let n = selection.count
        let canMerge = n >= 2
        return VStack(spacing: 10) {
            Text(String(format: L.s("selected_fmt", lang), n))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // A reel is the most likely thing to want from a hand-picked set,
            // so it gets the full-width primary slot.
            reelBtn(session, n).frame(maxWidth: .infinity)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { saveBtn(session, n); mergeBtn(session, canMerge); deleteBtn(session, n) }
                VStack(spacing: 10) {
                    HStack(spacing: 10) { saveBtn(session, n); deleteBtn(session, n) }
                    mergeBtn(session, canMerge).frame(maxWidth: .infinity)
                }
            }
        }
        .disabled(busy)
        .padding(14)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func reelBtn(_ session: Session, _ n: Int) -> some View {
        Button {
            let picked = store.clips(of: session)
                .filter { selection.contains($0.id) && $0.isReady }
                .map { (session, $0) }
            guard !picked.isEmpty else { return }
            destination = .reel(ReelRequest(pairs: picked))
        } label: {
            Label(L.s("reel_make", lang),
                  systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                .font(.subheadline.bold()).frame(maxWidth: .infinity)
        }
        .rcPrimary()
        .disabled(n == 0)
    }

    private func saveBtn(_ session: Session, _ n: Int) -> some View {
        Button {
            Task {
                if let saved = await store.saveClipsToPhotos(session, ids: selection) {
                    saveMessage = String(format: L.s("saved_n_fmt", lang), saved)
                } else {
                    saveMessage = L.s("photos_denied", lang)
                }
            }
        } label: {
            Label(L.s("save", lang), systemImage: "square.and.arrow.down")
                .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 24)
        }
        .rcSecondary()
        .disabled(n == 0)
    }

    /// Joining clips is a Pro capability.
    private func mergeBtn(_ session: Session, _ canMerge: Bool) -> some View {
        Button {
            guard purchases.isPro else { destination = .paywall(feature: nil); return }
            Task { if let url = await store.mergeClips(selection, in: session) {
                    destination = .merged(url)
                } }
        } label: {
            Label(L.s("merge", lang),
                  systemImage: purchases.isPro ? "arrow.triangle.merge" : "lock.fill")
                .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 24)
        }
        .rcSecondary()
        .disabled(!canMerge)
    }

    private func deleteBtn(_ session: Session, _ n: Int) -> some View {
        Button(role: .destructive) {
            store.deleteClips(selection, from: session)
            selection.removeAll()
        } label: {
            Label(L.s("delete", lang), systemImage: "trash")
                .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 24)
        }
        .rcSecondary(destructive: true)
        .disabled(n == 0)
    }

    // MARK: - Stats

    private func statsRow(_ clips: [ClipInfo]) -> some View {
        let total = clips.reduce(0) { $0 + $1.duration }
        let longest = clips.map(\.duration).max() ?? 0
        let hits = clips.reduce(0) { $0 + $1.segment.hits }
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                           count: statColumns),
            spacing: 10) {
            stat(L.s("rallies", lang), String(clips.count))
            stat(L.s("total", lang), fmtDur(total))
            stat(L.s("longest", lang), String(Int(longest)) + L.s("sec", lang))
            stat(L.s("shots", lang), String(hits))
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(v)
                .font(.headline.monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Toolbar

    private func toolbar(_ session: Session, busy: Bool) -> some View {
        let picker = Picker("", selection: $sort) {
            Text(L.s("sort_time", lang)).tag(ClipSort.time)
            Text(L.s("sort_best", lang)).tag(ClipSort.best)
            Text(L.s("sort_long", lang)).tag(ClipSort.long)
            Text(L.s("sort_short", lang)).tag(ClipSort.short)
        }
        .pickerStyle(.segmented)

        let reelButton = Button {
            let all = store.clips(of: session).filter(\.isReady).map { (session, $0) }
            guard !all.isEmpty else { return }
            destination = .reel(ReelRequest(pairs: all))
        } label: {
            Label(L.s("reel_make", lang), systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                .font(.subheadline.bold())
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .rcPrimary()
        .disabled(busy)

        let highlightButton = Button {
            Task { await store.makeHighlight(sessionID: sessionID) }
        } label: {
            Label(L.s("make_highlight", lang), systemImage: "sparkles")
                .font(.subheadline.bold())
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .rcSecondary()
        .disabled(busy)

        // Stacked, not side by side: at half width "하이라이트 합본" and its
        // Japanese equivalent truncate, and ViewThatFits can't catch it because
        // a maxWidth:.infinity button reports that it fits any width.
        return VStack(spacing: 10) {
            picker
            reelButton
            if !session.hasHighlight { highlightButton }
        }
    }

    // MARK: - Clips

    private func clipGrid(_ clips: [ClipInfo]) -> some View {
        let frame = OutputFrame(clips.first?.orientation)
        let columns = [GridItem(.adaptive(minimum: frame.isPortrait ? 108 : 165),
                                spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(clips) { clip in
                ClipCard(clip: clip,
                         selected: selecting ? selection.contains(clip.id) : nil) {
                    if selecting {
                        if selection.contains(clip.id) { selection.remove(clip.id) }
                        else { selection.insert(clip.id) }
                    } else if clip.isReady {
                        destination = .clip(clip)
                    }
                }
            }
        }
    }

    private func sorted(_ clips: [ClipInfo]) -> [ClipInfo] {
        switch sort {
        case .time: return clips
        // Unscored clips (detected before scoring existed) sort last rather
        // than mixing in at zero, so an old session doesn't look bad.
        case .best: return clips.sorted { ($0.segment.score ?? -1) > ($1.segment.score ?? -1) }
        case .long: return clips.sorted { $0.duration > $1.duration }
        case .short: return clips.sorted { $0.duration < $1.duration }
        }
    }
}

private struct MergedClip: Identifiable {
    let url: URL
    var id: String { url.path }
}
