import AVKit
import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var pass: ProPass
    @EnvironmentObject var ads: AdsManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let sessionID: UUID

    @State private var sort: ClipSort = .time
    @State private var destination: Destination?
    @State private var confirmDeleteSession = false
    @State private var confirmDeleteClips = false
    @State private var confirmSwitchVertical = false
    @State private var selecting = false
    @State private var selection: Set<String> = []
    /// Whether the user opened the folded settings card by hand.
    @State private var settingsOpen = false
    /// Apply would re-render Pro clips after the pass ran out.
    @State private var confirmFreeRender = false
    @State private var confirmClearClips = false
    /// Whether this screen is the one in front. `destination` only covers this
    /// screen's own sheets; switching tabs mid-render left it nil, and the
    /// interstitial then landed on top of whatever the user had moved on to.
    @State private var onScreen = false

    @State private var saveMessage: String?
    @State private var editingPlace = false
    @State private var placeDraft = ""

    /// Every modal this screen can show, so a single .sheet drives them all.
    private enum Destination: Identifiable {
        case clip(ClipInfo)
        case merged(URL)
        case pro(feature: String?)
        case caption
        case targetPlayer
        case addRally
        case reel(ReelRequest)

        var id: String {
            switch self {
            case .clip(let c): return "clip-" + c.id
            case .merged(let u): return "merged-" + u.lastPathComponent
            case .pro(let f): return "pro-" + (f ?? "")
            case .caption: return "caption"
            case .targetPlayer: return "target-player"
            case .addRally: return "add-rally"
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
        let busy = store.isBusy(sessionID)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsCard(session, busy: busy)

                if let stage = store.progress[sessionID] {
                    progressCard(stage)
                }

                if !clips.isEmpty {
                    if pass.isPro && session.renderedPro != true {
                        upgradeBanner()
                    }
                    statsRow(clips)
                    toolbar(session, busy: busy)
                    clipGrid(clips)
                    if !selecting { saveAllButton(session, busy: busy) }
                    // clear the floating tab bar
                    Color.clear.frame(height: 62)
                } else if !busy {
                    emptyClips(session)
                }
            }
            .padding()
        }
        // Pinned, not appended: below the grid the bar sat a whole screen away
        // from the clips it acts on.
        .safeAreaInset(edge: .bottom) {
            if selecting {
                selectionBar(session, busy: busy)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .adBanner()
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
                    // Storage lives here rather than in a settings screen: the
                    // question is always "what is this match costing me".
                    let used = store.storage(of: session)
                    Section(String(format: L.s("storage_fmt", lang),
                                   ByteCountFormatter.string(fromByteCount: used.clips + used.original,
                                                             countStyle: .file))) {
                        if used.clips > 0 {
                            Button(role: .destructive) { confirmClearClips = true } label: {
                                Label(String(format: L.s("clear_clips_fmt", lang),
                                             ByteCountFormatter.string(fromByteCount: used.clips,
                                                                       countStyle: .file)),
                                      systemImage: "externaldrive.badge.minus")
                            }
                            .disabled(busy || store.sourceMissing(session))
                        }
                    }
                    Button(role: .destructive) { confirmDeleteSession = true } label: {
                        Label(L.s("delete_session", lang), systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(L.s("more", lang))
            }
        }
        .alert(L.s("place", lang), isPresented: $editingPlace) {
            TextField(L.s("place_placeholder", lang), text: $placeDraft)
            Button(L.s("apply", lang)) { store.setPlaceName(session, placeDraft) }
            Button(L.s("cancel", lang), role: .cancel) {}
        }
        // Tracking only does something on a vertical crop. Rather than hide
        // the button on a wide session, say what will change and do it.
        .alert(L.s("target_switch_title", lang), isPresented: $confirmSwitchVertical) {
            Button(L.s("target_switch_ok", lang)) {
                store.setAspect(session, .vertical)
                destination = .targetPlayer
            }
            Button(L.s("cancel", lang), role: .cancel) {}
        } message: {
            Text(L.s("target_switch_msg", lang))
        }
        .alert(saveMessage ?? "", isPresented: Binding(
            get: { saveMessage != nil }, set: { if !$0 { saveMessage = nil } })) {
            Button("OK", role: .cancel) { saveMessage = nil }
        }
        .confirmationDialog(String(format: L.s(selection.count == 1 ? "delete_one_clip"
                                                                     : "delete_n_clips", lang),
                                   selection.count),
                            isPresented: $confirmDeleteClips, titleVisibility: .visible) {
            Button(L.s("delete", lang), role: .destructive) {
                store.deleteClips(selection, from: session)
                selection.removeAll()
            }
            Button(L.s("cancel", lang), role: .cancel) {}
        }
        .confirmationDialog(L.s("delete_session", lang),
                            isPresented: $confirmDeleteSession, titleVisibility: .visible) {
            Button(L.s("delete", lang), role: .destructive) {
                store.deleteSession(session)
                // The library pushes this screen with a value link and holds
                // no path, so nothing pops it: without this the user was left
                // on a blank screen after confirming.
                dismiss()
            }
        }
        // The one place an ad interrupts: a render just finished and the user
        // was watching the progress bar anyway. Only a completed render — a
        // `.failed` stage is a message, not a result, and gets no ad on top.
        //
        // And only with this screen in front. Trimming a clip, re-pointing the
        // tracker and splitting a rally all re-render a single clip through the
        // same stage, and the interstitial presents from the top-most
        // controller — so an edit made inside the player put a full-screen ad
        // over the sheet the user was working in.
        .confirmationDialog(L.s("clear_clips_title", lang), isPresented: $confirmClearClips,
                            titleVisibility: .visible) {
            Button(L.s("clear_clips", lang), role: .destructive) {
                store.clearClipFiles(session)
                selecting = false
                selection.removeAll()
            }
            Button(L.s("cancel", lang), role: .cancel) {}
        } message: {
            Text(L.s("clear_clips_msg", lang))
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .confirmationDialog(L.s("pro_expired_title", lang), isPresented: $confirmFreeRender,
                            titleVisibility: .visible) {
            Button(L.s("pro_expired_watch", lang)) { destination = .pro(feature: nil) }
            Button(L.s("pro_expired_free", lang)) {
                Task { await store.apply(sessionID: sessionID) }
            }
            Button(L.s("cancel", lang), role: .cancel) {}
        } message: {
            Text(L.s("pro_expired_msg", lang))
        }
        .onChange(of: store.progress[sessionID]) { old, new in
            guard destination == nil, onScreen else { return }
            if case .render? = old, new == nil { ads.showInterstitialIfDue() }
        }
        .sheet(item: $destination) { dest in
            switch dest {
            case .clip(let clip):
                ClipPlayerSheet(clip: clip)
            case .merged(let url):
                HighlightPlayerSheet(url: url, name: L.s("merged", lang),
                                     orientation: session.renderedOrientation)
            case .pro(let feature):
                ProPassView(feature: feature)
            case .caption:
                CaptionEditorView(session: session)
            case .targetPlayer:
                TargetPlayerSheet(session: session)
            case .addRally:
                AddRallySheet(session: session)
            case .reel(let request):
                ReelSheet(request: request)
            }
        }
    }

    /// Two different situations used to share one message. After a detection
    /// that found nothing — a quiet indoor court, or a video that isn't a match
    /// at all — "press Detect and clips will appear" tells the user to do the
    /// thing they just did, and reads as a broken app. Say which case it is and
    /// give the two ways out.
    @ViewBuilder
    private func emptyClips(_ session: Session) -> some View {
        // Detection finding nothing and the user deleting everything look the
        // same on disk; only the first deserves detection advice.
        let detectedNothing = session.segments?.isEmpty == true
            && session.detectionFoundNothing == true
        VStack(spacing: 10) {
            Image(systemName: detectedNothing ? "waveform.badge.exclamationmark" : "film")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(L.s(detectedNothing ? "no_rallies" : "empty_clips", lang))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if detectedNothing {
                Text(L.s("no_rallies_hint", lang))
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    destination = .addRally
                } label: {
                    Label(L.s("add_rally", lang), systemImage: "plus")
                        .font(.subheadline.bold())
                }
                .rcSecondary()
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 8)
    }

    // MARK: - Settings
    // Grid sizes the label column to the widest label, so the controls stay
    // aligned in every language and at every Dynamic Type size.

    /// Icon, value and the edit affordance as one run of text. Laid out as an
    /// HStack the two glyphs hold fixed columns, and what is left at
    /// accessibility sizes is narrower than a single word — a court name came
    /// out broken mid-word. Inline, the value owns the width.
    private func editableRow(icon: String, value: String, dim: Bool) -> some View {
        (Text(Image(systemName: icon))
         + Text("  ")
         + Text(value).foregroundColor(dim ? .secondary : .primary)
         + Text("  ")
         + Text(Image(systemName: "pencil")).font(.caption2).foregroundColor(.secondary))
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func settingsCard(_ session: Session, busy: Bool) -> some View {
        // Sport, crop and export are chosen once per match; after that the card
        // is a wall between the user and the clips. It folds to one summary line
        // once there are clips, and is held open whenever it has something to
        // say: never detected, found nothing, unapplied changes, or a missing
        // original.
        let forced = session.segments?.isEmpty != false || session.hasPendingChanges
            || store.sourceMissing(session)
        let expanded = forced || settingsOpen
        return VStack(spacing: 14) {
            // the place comes from the video's metadata, but reverse geocoding
            // needs a network — so it stays editable by hand
            Button {
                placeDraft = session.placeName ?? ""
                editingPlace = true
            } label: {
                editableRow(icon: "mappin.and.ellipse",
                            value: session.placeName ?? L.s("add_place", lang),
                            dim: session.placeName == nil)
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

            if !forced { settingsHeader(session, expanded: expanded) }
            if expanded { settingsBody(session, busy: busy) }
        }
        .padding(14)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    /// The folded card's stand-in: what the clips are made with, and the way
    /// back in. Only shown when folding is allowed.
    private func settingsHeader(_ session: Session, expanded: Bool) -> some View {
        Button {
            withAnimation(.snappy) { settingsOpen.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.s("settings", lang))
                        .font(.subheadline.weight(.medium))
                    if !expanded {
                        Text(settingsSummary(session))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "🎾 Tennis · Normal · 9:16 · 720p" — enough to tell whether the clips
    /// below were cut the way the user wants without opening anything.
    private func settingsSummary(_ session: Session) -> String {
        let frame = OutputFrame(session.effectiveOrientation)
        let sensitivity: String
        switch session.sensitivity {
        case .low: sensitivity = "strict"
        case .normal: sensitivity = "normal"
        case .high: sensitivity = "loose"
        }
        // What the clips below were made at, not what the next render would
        // use: a summary that turned "4K" the moment a pass ended described
        // clips that are still 4K as 720p, and the other way round.
        let pro = session.renderedOrientation != nil ? (session.renderedPro ?? false) : pass.isPro
        let quality = pro ? (frame.isPortrait ? "quality_1080" : "quality_source")
                          : "quality_720"
        return [session.sport.emoji + " " + L.s(session.sport.rawValue, lang),
                L.s(sensitivity, lang), frame.label, L.s(quality, lang)]
            .joined(separator: " · ")
    }

    @ViewBuilder
    private func settingsBody(_ session: Session, busy: Bool) -> some View {
            section("sec_detect") {
                settingRows([
                    (L.s("sport", lang), AnyView(sportPicker(session))),
                    (L.s("sensitivity", lang), AnyView(sensitivityPicker(session))),
                ])
            }

            Divider()

            section("sec_crop") {
                settingRows([(L.s("aspect", lang), AnyView(aspectPicker(session)))])

                // The crop controls stay visible on a wide session — hiding
                // them made tracking look like it didn't exist — with one line
                // saying when they kick in.
                if OutputFrame(session.effectiveOrientation).isPortrait {
                    cropWidthHint(session)
                } else {
                    Label(L.s("crop_wide_note", lang), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle(isOn: Binding(
                    get: { pass.isPro && session.smartCropEnabled },
                    set: { on in
                        guard pass.isPro else {
                            destination = .pro(feature: L.s("smart_crop", lang))
                            return
                        }
                        store.setSmartCrop(session, on)
                    })) {
                    HStack(spacing: 6) {
                        Text(L.s("smart_crop", lang)).font(.subheadline)
                        if !pass.isPro { ProBadge() }
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

            Divider()

            section("sec_export") {
                // free users still see what the export would look like on Pro
                HStack(spacing: 6) {
                    Text(L.s("export_quality", lang))
                        .font(.subheadline)
                    if !pass.isPro { ProBadge() }
                    Spacer()
                    Button {
                        guard !pass.isPro else { return }
                        destination = .pro(feature: L.s("feat_quality", lang))
                    } label: {
                        // 4K is the wide path only: a portrait export is
                        // capped at a 1080 short side, and 9:16 is the app's
                        // main output — promising 4K there was simply false.
                        Text(pass.isPro
                             ? L.s(OutputFrame(session.effectiveOrientation).isPortrait
                                   ? "quality_1080" : "quality_source", lang)
                                             : L.s("quality_720", lang))
                            .font(.caption.bold())
                            .foregroundStyle(pass.isPro ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button { destination = .caption } label: {
                    let current = session.caption?.isVisible == true
                        ? session.caption!.text : L.s("off", lang)
                    // Label, current text and chevron in one row leave the
                    // label about two characters wide at accessibility sizes:
                    // "Caption" came out as "Ca / pti / on".
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "textformat")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            Text(L.s("edit_caption", lang))
                            Text(current)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "textformat")
                            Text(L.s("edit_caption", lang))
                            Spacer()
                            Text(current)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .rcSecondary()
            }

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
            // The label follows what pressing it will actually do. It used to
            // read "Re-detect" even when the pending change was a caption edit
            // — which only re-renders — and in the common case where nothing
            // had changed it was enabled and did nothing at all.
            let needsDetect = session.segments == nil
                || session.segments?.isEmpty == true || session.needsRedetect
            Button {
                // Renders bake the tier in. Clips made during a pass would
                // silently come back at 720p with a watermark because the user
                // fixed a caption an hour later, so ask first.
                if session.renderedPro == true && !pass.isPro
                    && store.clips(of: session).contains(where: \.isReady) {
                    confirmFreeRender = true
                } else {
                    Task { await store.apply(sessionID: sessionID) }
                }
            } label: {
                Text(needsDetect ? (session.segments == nil ? L.s("detect", lang)
                                                            : L.s("redetect", lang))
                                 : L.s("apply_changes", lang))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .rcPrimary()
            .disabled(!needsDetect && !session.needsRerender)
            .disabled(busy || store.sourceMissing(session))
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

    private func sportPicker(_ session: Session) -> some View {
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

    private func sensitivityPicker(_ session: Session) -> some View {
        Picker("", selection: Binding(
            get: { session.sensitivity },
            set: { v in store.setSensitivity(session, v) })) {
            Text(L.s("strict", lang)).tag(Sensitivity.low)
            Text(L.s("normal", lang)).tag(Sensitivity.normal)
            Text(L.s("loose", lang)).tag(Sensitivity.high)
        }
        .pickerStyle(.segmented)
    }

    private func aspectPicker(_ session: Session) -> some View {
        Picker("", selection: Binding(
            get: { session.aspect },
            set: { v in store.setAspect(session, v) })) {
            Text(L.s("auto", lang)).tag(AspectSetting.auto)
            Text(L.s("wide", lang)).tag(AspectSetting.landscape)
            Text("9:16").tag(AspectSetting.vertical)
            Text("4:5").tag(AspectSetting.portrait45)
        }
        .pickerStyle(.segmented)
        // Four segments, and only two of them are numbers. Italian
        // "Orizzontale" and Portuguese "Horizontal" clipped to "Oriz…" at the
        // DEFAULT text size, not just the accessibility ones.
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    /// Label beside control, until the text gets big enough that the control
    /// has no room left — at AX5 the sport menu was squeezed down to a single
    /// letter. Past the accessibility threshold the label moves above instead.
    @ViewBuilder
    private func settingRows(_ rows: [(String, AnyView)]) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 6) {
                        label(row.0)
                        row.1.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        label(row.0)
                        row.1
                    }
                }
            }
        }
    }

    /// A titled group inside the settings card. Three of them split what used
    /// to be one dense column into what is detected, how it is framed, and how
    /// it leaves the phone.
    private func section<Content: View>(_ key: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.s(key, lang))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            let zoomed = pass.isPro && session.effectiveSmartCrop
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

    /// "Track a player" — opens the picker, or routes free users to the Pro sheet.
    /// Styled like every other action button so it reads as one; the old plain
    /// text row was indistinguishable from the hint under it.
    @ViewBuilder
    private func targetPlayerRow(_ session: Session) -> some View {
        let picked = session.targetPlayer != nil
        HStack(spacing: 8) {
            Button {
                guard pass.isPro else {
                    destination = .pro(feature: L.s("target_player", lang))
                    return
                }
                if OutputFrame(session.effectiveOrientation).isPortrait {
                    destination = .targetPlayer
                } else {
                    confirmSwitchVertical = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: picked
                          ? "person.crop.circle.badge.checkmark"
                          : "person.crop.circle.badge.plus")
                        .foregroundStyle(picked ? Theme.accent : Color.primary)
                    Text(picked ? L.s("target_change", lang) : L.s("target_pick", lang))
                    if !pass.isPro { ProBadge() }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
            .rcSecondary()
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(picked ? 0.9 : 0),
                                            lineWidth: 1.5))

            if picked {
                Button(L.s("target_clear", lang)) {
                    store.setTargetPlayer(session, nil)
                }
                .rcSecondary(destructive: true)
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
            // `render` returns silently when the session is already working,
            // so without this the button looks dead mid-render.
            Button(L.s("rerender", lang)) {
                Task { await store.render(sessionID: sessionID) }
            }
            .rcSecondary()
            .disabled(store.isBusy(sessionID))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func saveAllButton(_ session: Session, busy: Bool) -> some View {
        Button {
            guard pass.isPro else {
                destination = .pro(feature: L.s("save_all", lang))
                return
            }
            Task {
                if let n = await store.saveClipsToPhotos(session) {
                    saveMessage = String(format: L.s(n == 1 ? "saved_one_fmt" : "saved_n_fmt", lang), n)
                } else {
                    saveMessage = L.s("photos_denied", lang)
                }
            }
        } label: {
            Label(L.s("save_all", lang),
                  systemImage: pass.isPro ? "square.and.arrow.down.on.square" : "lock.fill")
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

    /// Saving several at once is the Pro capability — a single clip can always
    /// be shared. Without this gate, Select → Save was a two-tap bypass of the
    /// "one-tap camera roll" the Pro sheet lists.
    private func saveBtn(_ session: Session, _ n: Int) -> some View {
        Button {
            guard pass.isPro || n <= 1 else {
                destination = .pro(feature: L.s("feat_saveall", lang))
                return
            }
            Task {
                if let saved = await store.saveClipsToPhotos(session, ids: selection) {
                    saveMessage = String(format: L.s(saved == 1 ? "saved_one_fmt" : "saved_n_fmt", lang), saved)
                } else {
                    saveMessage = L.s("photos_denied", lang)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Label(L.s("save", lang),
                      systemImage: pass.isPro || n <= 1
                          ? "square.and.arrow.down" : "lock.fill")
                if !pass.isPro && n > 1 { ProBadge() }
            }
            .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 24)
        }
        .rcSecondary()
        .disabled(n == 0)
    }

    /// Joining clips is a Pro capability.
    private func mergeBtn(_ session: Session, _ canMerge: Bool) -> some View {
        Button {
            guard pass.isPro else { destination = .pro(feature: L.s("merge", lang)); return }
            Task { if let url = await store.mergeClips(selection, in: session) {
                    destination = .merged(url)
                } }
        } label: {
            Label(L.s("merge", lang),
                  systemImage: pass.isPro ? "arrow.triangle.merge" : "lock.fill")
                .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 24)
        }
        .rcSecondary()
        .disabled(!canMerge)
    }

    private func deleteBtn(_ session: Session, _ n: Int) -> some View {
        // The same action in All Clips confirms; here the clips just vanished.
        Button(role: .destructive) { confirmDeleteClips = true } label: {
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
        let title = Text(L.s("clips_title", lang)).font(.headline)
        let addRally = Button { destination = .addRally } label: {
            Label(L.s("add_rally", lang), systemImage: "plus")
                .font(.caption.bold())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)

        // One row when it fits. At accessibility sizes, or in a language whose
        // labels run long, sharing the width breaks words mid-way — the sort
        // pill read "Timeli…" — so the row splits instead of truncating.
        let picker = Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    title
                    SortMenu(sort: $sort)
                    addRally
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        title
                        Spacer(minLength: 8)
                        addRally
                        SortMenu(sort: $sort)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { title; Spacer(); SortMenu(sort: $sort) }
                        addRally
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        let reelButton = Button {
            let all = store.clips(of: session).filter(\.isReady).map { (session, $0) }
            guard !all.isEmpty else { return }
            destination = .reel(ReelRequest(pairs: all))
        } label: {
            Label(L.s("reel_make", lang), systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                .font(.subheadline.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .rcPrimary()
        .disabled(busy)

        // Full width, and wrapping rather than clipping to "Make a R…" on a
        // 4.7" screen at accessibility sizes.
        return VStack(spacing: 10) {
            picker
            reelButton
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
        sort == .time ? clips : clips.sorted { sort.precedes($0, $1) }
    }
}

private struct MergedClip: Identifiable {
    let url: URL
    var id: String { url.path }
}
