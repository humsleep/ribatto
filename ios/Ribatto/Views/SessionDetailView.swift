import AVKit
import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var pass: ProPass
    @EnvironmentObject var ads: AdsManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    let sessionID: UUID
    /// A rally to open on arrival — the Season tab's longest-rally record.
    var openNumber: Int? = nil
    @State private var openedRequested = false
    /// The id of the last sheet this screen presented, kept past its
    /// dismissal: onDismiss runs after `destination` is already nil, and
    /// closing the pass sheet — where the user just watched an ad, or chose
    /// not to — must not be answered with another one.
    @State private var lastPresented: String?

    /// Kept across launches: re-picking "Best" on every match was a chore.
    @AppStorage("rc_clip_sort") private var sort: ClipSort = .time
    @State private var destination: Destination?
    @State private var confirmDeleteSession = false
    @State private var confirmDeleteClips = false
    @State private var confirmSwitchVertical = false
    @State private var selecting = false
    @State private var selection: Set<String> = []
    /// A modal opened from inside the settings sheet. It stacks on that sheet
    /// rather than replacing it, so closing the caption editor lands back in
    /// settings instead of dropping the user on the session screen.
    @State private var settingsDestination: Destination?
    /// Apply was pressed in the settings sheet. The run starts once the sheet
    /// is gone: the "pass ended" confirmation cannot present from a screen
    /// that is still covered, and the progress card is what the user should
    /// be looking at.
    @State private var applyAfterSettings = false
    @State private var scrollToTop = 0
    /// What a pass offer interrupted, run once its sheet has closed: at PASS
    /// quality after the reward, on the free tier after "later", not at all
    /// when the sheet was swiped away.
    @State private var offerOutcome: PassOfferOutcome?
    @State private var offerActions: (granted: () -> Void, declined: () -> Void, passive: Bool)?
    @State private var toast: String?
    /// The last delete, with the rallies it took, for five seconds of undo.
    @State private var undo: (text: String, rallies: [RallySegment])?
    /// Clips just added or split, lit for a moment so the eye finds them.
    @State private var highlighted: Set<Int> = []
    @State private var scrollTarget: String?
    /// A re-detect would reset stars and hand edits; asked first.
    @State private var confirmRedetect = false
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
        case settings
        case offer(PassOfferRequest)

        var id: String {
            switch self {
            case .clip(let c): return "clip-" + c.id
            case .merged(let u): return "merged-" + u.lastPathComponent
            case .pro(let f): return "pro-" + (f ?? "")
            case .caption: return "caption"
            case .targetPlayer: return "target-player"
            case .addRally: return "add-rally"
            case .reel(let r): return "reel-" + r.id.uuidString
            case .settings: return "settings"
            case .offer(let r): return "offer-" + r.id.uuidString
            }
        }
    }

    private var session: Session? { store.sessions.first { $0.id == sessionID } }

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
        let all = store.clips(of: session)
        let clips = sorted(all)
        // Best first, for the hero and the reel shortcut — whatever order the
        // grid happens to be in.
        let ranked = all.sorted { ClipSort.best.precedes($0, $1) }
        let busy = store.isBusy(sessionID)

        ScrollView {
            ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 14) {
                // Above the settings: right after an import the card is held
                // open and ran ~700pt tall, so the progress — the only thing
                // happening — was off the bottom of the screen.
                if let stage = store.progress[sessionID] {
                    if case .failed(let message) = stage {
                        failureCard(session, message: message)
                    } else {
                        progressCard(session, stage)
                    }
                }

                // Only when it has something to say — never detected, found
                // nothing, unapplied changes, a missing original — and then
                // inline, because Apply has to be reachable without a hunt.
                // Otherwise the settings live in a sheet: sport, crop and export
                // are chosen once per match, and even folded the card was a
                // wall between the user and the rallies they came to watch.
                if settingsForced(session, busy: busy) {
                    settingsCard(session, busy: busy)
                }
                // Clips missing with nothing changed. Not while a failure card
                // is up: that one already says how many and offers the retry.
                let gap = busy || store.progress[sessionID] != nil ? nil : session.renderGap
                if let gap {
                    gapCard(session, gap: gap, made: all.filter(\.isReady).count)
                }

                if !clips.isEmpty {
                    if pass.isPro && session.renderedPro != true {
                        upgradeBanner()
                    }
                    // Hidden while selecting: a looping video above the grid
                    // fights the checkmarks for attention, and tapping it would
                    // open the player instead of selecting.
                    // While a render runs the best rally may not be a file yet;
                    // its poster stands in until it is.
                    // Dimmed, not removed, while selecting: removing it made
                    // the whole grid jump up under the user's finger.
                    if let best = busy ? preferringSingleRallies(ranked).first
                                       : preferringSingleRallies(ranked.filter(\.isReady)).first {
                        HeroRally(clip: best, session: session,
                                  paused: destination != nil || selecting,
                                  // Never the original: during a render that
                                  // was a second 4K decode alongside the encoder
                                  // — the memory pressure behind -11819 on
                                  // device. A finished clip plays; otherwise
                                  // the poster stays until one exists.
                                  fromOriginal: false) {
                            destination = .clip(best)
                        }
                        .opacity(selecting ? 0.35 : 1)
                        .allowsHitTesting(!selecting)
                        .accessibilityHidden(selecting)
                    }
                    summaryLine(session)
                    reelCTA(session, ranked: ranked, busy: busy)
                    clipHeader(clips)
                    clipGrid(clips)
                } else if gap != nil {
                    // Cleared files take the posters with them, but the rallies
                    // are all still there — say so rather than "no clips yet".
                    summaryLine(session)
                } else if !busy {
                    emptyClips(session)
                }
                // Outside the branch on purpose. Inside it, a session with no
                // clips had no clearance at all — and that is exactly the state
                // where the settings card is force-expanded and "Apply changes"
                // sits at the bottom. The button drew above the translucent tab
                // bar but the tap went to the tab bar, so the one action the
                // screen exists for could not be pressed without scrolling.
                Color.clear.frame(height: 62)
            }
            .padding()
            .id("top")
            .onChange(of: scrollToTop) { _, _ in
                withAnimation { proxy.scrollTo("top", anchor: .top) }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
            }
        }
        // Pinned, not appended: below the grid the bar sat a whole screen away
        // from the clips it acts on.
        // The undo bar lives in the same pinned inset as the selection bar.
        // As an overlay it was laid out against the scroll view and, at some
        // scroll positions, ended up under the floating tab bar — which took
        // the tap, so "Undo" did nothing and the bar simply timed out.
        // Inside the stack (`.adBanner()` comes after) it always sits above
        // the banner and the tab bar.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                undoBar
                if selecting {
                    selectionBar(session, busy: busy)
                }
            }
            .padding(.horizontal)
            // A little more off a loaded banner, or Delete sits on the ad.
            .padding(.bottom, ads.bannerLoaded && ads.showing ? 20 : 8)
        }
        .adBanner()
        .passToast($toast)
        // Selection is by clip id, which is the clip's position: after any
        // change to the rallies the same id is a different rally.
        .onChange(of: session.segments) { _, _ in selection.removeAll() }
        .onChange(of: store.lastEdit) { _, edit in
            guard let edit, edit.sessionID == sessionID else { return }
            handle(edit, session)
        }
        // Alerts, not confirmation dialogs, for every confirm on this screen:
        // iOS 26 floats a dialog as a popover anchored to the whole screen.
        .alert(L.s("redetect_title", lang), isPresented: $confirmRedetect) {
            Button(L.s("redetect", lang), role: .destructive) { runApply(session, confirmed: true) }
            Button(L.s("cancel", lang), role: .cancel) {}
        } message: {
            Text(String(format: L.s("redetect_confirm_fmt", lang),
                        (session.segments ?? []).filter(\.isFavourite).count))
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
                    Button { destination = .settings } label: {
                        Label(L.s("settings", lang), systemImage: "slider.horizontal.3")
                    }
                    if !clips.isEmpty {
                        // A disabled item says why; greyed out alone it read
                        // as broken.
                        Button { destination = .addRally } label: {
                            menuLabel("add_rally", "plus", busy: busy)
                        }
                        .disabled(busy || store.sourceMissing(session) || selecting)
                        Button { saveAll(session) } label: {
                            menuLabel("save_all", pass.isPro ? "square.and.arrow.down.on.square"
                                                             : "lock.fill", busy: busy)
                        }
                        .disabled(busy)
                    }
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
        .modifier(SettingsAlerts(owner: self, session: session, inSheet: false))
        .alert(saveMessage ?? "", isPresented: Binding(
            get: { saveMessage != nil }, set: { if !$0 { saveMessage = nil } })) {
            Button("OK", role: .cancel) { saveMessage = nil }
        }
        .alert(String(format: L.s(selection.count == 1 ? "delete_one_clip"
                                                        : "delete_n_clips", lang),
                      selection.count),
               isPresented: $confirmDeleteClips) {
            Button(L.s("delete", lang), role: .destructive) {
                // Refused while anything runs on the session. Clearing the
                // selection regardless made Delete look like it did nothing.
                if store.deleteClips(selection, from: session) {
                    selection.removeAll()
                    selecting = false
                } else {
                    saveMessage = L.s("busy_wait", lang)
                }
            }
            Button(L.s("cancel", lang), role: .cancel) {}
        } message: {
            // What a delete takes and what it leaves.
            Text(L.s("delete_clips_note", lang))
        }
        .alert(L.s("delete_session", lang), isPresented: $confirmDeleteSession) {
            Button(L.s("delete", lang), role: .destructive) {
                store.deleteSession(session)
                // The library pushes this screen with a value link and holds
                // no path, so nothing pops it: without this the user was left
                // on a blank screen after confirming.
                dismiss()
            }
            Button(L.s("cancel", lang), role: .cancel) {}
        } message: {
            Text(L.s("delete_sessions_note", lang))
        }
        .alert(L.s("clear_clips_title", lang), isPresented: $confirmClearClips) {
            Button(L.s("clear_clips", lang), role: .destructive) {
                store.clearClipFiles(session)
                selecting = false
                selection.removeAll()
            }
            Button(L.s("cancel", lang), role: .cancel) {}
        } message: {
            Text(L.s("clear_clips_msg", lang))
        }
        .onAppear {
            onScreen = true
            guard let openNumber, !openedRequested else { return }
            openedRequested = true
            if let clip = store.clips(of: session).first(where: { $0.number == openNumber }) {
                destination = .clip(clip)
            }
        }
        .onDisappear { onScreen = false }
        // A finished render earns an interstitial, but it is only owed here.
        // Shown on the spot it covered the first look at the clips the user
        // had waited minutes for; it now waits until they have watched one and
        // closed the player (the sheet's onDismiss below). Only a completed
        // render — a `.failed` stage is a message, not a result. A trim or
        // re-target inside the player re-renders through the same stage; that
        // marks it too, and it shows once the player is closed, never over it.
        .onChange(of: store.progress[sessionID]) { old, new in
            // Only a render the user was here for. One finishing on another
            // tab, under a sheet, or in the background is not a result they
            // just saw, and owing an ad for it put one on a later, unrelated
            // dismissal.
            guard destination == nil, onScreen, scenePhase == .active else { return }
            // A render made on a PASS owes nothing, even when the pass ran
            // out while it was running (the tier is baked at the start).
            if case .render? = old, new == nil, self.session?.renderedPro != true {
                ads.markInterstitialDue()
            }
        }
        .onChange(of: destination?.id) { _, new in
            if let new { lastPresented = new }
        }
        .sheet(item: $destination, onDismiss: {
            settingsDestination = nil
            if lastPresented?.hasPrefix("offer-") == true {
                finishOffer()
                return
            }
            guard applyAfterSettings else {
                // The owed ad, if any: a sheet the user opened has closed and
                // this screen is in front. Not when one sheet was swapped for
                // another, and not on a tab the user has moved to.
                // Only after the user watched a result (a clip, a merge, a
                // reel). Closing settings, the caption editor or the pass sheet
                // and getting a full-screen ad is the "unexpected interstitial"
                // AdMob's policy warns about.
                let watched = ["clip-", "merged-", "reel-"].contains {
                    lastPresented?.hasPrefix($0) == true
                }
                // Not over the undo bar: a clip deleted in the player owes
                // its ad to the next result instead.
                if destination == nil, onScreen, watched, undo == nil {
                    ads.showPendingInterstitial()
                }
                return
            }
            applyAfterSettings = false
            scrollToTop += 1
            if let session = self.session { runApply(session) }
        }) { dest in
            destinationView(dest, session)
        }
    }

    @ViewBuilder
    private func destinationView(_ dest: Destination, _ session: Session) -> some View {
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
        case .settings:
            settingsSheet(session)
        case .offer(let request):
            PassOfferSheet(request: request, outcome: $offerOutcome)
        }
    }

    /// Opens the pass offer for `session`'s best rally, remembering what to
    /// do once it closes. Every PASS gate on this screen comes through here.
    /// `passive`: shown unasked, so a swipe-away still runs `declined` — the
    /// user tapped Apply, and that has to happen either way.
    private func offer(_ session: Session, declineKey: String = "offer_later",
                       title: String = "offer_title", message: String? = nil,
                       passive: Bool = false,
                       granted: @escaping () -> Void,
                       declined: @escaping () -> Void = {}) {
        offerOutcome = nil
        offerActions = (granted, declined, passive)
        // "Bigger players" is the 9:16 crop; a landscape match gets quality.
        let landscape = !OutputFrame(session.effectiveOrientation).isPortrait
        let title = title == "offer_title" && landscape ? "offer_title_quality" : title
        let best = preferringSingleRallies(
            store.clips(of: session).sorted { ClipSort.best.precedes($0, $1) }).first
        open(.offer(PassOfferRequest(session: session,
                                     segment: best?.segment.playTrimmed,
                                     poster: best?.thumbURL,
                                     titleKey: title, messageKey: message,
                                     declineKey: declineKey, passive: passive)))
    }

    /// Runs what the offer interrupted. After the sheet is gone, so a gate
    /// that opens another sheet (the player picker) does not collide with it.
    private func finishOffer() {
        guard let actions = offerActions else { return }
        let outcome = offerOutcome
        offerActions = nil
        offerOutcome = nil
        switch outcome {
        case .granted?:
            toast = passOpenedText(pass, lang)
            actions.granted()
        case .declined?: actions.declined()
        case nil: if actions.passive { actions.declined() }
        }
    }

    private var settingsShown: Bool {
        if case .settings? = destination { return true }
        return false
    }

    /// Opens a modal from the settings content, which lives in two places:
    /// inline when forced, and in the settings sheet. From the sheet it has to
    /// stack on top — the screen's own `destination` is the sheet itself.
    private func open(_ d: Destination) {
        if settingsShown { settingsDestination = d } else { destination = d }
    }

    /// The place and "switch to 9:16" alerts, attached both to the screen and
    /// to the settings sheet, each live only where its button is. An alert
    /// asked of a screen that is covered by a sheet simply never appears.
    private struct SettingsAlerts: ViewModifier {
        let owner: SessionDetailView
        let session: Session
        let inSheet: Bool

        func body(content: Content) -> some View {
            let lang = owner.lang
            content
                .alert(L.s("place", lang), isPresented: gated(owner.$editingPlace)) {
                    TextField(L.s("place_placeholder", lang), text: owner.$placeDraft)
                    Button(L.s("apply", lang)) { owner.store.setPlaceName(session, owner.placeDraft) }
                    Button(L.s("cancel", lang), role: .cancel) {}
                }
                // Tracking only does something on a vertical crop. Rather than hide
                // the button on a wide session, say what will change and do it.
                .alert(L.s("target_switch_title", lang),
                       isPresented: gated(owner.$confirmSwitchVertical)) {
                    Button(L.s("target_switch_ok", lang)) {
                        owner.store.setAspect(session, .vertical)
                        owner.open(.targetPlayer)
                    }
                    Button(L.s("cancel", lang), role: .cancel) {}
                } message: {
                    Text(L.s("target_switch_msg", lang))
                }
        }

        private func gated(_ flag: Binding<Bool>) -> Binding<Bool> {
            let here = owner.settingsShown == inSheet
            return Binding(get: { flag.wrappedValue && here },
                           set: { flag.wrappedValue = $0 })
        }
    }

    /// Everything the folded card used to hold, one tap away from the ⋯ menu
    /// or the summary line.
    private func settingsSheet(_ session: Session) -> some View {
        NavigationStack {
            // In a scroll view like every sheet: the form runs well past one
            // screen at accessibility sizes, and Apply is at the bottom.
            ScrollView {
                VStack(spacing: 14) {
                    placeRows(session)
                    settingsBody(session, busy: store.isBusy(sessionID)) {
                        // Close first so the progress card is what the user
                        // sees; the run itself starts in the sheet's onDismiss.
                        applyAfterSettings = true
                        destination = nil
                    }
                }
                .padding()
            }
            .navigationTitle(L.s("settings", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.s("done", lang)) { destination = nil }
                        .font(.subheadline.bold())
                }
            }
            .modifier(SettingsAlerts(owner: self, session: session, inSheet: true))
            .sheet(item: $settingsDestination, onDismiss: finishOffer) { dest in
                // Type-erased: the sheet's content is this function's own
                // caller, and an opaque type cannot contain itself.
                AnyView(destinationView(dest, session))
            }
        }
        .preferredColorScheme(.dark)
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
                .disabled(store.sourceMissing(session))
                .padding(.top, 4)
                // A session that finds nothing is the only signal that the
                // detector did not generalise beyond the one recording its
                // thresholds were fitted to, and it is invisible from App Store
                // Connect — the user just leaves. Shown only when the device
                // can actually open a mail draft.
                if let url = reportURL(session), UIApplication.shared.canOpenURL(url) {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label(L.s("report_none", lang), systemImage: "envelope")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 8)
    }

    /// A mail the user sends themselves when detection found nothing.
    ///
    /// The app sends nothing. This hands the user's own mail client a draft
    /// they read, edit and choose to send, so "your video never leaves the
    /// phone" is untouched: no frames, no audio, no coordinates — only the
    /// settings that produced the empty result, listed in plain text where the
    /// user can see and delete them before sending.
    private func reportURL(_ session: Session) -> URL? {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var sys = utsname()
        uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let facts = ["sport: \(session.sport.rawValue)",
                     "sensitivity: \(session.sensitivity.rawValue)",
                     "source: \(Int(session.duration))s \(session.width)x\(session.height)",
                     "app: \(version) (\(build))",
                     "ios: \(UIDevice.current.systemVersion)",
                     "device: \(model)"]
        let body = L.s("report_body", lang) + "\n\n----\n" + facts.joined(separator: "\n")
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = "humsleep@naver.com"
        c.queryItems = [URLQueryItem(name: "subject",
                                     value: "[Ribatto] " + L.s("report_subject", lang)),
                        URLQueryItem(name: "body", value: body)]
        return c.url
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

    /// The settings card is held open inline whenever it has something to say:
    /// never detected, found nothing, unapplied changes, or a missing original.
    /// Not while working: the form cannot be applied then, and held open it
    /// pushed everything under it off the screen.
    private func settingsForced(_ session: Session, busy: Bool) -> Bool {
        (session.segments?.isEmpty != false
            || (session.hasPendingChanges && session.renderGap == nil)
            || store.sourceMissing(session)) && !busy
    }

    private func settingsCard(_ session: Session, busy: Bool) -> some View {
        VStack(spacing: 14) {
            placeRows(session)
            settingsBody(session, busy: busy) { runApply(session) }
        }
        .padding(14)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func placeRows(_ session: Session) -> some View {
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
    }

    @ViewBuilder
    private func settingsBody(_ session: Session, busy: Bool,
                              onApply: @escaping () -> Void) -> some View {
            section("sec_detect") {
                settingRows([
                    (L.s("sport", lang), AnyView(sportPicker(session))),
                    (L.s("sensitivity", lang), AnyView(sensitivityPicker(session))),
                ])
            }

            Divider()

            section("sec_crop") {
                settingRows([(L.s("aspect", lang), AnyView(aspectPicker(session)))])
                // The bands above and below a wide frame in a free vertical clip.
                if OutputFrame(session.effectiveOrientation).isPortrait {
                    settingRows([(L.s("backdrop_title", lang), AnyView(backdropPicker(session)))])
                }

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
                            // Granted: the switch the user flipped goes on.
                            offer(session, title: "offer_title_crop") {
                                store.setSmartCrop(session, true)
                            }
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
                settingRows([
                    (L.s("filter_title", lang), AnyView(filterPicker(session))),
                    (L.s("sound_title", lang), AnyView(soundPicker(session))),
                ])
                // free users still see what the export would look like on Pro
                HStack(spacing: 6) {
                    Text(L.s("export_quality", lang))
                        .font(.subheadline)
                    if !pass.isPro { ProBadge() }
                    Spacer()
                    Button {
                        guard !pass.isPro else { return }
                        // Nothing to run: the next render picks the quality up.
                        offer(session, title: "offer_title_quality") {}
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

                Button { open(.caption) } label: {
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

            if session.hasPendingChanges && session.renderGap == nil {
                Label(L.s("apply_hint", lang), systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if store.sourceMissing(session) {
                let problem = store.sourceProblemKey(session)
                Label(L.s(problem, lang), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if problem != "source_missing",
                   let url = URL(string: UIApplication.openSettingsURLString) {
                    Button(L.s("photos_open_settings", lang)) { UIApplication.shared.open(url) }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                onApply()
            } label: {
                Text(needsDetect ? (session.segments == nil ? L.s("detect", lang)
                                                            : L.s("redetect", lang))
                                 : L.s("apply_changes", lang))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .rcPrimary()
            .disabled(!needsDetect && !session.needsRerender)
            .disabled(busy || store.sourceMissing(session) || selecting)
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

    /// One field of the session's look and sound, written back whole.
    private func editBinding<T>(_ session: Session,
                                _ key: WritableKeyPath<ClipEdit, T>) -> Binding<T> {
        Binding(get: { session.effectiveEdit[keyPath: key] },
                set: { v in
                    var edit = session.effectiveEdit
                    edit[keyPath: key] = v
                    store.setEdit(session, edit)
                })
    }

    private func filterPicker(_ session: Session) -> some View {
        Picker(L.s("filter_title", lang), selection: editBinding(session, \.filter)) {
            ForEach(ClipFilter.allCases) { f in
                Text(L.s("filter_" + f.rawValue, lang)).tag(f)
            }
        }
        .pickerStyle(.menu)
        .tint(Theme.accent)
    }

    private func soundPicker(_ session: Session) -> some View {
        Picker("", selection: editBinding(session, \.volume)) {
            Text(L.s("sound_full", lang)).tag(1.0)
            Text(L.s("sound_low", lang)).tag(0.4)
            Text(L.s("sound_off", lang)).tag(0.0)
        }
        .pickerStyle(.segmented)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private func backdropPicker(_ session: Session) -> some View {
        Picker("", selection: editBinding(session, \.backdrop)) {
            Text(L.s("backdrop_blur", lang)).tag(Backdrop.blur)
            Text(L.s("backdrop_black", lang)).tag(Backdrop.black)
        }
        .pickerStyle(.segmented)
        .dynamicTypeSize(...DynamicTypeSize.large)
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
            // Without smart crop nothing is cut away any more — the whole
            // frame goes across the middle over a blur (ClipExporter) — so
            // "keeps 32% of the width" would describe a crop that no longer
            // happens.
            if !(pass.isPro && session.effectiveSmartCrop) {
                Label(L.s("crop_blurfill", lang), systemImage: "rectangle.inset.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
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
                    // Granted: on to the picker they were reaching for.
                    offer(session, title: "offer_title_target") {
                        if OutputFrame(session.effectiveOrientation).isPortrait {
                            open(.targetPlayer)
                        } else {
                            confirmSwitchVertical = true
                        }
                    }
                    return
                }
                if OutputFrame(session.effectiveOrientation).isPortrait {
                    open(.targetPlayer)
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

    /// Renders bake the tier in. Clips made during a pass would silently come
    /// back at 720p with a watermark because the user fixed a caption an hour
    /// later, so ask first.
    private func runApply(_ session: Session, confirmed: Bool = false) {
        // A re-detect replaces the rallies wholesale: stars (beyond the ones
        // that carry over), trims, hand-added rallies, splits and deletes all
        // go with them. Said before, not discovered after.
        if !confirmed, session.needsRedetect, hasEdits(session) {
            confirmRedetect = true
            return
        }
        let apply: () -> Void = { Task { await store.apply(sessionID: sessionID) } }
        let hasClips = store.clips(of: session).contains(where: \.isReady)
        if session.renderedPro == true && !pass.isPro && hasClips {
            // Straight to the offer, with the downgrade said in it.
            offer(session, declineKey: "offer_later_free", title: "pro_expired_title",
                  message: "pro_expired_msg", granted: apply, declined: apply)
        } else if PassOfferGate.allowsPassive(pass: pass, ads: ads), hasClips,
                  !store.isBusy(session.id), !session.needsRedetect,
                  session.renderGap == nil {
            // A free re-render is the moment a pass changes the result.
            PassOfferGate.recordShown()
            offer(session, declineKey: "offer_later_free", passive: true,
                  granted: apply, declined: apply)
        } else {
            apply()
        }
    }

    private func progressCard(_ session: Session, _ stage: ProcessingStage) -> some View {
        // Read, not observed: the feed entry is created before the first
        // stage is set, so it is in place whenever this body runs for one.
        let live = store.analysis.items[sessionID] != nil
        return VStack(alignment: .leading, spacing: 8) {
            StageLabel(stage: stage)
            AnalysisProgress(feed: store.analysis, sessionID: sessionID, stage: stage,
                             poster: store.posterURL(session),
                             liveSegments: session.segments) { i in
                // A marker opens its rally — still being made is fine, the
                // player previews it from the original. The strip only
                // offers taps on the session's committed rallies.
                guard let clip = store.clips(of: session).first(where: { $0.index == i })
                else { return }
                destination = .clip(clip)
            }
            if case .render(let d, let t) = stage, t > 0 {
                ProgressView(value: Double(d), total: Double(t))
                RenderEta(done: d, total: t)
            } else if !live {
                ProgressView().progressViewStyle(.linear)
            }
            // Leaving the app is what stops a long render, so this is body
            // text, not a footnote.
            Label(L.s(store.rendersInBackground ? "keep_awake_bg" : "keep_awake", lang),
                  systemImage: "iphone.gen3.radiowaves.left.and.right")
                // Caption, not footnote: on one line where it fits, so the
                // card stays small while the clips are made.
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            // While detecting the tier is still open; from render on it is baked.
            if !pass.isPro, ads.showing, stage.tierOpen {
                PassLine { open(.pro(feature: nil)) }
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    /// Clips missing although nothing changed: a first render the app was
    /// killed in the middle of, or files the user freed up. The settings form
    /// has nothing to say here, so it stays shut; this says what happened and
    /// runs the same Apply.
    private func gapCard(_ session: Session, gap: Session.RenderGap, made: Int) -> some View {
        let missing = max((session.segments?.count ?? 0) - made, 0)
        let text = gap == .cleared ? L.s("gap_cleared", lang)
                                   : String(format: L.s("gap_unfinished_fmt", lang), missing)
        return VStack(alignment: .leading, spacing: 12) {
            Label(text, systemImage: gap == .cleared ? "externaldrive.badge.minus"
                                                     : "clock.badge.exclamationmark")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { runApply(session) } label: {
                Label(L.s(gap == .cleared ? "gap_remake" : "gap_continue", lang),
                      systemImage: "arrow.clockwise")
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .rcPrimary()
            .disabled(store.sourceMissing(session))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    /// A failure with the way out next to it. It used to be a grey caption in
    /// the progress card's style, and the only retry was the Apply button
    /// further down.
    private func failureCard(_ session: Session, message: String) -> some View {
        // Trying again cannot bring back a deleted original or add sound.
        // …and Apply only acts on pending work. A failed trim or re-target
        // leaves nothing pending, and the button did nothing at all.
        let pending = session.hasPendingChanges || session.segments == nil
            || session.segments?.isEmpty == true
        let canRetry = pending && !store.sourceMissing(session)
            && message != L.s("no_audio", lang)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { store.dismissFailure(sessionID) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.s("close", lang))
            }
            if canRetry {
                Button { runApply(session) } label: {
                    Label(L.s("try_again", lang), systemImage: "arrow.clockwise")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .rcPrimary()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Pro

    private func upgradeBanner() -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title3).foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            VStack(alignment: .leading, spacing: 2) {
                Text(L.s("pro_rerender_t", lang)).font(.subheadline.bold())
                Text(L.s("pro_rerender_d", lang))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            // `render` returns silently when the session is already working,
            // so without this the button looks dead mid-render.
            Button {
                Task { await store.render(sessionID: sessionID) }
            } label: {
                Text(L.s("rerender", lang))
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
            }
            .rcSecondary()
            .disabled(store.isBusy(sessionID))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
    }

    /// Every clip to Photos — Pro. Lives in the ⋯ menu; a full-width button
    /// under the grid repeated what Select → Save already does.
    private func saveAll(_ session: Session) {
        guard pass.isPro else {
            offer(session) { saveAll(session) }
            return
        }
        Task {
            if let n = await store.saveClipsToPhotos(session) {
                saveMessage = String(format: L.s(n == 1 ? "saved_one_fmt" : "saved_n_fmt", lang), n)
            } else {
                saveMessage = L.s("photos_denied", lang)
            }
        }
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
                offer(session) { saveSelection(session) }
                return
            }
            saveSelection(session)
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

    private func saveSelection(_ session: Session) {
        Task {
            if let saved = await store.saveClipsToPhotos(session, ids: selection) {
                saveMessage = String(format: L.s(saved == 1 ? "saved_one_fmt" : "saved_n_fmt", lang), saved)
            } else {
                saveMessage = L.s("photos_denied", lang)
            }
        }
    }

    private func mergeSelection(_ session: Session) {
        Task {
            if let url = await store.mergeClips(selection, in: session) {
                destination = .merged(url)
            } else if store.progress[sessionID] == nil {
                // A refusal (busy, fewer than two finished clips) said
                // nothing; a failure shows its own card.
                saveMessage = L.s(store.isBusy(sessionID) ? "busy_wait" : "merge_failed", lang)
            }
        }
    }

    /// Joining clips is a Pro capability.
    private func mergeBtn(_ session: Session, _ canMerge: Bool) -> some View {
        Button {
            guard pass.isPro else { offer(session) { mergeSelection(session) }; return }
            mergeSelection(session)
        } label: {
            Label(L.s("merge", lang),
                  systemImage: pass.isPro ? "arrow.triangle.merge" : "lock.fill")
                .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 24)
        }
        .rcSecondary()
        .disabled(!canMerge)
    }

    private func deleteBtn(_ session: Session, _ n: Int) -> some View {
        Button(role: .destructive) { confirmDeleteClips = true } label: {
            Label(L.s("delete", lang), systemImage: "trash")
                .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 24)
        }
        .rcSecondary(destructive: true)
        .disabled(n == 0)
    }

    // MARK: - Overview

    /// "5 rallies · 1:34 · Longest 0:42 · Riverside" — what this match came to,
    /// and the way into its settings, where the place is also edited.
    private func summaryLine(_ session: Session) -> some View {
        // From the rallies, not the clip files: after "free up" there are no
        // files and the match still has every rally.
        let lengths = (session.segments ?? []).map { $0.end - $0.start }
        let total = lengths.reduce(0, +)
        // "Longest" from single rallies: a joined 1:55 block is not the
        // longest point, and quoting it made the summary look broken.
        let single = (session.segments ?? []).filter { !$0.looksMerged }.map(\.duration)
        let longest = (single.isEmpty ? lengths : single).max() ?? 0
        var parts = [String(format: L.s(lengths.count == 1 ? "rallies_one" : "rallies_n", lang),
                            lengths.count),
                     fmtDur(total),
                     L.s("longest", lang) + " " + fmtDur(longest)]
        if let place = session.placeName, !place.isEmpty { parts.append(place) }
        return Button { destination = .settings } label: {
            // The chevron flows in the text, as in `editableRow`: as its own
            // column it left the line a word wide at accessibility sizes.
            (Text(parts.joined(separator: " · "))
             + Text("  ")
             + Text(Image(systemName: "chevron.right")).font(.caption2))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(L.s("settings", lang))
    }

    /// The one-tap reel: about thirty seconds of the match's best, built the
    /// moment the sheet opens. Chosen by length, not count — five long rallies
    /// ran past a minute, which is not a highlight. Best rallies are taken in
    /// order until the next would overrun (always at least one); the best one
    /// leads, since the first seconds decide whether anyone keeps watching,
    /// and the rest follow in the order they were played.
    /// Room kept for the slow winning-shot replay the reel ends on, so the
    /// whole thing still lands near thirty seconds. Reserved even when the
    /// footage turns out too slow for one; the reel is then a little shorter.
    private static let reelBudget: Double = 30 - ReelBuilder.replaySeconds

    /// The longest piece of one rally the highlight takes when it is the only
    /// one, and when there are others to fit beside it. At 25 s for every
    /// rally, a long best point left 5 s and every other rally (9–11 s once
    /// cut to its strikes) was turned away: a "highlight" of one rally.
    private static let reelTailMax: Double = 25
    private static let reelTailShared: Double = 15
    /// Below this, a cut-down rally is a fragment, not a point.
    private static let reelTailMin: Double = 8

    private func reelPicks(_ ready: [ClipInfo]) -> [ClipInfo] {
        var picked: [ClipInfo] = []
        var total = 0.0
        // Measured on the strikes, not the padded clip: the dead time before
        // the serve and after the point is cut from a reel anyway, and
        // counting it left room for one rally where two fit.
        let cap = ready.count > 1 ? Self.reelTailShared : Self.reelTailMax
        for whole in ready.map(\.forReel) {
            // Its last `cap` seconds, starting just before a strike.
            let clip = whole.segment.duration > cap ? Self.tail(of: whole, seconds: cap) : whole
            let left = Self.reelBudget - total
            // Measured at the pace the reel is built at — the hook adds its
            // teaser to every rally.
            if ReelPace.hook.estimatedLength(of: clip.segment) <= left {
                picked.append(clip)
                total += ReelPace.hook.estimatedLength(of: clip.segment)
                continue
            }
            // Too long for what is left. A 42-second best rally alone made a
            // 43-second "30-second" reel, so it is cut to its end — where the
            // winning shot is — rather than taken whole or skipped.
            let room = min(cap, left - ReelPace.hookLead - 0.5)
            // Too little room for this one; a shorter rally further down the
            // ranking may still fit whole.
            guard room >= Self.reelTailMin else { continue }
            let cut = Self.tail(of: clip, seconds: room)
            picked.append(cut)
            total += ReelPace.hook.estimatedLength(of: cut.segment)
        }
        guard let best = picked.first else { return [] }
        return [best] + picked.dropFirst().sorted { $0.index < $1.index }
    }

    /// The last `seconds` of a rally, started just before a strike when the
    /// detector kept them — a cut mid-swing opens on a player already
    /// running, with no idea where the ball is. Only the request is cut; the
    /// session's rally stays whole.
    private static func tail(of clip: ClipInfo, seconds: Double) -> ClipInfo {
        var seg = clip.segment
        guard seg.duration > seconds else { return clip }
        var start = seg.end - seconds
        if let hit = seg.hitTimes?.sorted().first(where: { $0 >= start && $0 < seg.end - 2 }) {
            start = max(start, hit - 0.4)
        }
        seg.start = start
        return clip.with(segment: seg)
    }

    private func reelCTA(_ session: Session, ranked: [ClipInfo], busy: Bool) -> some View {
        let ready = ranked.filter(\.isReady)
        return Group {
            if busy {
                // Not a dimmed button: at 30% the label could not be read, and the
                // only thing worth saying while busy is how far along the clips are.
                // No count: the progress card right above already says
                // "Making clips 2/6", and two counters read as two jobs.
                Label(L.s("reel_wait", lang), systemImage: "hourglass")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 16)
                    .background(Theme.surface, in: Capsule())
                    .accessibilityElement(children: .combine)
            } else {
                Button {
                    let picked = reelPicks(preferringSingleRallies(ready))
                    guard !picked.isEmpty else { return }
                    // The rest of the match comes along switched off, so Edit
                    // can add a rally the automatic pick left out.
                    let taken = Set(picked.map(\.id))
                    let rest = ready.filter { !taken.contains($0.id) }
                        .sorted { $0.index < $1.index }
                    destination = .reel(ReelRequest(pairs: picked.map { (session, $0) },
                                                    pace: .hook, keepOrder: true,
                                                    extras: rest.map { (session, $0) }))
                } label: {
                    // Full width, and wrapping rather than clipping to "Make a R…" on a
                    // 4.7" screen at accessibility sizes.
                    Label(L.s("reel_30s", lang),
                          systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                        .font(.subheadline.bold())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .rcPrimary()
                .disabled(ready.isEmpty)
            }
        }
    }

    private func clipHeader(_ clips: [ClipInfo]) -> some View {
        // Title only: the count and total are on the summary line just above,
        // and saying them twice made the two read as different numbers.
        let title = Text(L.s("clips_title", lang)).font(.headline)

        // One row when it fits. At accessibility sizes, or in a language whose
        // labels run long, sharing the width breaks words mid-way — the sort
        // pill read "Timeli…" — so the row splits instead of truncating.
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    title
                    SortMenu(sort: $sort)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        title
                        Spacer(minLength: 8)
                        SortMenu(sort: $sort)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        title
                        SortMenu(sort: $sort)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Clips

    private func clipGrid(_ clips: [ClipInfo]) -> some View {
        let frame = OutputFrame(clips.first?.orientation)
        let columns = [GridItem(.adaptive(minimum: frame.isPortrait ? 108 : 165),
                                spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(clips) { clip in
                ClipCard(clip: clip,
                         selected: selecting ? selection.contains(clip.id) : nil,
                         highlighted: highlighted.contains(clip.number)) {
                    if selecting {
                        // Unfinished clips preview, but there is no file to
                        // save, merge or put in a reel — say so rather than
                        // ignore the tap.
                        guard clip.isReady else {
                            saveMessage = L.s("clip_not_ready", lang)
                            return
                        }
                        if selection.contains(clip.id) { selection.remove(clip.id) }
                        else { selection.insert(clip.id) }
                    } else {
                        // Unfinished clips too: the player previews them
                        // from the original.
                        destination = .clip(clip)
                    }
                }
            }
        }
    }

    /// Anything a re-detect would throw away: stars, trims (hand-added and
    /// split rallies are marked trimmed), deleted rallies (gaps in the
    /// numbers), per-clip players.
    private func hasEdits(_ session: Session) -> Bool {
        let segs = session.segments ?? []
        return segs.contains { $0.isFavourite || $0.trimmed == true || $0.speed != nil }
            || (segs.compactMap(\.number).max() ?? 0) > segs.count
            || !(session.clipTargets ?? [:]).isEmpty
    }

    /// Answers a change to the rallies: an undo for a delete; for a split or
    /// an added rally, back to this screen with the new clips in view and lit.
    private func handle(_ edit: RallyEdit, _ session: Session) {
        switch edit.kind {
        case .deleted(let rallies):
            // Undo re-cuts from the original; without it there is nothing to undo.
            let text = rallies.count == 1 ? L.s("deleted_one", lang)
                : String(format: L.s("deleted_n_fmt", lang), rallies.count)
            undo = store.sourceMissing(session) ? nil : (text, rallies)
        case .split(let a, let b):
            destination = nil
            toast = String(format: L.s("split_done_fmt", lang), a, a, b)
            light([a, b], session)
        case .added(let n, let start):
            destination = nil
            toast = String(format: L.s("rally_added_fmt", lang), fmtPos(start))
            light([n], session)
        }
    }

    private func light(_ numbers: Set<Int>, _ session: Session) {
        highlighted = numbers
        if let first = store.clips(of: session).first(where: { numbers.contains($0.number) }) {
            // After the sheets have gone, or the scroll is lost under them.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                scrollTarget = first.id
                try? await Task.sleep(for: .seconds(2))
                withAnimation { highlighted = [] }
            }
        }
    }

    /// "2 clips deleted · Undo", for eight seconds above the tab bar.
    @ViewBuilder private var undoBar: some View {
        if let undo {
            HStack(spacing: 12) {
                Text(undo.text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    let rallies = undo.rallies
                    self.undo = nil
                    Task {
                        if !(await store.restoreRallies(rallies, in: sessionID)) {
                            saveMessage = L.s("undo_failed", lang)
                        }
                    }
                } label: {
                    Text(L.s("undo", lang))
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 2)
            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // Keyed on the rallies, so a second delete restarts the clock.
            .task(id: undo.rallies.map(\.start)) {
                try? await Task.sleep(for: .seconds(8))
                withAnimation { self.undo = nil }
            }
        }
    }

    /// A menu item that, when greyed out because the match is busy, says so.
    private func menuLabel(_ key: String, _ icon: String, busy: Bool) -> some View {
        Label {
            Text(L.s(key, lang))
            if busy { Text(L.s("busy_short", lang)) }
        } icon: {
            Image(systemName: icon)
        }
    }

    private func sorted(_ clips: [ClipInfo]) -> [ClipInfo] {
        sort == .time ? clips : clips.sorted { sort.precedes($0, $1) }
    }
}

// MARK: - Hero

/// The match's best rally, playing, at the top of the screen — the user came
/// to watch, and a grid of posters under a form made them work for it.
///
/// Muted and looping. The player exists only while someone can see it: on
/// screen, scrolled into view, nothing covering it, Reduce Motion off. Any of
/// those turning false tears it down — a paused player still holds its
/// decoder and, for an original, its download. While a render runs and the
/// clip has no file yet, it plays the rally straight from the original.
private struct HeroRally: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let clip: ClipInfo
    let session: Session
    /// A sheet is up over the screen, so nobody is watching — and the player
    /// sheet the hero opens would otherwise decode the same rally twice.
    let paused: Bool
    /// Whether an unfinished clip may play from the original.
    let fromOriginal: Bool
    let onTap: () -> Void

    @State private var player: AVPlayer?
    @State private var loop: NSObjectProtocol?
    @State private var visible = true

    private var frame: OutputFrame { OutputFrame(clip.orientation) }

    /// Whatever changes the pixels or whether anyone can see them. The file's
    /// date is in it because a staged re-render — a caption, the crop, the
    /// tier — replaces the file at the same URL with the same rally bounds,
    /// and the hero kept looping the old one.
    private var key: String {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: clip.url.path))?[.modificationDate]
            as? Date
        let live = !paused && visible && !reduceMotion
        return [clip.id, clip.orientation, String(clip.isReady), String(fromOriginal),
                String(clip.segment.start), String(clip.segment.end),
                String(stamp?.timeIntervalSince1970 ?? 0), String(live)].joined(separator: "|")
    }

    private var stats: String {
        fmtLen(clip.duration, lang) + " · "
            + String(clip.segment.hits) + " " + L.s("shots_n", lang)
            // Only when every candidate the hero could show is long — every
            // rally, or every finished one mid-render — and then it says so.
            + (clip.segment.looksMerged ? " · " + L.s("long_block", lang) : "")
    }

    /// At accessibility sizes the type is what needs the room: a full-size
    /// hero pushed the reel button and the first row of clips off the first
    /// screen.
    private var maxVideoHeight: CGFloat {
        if typeSize.isAccessibilitySize { return frame.isPortrait ? 160 : 200 }
        return frame.isPortrait ? 240 : .infinity
    }

    var body: some View {
        Button(action: onTap) {
            Group {
                if frame.isPortrait {
                    // A 9:16 rally at full width is taller than the phone.
                    // Capped, it leaves the width beside it, which is where
                    // the caption goes instead of over a 135pt-wide picture —
                    // until the caption is too big to fit beside it.
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                        : AnyLayout(HStackLayout(spacing: 14))
                    layout {
                        video.frame(height: maxVideoHeight)
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L.s("best_rally", lang), systemImage: "star.fill")
                                .font(.subheadline.bold())
                            Text(stats)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    video
                        .frame(maxHeight: maxVideoHeight)
                        .overlay(alignment: .bottomLeading) {
                            Text("★ " + L.s("best_rally", lang) + " · " + stats)
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                // It sits on the picture; unbounded it would
                                // cover the rally it describes.
                                .dynamicTypeSize(...DynamicTypeSize.large)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.65),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.s("best_rally", lang) + ", " + stats)
        .accessibilityHint(L.s("hero_hint", lang))
        .modifier(OnScreenTracker(visible: $visible))
        .task(id: key) { await start() }
        .onDisappear { teardown() }
        .onChange(of: scenePhase) { _, _ in sync() }
    }

    private var video: some View {
        Color.clear
            .aspectRatio(frame.aspectRatio, contentMode: .fit)
            .overlay { PosterImage(url: clip.thumbURL) }
            .overlay {
                if let player {
                    // Fill, not fit: before the clip exists this is the wide
                    // original in a 9:16 card, and filling shows the middle —
                    // close to the crop the clip will have.
                    PlayerLayerView(player: player, gravity: .resizeAspectFill)
                        // A UIKit view takes the touch for itself, and the
                        // card's tap never reached the button.
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // Reduce Motion: nothing moves until asked. The poster and a
                // play glyph say what a tap does.
                if reduceMotion {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white.opacity(0.9))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func start() async {
        teardown()
        guard !paused, visible, !reduceMotion else { return }
        let item: AVPlayerItem?
        if clip.isReady {
            item = await RallyPreview.item(from: AVURLAsset(url: clip.url), start: 0,
                                           end: .infinity, audio: false)
        } else if fromOriginal, let asset = await store.loadAsset(session) {
            guard !Task.isCancelled else { return }
            item = await RallyPreview.item(from: asset, start: clip.segment.start,
                                           end: clip.segment.end, audio: false)
        } else {
            item = nil      // nothing to play: the poster stays
        }
        guard let item, !Task.isCancelled else { return }
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        // A silent loop on a list screen has no business on the TV.
        p.allowsExternalPlayback = false
        // Keeps the rate at the end so the loop is just a seek; with the
        // default the player paused itself and needed telling to play again.
        p.actionAtItemEnd = .none
        loop = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
            queue: .main) { [weak p] _ in
            p?.seek(to: .zero)
        }
        player = p
        sync()
    }

    /// Only the app going inactive is a pause rather than a teardown: coming
    /// back from the app switcher should not reload the video.
    private func sync() {
        guard let player else { return }
        if scenePhase == .active { player.play() } else { player.pause() }
    }

    private func teardown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if let loop { NotificationCenter.default.removeObserver(loop) }
        loop = nil
        player = nil
    }
}

/// Whether a view is in the visible part of its scroll view. The scroll API
/// for this arrived in iOS 18; the app supports 17, which measures instead.
private struct OnScreenTracker: ViewModifier {
    @Binding var visible: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.2) { visible = $0 }
        } else {
            content.background {
                GeometryReader { g in
                    let f = g.frame(in: .global)
                    let screen = g.size.height > 0 ? UIScreen.main.bounds.height : 0
                    Color.clear.onChange(of: f.maxY > 40 && f.minY < screen - 40,
                                         initial: true) { _, v in visible = v }
                }
            }
        }
    }
}

private struct MergedClip: Identifiable {
    let url: URL
    var id: String { url.path }
}
