import AVKit
import PhotosUI
import Pow
import SwiftUI
import UniformTypeIdentifiers

struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) {
            SentTransferredFile($0.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var pass: ProPass
    @EnvironmentObject var ads: AdsManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    /// Where the import goes once the sport has been asked.
    @State private var pendingSource: ImportSource?
    @State private var askSport = false
    @State private var rescueMessage: String?
    @State private var confirmDiscard = false
    @State private var importing = false
    @State private var showPro = false
    @State private var recording = false
    @State private var cameraAlert = false
    @State private var importError: String?
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmDelete = false
    @State private var search = ""
    @State private var sportFilter: Sport?
    @State private var placeFilter: String?
    @State private var showDebug = false
    /// Lets a single import land straight on its session screen.
    @State private var path = NavigationPath()
    /// Sessions some finished reel was built from, for the card's "Reels ✓".
    @State private var reelSessions: Set<UUID> = []

    enum ImportSource { case photos, files, record }

    /// Text match on the sport and the date shown on the card, plus the
    /// sport chip — enough to find "that badminton match last week".
    private var visibleSessions: [Session] {
        // Below the threshold the search and chips are hidden, so a filter
        // left over from when they were showing must not hide sessions.
        guard searchable else { return store.sessions }
        return store.sessions.filter { s in
            if let sportFilter, s.sport != sportFilter { return false }
            if let placeFilter, s.placeName != placeFilter { return false }
            guard !search.isEmpty else { return true }
            let haystack = [L.s(s.sport.rawValue, lang),
                            L.dateTime(s.playedAt, lang),
                            s.placeName ?? "",
                            s.name].joined(separator: " ").lowercased()
            return haystack.contains(search.lowercased())
        }
    }

    /// Search and the sport chips earn their space only once there is
    /// something to search: with a handful of matches they were two rows of
    /// controls above three cards.
    private var searchable: Bool { store.sessions.count >= 8 }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
            // Two header controls. Select and delete live on a long press on a
            // card (deleting several is rare), the camera in the + menu beside
            // the other ways in, and the globe's contents in Settings.
            TabHeader(title: L.s("my_sessions", lang)) {
                if selecting {
                    // The way back out of a mode entered by long press.
                    Button(L.s("done", lang)) {
                        selecting = false
                        selection.removeAll()
                    }
                    .font(.subheadline.bold())
                } else {
                    // A toolbar collapses a Label to its icon; in the content
                    // it would spell out "Import video" and push the title out.
                    importButton
                        .labelStyle(.iconOnly)
                        .font(.title3)
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .font(.title3)
                    .accessibilityLabel(L.s("settings", lang))
                }
            }
            // The pass is the only way to Pro, so it keeps its own line.
            HStack(spacing: 10) {
                entitlementPill
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            Group {
                if store.sessions.isEmpty && !importing {
                    EmptyStateBox { emptyState }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if searchable {
                                SearchField(prompt: L.s("search_sessions", lang), text: $search)
                            }
                            if importing { ProgressView().padding() }
                            recoveredCard
                            // Once for all imports, not per card: the user waits here.
                            if !pass.isPro, ads.showing, store.sessions.contains(where: {
                                store.progress[$0.id]?.tierOpen == true }) {
                                PassLine { showPro = true }
                            }
                            if searchable { sportFilterBar }
                            if visibleSessions.isEmpty {
                                Text(L.s("no_match", lang))
                                    .font(.subheadline).foregroundStyle(Theme.secondaryText)
                                    .padding(.vertical, 40)
                            }
                            ForEach(visibleSessions) { session in
                                if selecting {
                                    Button {
                                        if selection.contains(session.id) {
                                            selection.remove(session.id)
                                        } else {
                                            selection.insert(session.id)
                                        }
                                    } label: {
                                        SessionCard(session: session,
                                                    selected: selection.contains(session.id))
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink(value: session.id) {
                                        SessionCard(session: session,
                                                    hasReel: reelSessions.contains(session.id))
                                    }
                                    .buttonStyle(.plain)
                                    // Selecting is for deleting several matches
                                    // at once — rare enough to sit behind a long
                                    // press, which starts with this card picked.
                                    // Deleting just this one is right there too.
                                    .contextMenu {
                                        Button { select(session) } label: {
                                            Label(L.s("select", lang),
                                                  systemImage: "checkmark.circle")
                                        }
                                        Button(role: .destructive) { askDelete(session) } label: {
                                            Label(L.s("delete", lang), systemImage: "trash")
                                        }
                                    }
                                    .accessibilityAction(named: Text(L.s("select", lang))) {
                                        select(session)
                                    }
                                    .accessibilityAction(named: Text(L.s("delete", lang))) {
                                        askDelete(session)
                                    }
                                }
                            }
                            Color.clear.frame(height: 62)
                        }
                        .padding()
                    }
                    // Pinned like the session screen's: at the end of the list
                    // it was a long scroll away from the cards it acts on.
                    .safeAreaInset(edge: .bottom) {
                        if selecting {
                            deleteBar
                                .padding(.horizontal)
                                .padding(.bottom, ads.bannerLoaded && ads.showing ? 20 : 8)
                        }
                    }
                }
            }
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .adBanner()
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionID: id)
            }
            // Again on every return: a reel made or deleted elsewhere changes the ticks.
            .onAppear {
                reelSessions = Set(store.reels().flatMap { $0.sources ?? [] }.map(\.sessionID))
            }
            .sheet(isPresented: $showPro) { ProPassView() }
#if DEBUG
            .sheet(isPresented: $showDebug) { DebugProSheet() }
#endif
            .sheet(isPresented: $showSettings) { AppSettingsView() }
            // Hidden controls must not keep filtering: deleting down to seven
            // matches left a search no one could see or clear.
            // A match filtered out of view is not one the user can see they
            // are about to delete.
            .onChange(of: visibleSessions.map(\.id)) { _, visible in
                selection.formIntersection(visible)
            }
            .onChange(of: searchable) { _, shown in
                guard !shown else { return }
                search = ""
                sportFilter = nil
                placeFilter = nil
            }
            .fullScreenCover(isPresented: $recording) {
                VideoRecorder { url in
                    importing = true
                    Task {
                        let name = importName()
                        // Into Photos first, then referenced from there like
                        // any import: the recording survives the session being
                        // deleted, and the app does not hold a second copy.
                        // Without Photos access it stays a private copy.
                        var id: UUID?
                        if let asset = await store.saveRecordingToPhotos(url) {
                            id = await store.importFromPhotos(identifier: asset, fallback: url,
                                                              name: name, detect: false)
                        } else {
                            id = await store.importVideo(from: url, name: name, detect: false,
                                                         rescue: true)
                        }
                        importing = false
                        guard let id else { importError = L.s("import_failed", lang); return }
                        path.append(id)
                        await store.processQueued([id])
                    }
                }
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems,
                          maxSelectionCount: 20, selectionBehavior: .ordered,
                          matching: .videos, photoLibrary: .shared())
            // Action cameras and screen recorders hand over files, not Photos
            // assets: a GoPro or DJI match arrives through Files or AirDrop.
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                importFiles(urls)
            }
            // An alert, not a confirmation dialog: iOS 26 floats the dialog as a
            // popover, and its slower dismissal could swallow the picker.
            .alert(L.s("ask_sport_title", lang), isPresented: $askSport) {
                ForEach(Sport.allCases) { sp in
                    Button("\(sp.emoji) \(L.s(sp.rawValue, lang))") {
                        store.lastSport = sp
                        let source = pendingSource
                        pendingSource = nil
                        // The dialog has to finish closing before a picker can
                        // present, or the picker silently never appears.
                        Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            if let source { launch(source) }
                        }
                    }
                }
                Button(L.s("cancel", lang), role: .cancel) { pendingSource = nil }
            } message: {
                Text(L.s("ask_sport_msg", lang))
            }
            .alert(rescueMessage ?? "", isPresented: Binding(
                get: { rescueMessage != nil }, set: { if !$0 { rescueMessage = nil } })) {
                Button("OK", role: .cancel) { rescueMessage = nil }
            }
            .alert(L.s("camera_unavailable", lang), isPresented: $cameraAlert) {
                Button("OK", role: .cancel) {}
            }
            .alert(importError ?? "", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            }
            // An alert, not a confirmation dialog: iOS 26 floats the dialog as a
            // popover anchored to this whole screen.
            .alert(
                String(format: L.s(selection.count == 1 ? "delete_one_session"
                                        : "delete_n_sessions", lang), selection.count),
                isPresented: $confirmDelete) {
                Button(L.s("delete", lang), role: .destructive) {
                    for id in selection {
                        if let s = store.sessions.first(where: { $0.id == id }) {
                            store.deleteSession(s)
                        }
                    }
                    selection.removeAll()
                    selecting = false
                }
                // A delete from the menu borrowed the selection; give it back.
                Button(L.s("cancel", lang), role: .cancel) {
                    if !selecting { selection.removeAll() }
                }
            } message: {
                Text(L.s("delete_sessions_note", lang))
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                importing = true
                Task {
                    // Every video is registered first so all of them show up
                    // at once, then detected one after another — a set filmed
                    // in three files is one import, not three trips.
                    var ids: [UUID] = []
                    var failed = 0
                    for item in items {
                        // Referencing the library asset is tried FIRST, without a
                        // copy. Loading the transferable up front duplicated the
                        // whole file — 6.5 GB for a 26-minute 4K match — behind a
                        // bare spinner, and then deleted it unused on the happy
                        // path. The copy is now made only when referencing fails.
                        let name = importName()
                        var id: UUID?
                        if let ident = item.itemIdentifier {
                            id = await store.importFromPhotos(identifier: ident, fallback: nil,
                                                              name: name, detect: false)
                        }
                        if id == nil,
                           let copy = try? await item.loadTransferable(type: MovieFile.self) {
                            id = await store.importVideo(from: copy.url, name: name, detect: false)
                        }
                        if let id { ids.append(id) } else { failed += 1 }
                    }
                    let single = items.count == 1
                    pickerItems = []
                    importing = false
                    if failed > 0 { importError = L.s("import_failed", lang) }
                    if single, let id = ids.first { path.append(id) }
                    await store.processQueued(ids)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sportscourt")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.secondaryText)
            Text(L.s("lib_empty_title", lang)).font(.title3.bold())
            Text(L.s("lib_empty_body", lang))
                .font(.subheadline).foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Menu { importMenuItems } label: { bigImportLabel }
                Button {
                    begin(.record)
                } label: {
                    Label(L.s("record", lang), systemImage: "video.fill")
                        .font(.subheadline.bold())
                }
                .rcSecondary()
            }
            .padding(.top, 8)
        }
        .padding(32)
    }

    private var sportFilterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Side by side the count claims half the row and "Filter" breaks
            // as "Filte / r" on a 4.7" screen at accessibility sizes.
            let count = Text(String(format: L.s(visibleSessions.count == 1 ? "n_one_session"
                                                : "n_sessions", lang), visibleSessions.count))
                .font(.caption).foregroundStyle(Theme.secondaryText)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L.s("filter", lang), systemImage: "line.3.horizontal.decrease")
                        .font(.subheadline.bold())
                    count
                }
            } else {
                HStack {
                    Label(L.s("filter", lang), systemImage: "line.3.horizontal.decrease")
                        .font(.subheadline.bold())
                    Spacer()
                    count
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { sportFilter = nil; placeFilter = nil } label: {
                        Text(L.s("all", lang))
                            .chip(active: sportFilter == nil && placeFilter == nil)
                    }
                    .buttonStyle(.plain)
                    ForEach(Sport.allCases) { sp in
                        Button { sportFilter = sportFilter == sp ? nil : sp } label: {
                            Text("\(sp.emoji) \(L.s(sp.rawValue, lang))")
                                .chip(active: sportFilter == sp)
                        }
                        .buttonStyle(.plain)
                    }
                    let places = store.knownPlaces()
                    if !places.isEmpty {
                        Divider().frame(height: 22).overlay(Theme.hairline)
                        ForEach(places, id: \.self) { place in
                            Button { placeFilter = placeFilter == place ? nil : place } label: {
                                Label(place, systemImage: "mappin.and.ellipse")
                                    .chip(active: placeFilter == place)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.bottom, 2)
    }

    private var deleteBar: some View {
        HStack {
            Text(String(format: L.s("selected_fmt", lang), selection.count))
                .font(.subheadline).foregroundStyle(Theme.secondaryText)
            Spacer()
            Button(role: .destructive) { confirmDelete = true } label: {
                Label(L.s("delete", lang), systemImage: "trash")
                    .font(.subheadline.bold())
            }
            .rcSecondary(destructive: true)
            .disabled(selection.isEmpty)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var bigImportLabel: some View {
        Label(L.s("import_video", lang), systemImage: "plus")
            .font(.headline)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.tint, in: Capsule())
            .foregroundStyle(Theme.onAccent)
    }

    /// Every way a match gets in, in one menu: Photos, Files, or shooting
    /// it in-app (the recording goes straight into detection).
    private var importButton: some View {
        Menu {
            importMenuItems
            Button { begin(.record) } label: {
                Label(L.s("record", lang), systemImage: "video.fill")
            }
        } label: {
            Label(L.s("import_video", lang), systemImage: "plus")
        }
    }

    @ViewBuilder private var importMenuItems: some View {
        Button { begin(.photos) } label: {
            Label(L.s("import_photos", lang), systemImage: "photo.on.rectangle")
        }
        Button { begin(.files) } label: {
            Label(L.s("import_files", lang), systemImage: "folder")
        }
    }

    /// Every way in asks the sport once, before the first import: detection
    /// runs the moment a video lands, and it runs with the sport's strike
    /// profile. After that the last choice is used and changed per session.
    private func begin(_ source: ImportSource) {
        if store.lastSport == nil {
            pendingSource = source
            askSport = true
        } else {
            launch(source)
        }
    }

    private func launch(_ source: ImportSource) {
        // Reset first: a presentation that failed can leave the flag true, and
        // true → true never presents again.
        switch source {
        case .photos:
            showPhotoPicker = false
            Task { @MainActor in showPhotoPicker = true }
        case .files:
            showFileImporter = false
            Task { @MainActor in showFileImporter = true }
        case .record:
            guard VideoRecorder.isAvailable else { cameraAlert = true; return }
            recording = true
        }
    }

    private func importFiles(_ urls: [URL]) {
        importing = true
        Task {
            var ids: [UUID] = []
            var failed = 0
            for url in urls {
                // Files hands over a security-scoped URL that stops working
                // once access ends, so the video is copied in while it lasts.
                let copy = await Task.detached(priority: .userInitiated) { () -> URL? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                    return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil
                }.value
                if let copy, let id = await store.importVideo(from: copy, name: importName(),
                                                              detect: false) {
                    ids.append(id)
                } else {
                    failed += 1
                }
            }
            importing = false
            if failed > 0 { importError = L.s("import_failed", lang) }
            if urls.count == 1, let id = ids.first { path.append(id) }
            await store.processQueued(ids)
        }
    }

    private func select(_ session: Session) {
        selection = [session.id]
        selecting = true
    }

    private func askDelete(_ session: Session) {
        selection = [session.id]
        confirmDelete = true
    }

    /// Recordings a failed import set aside. Offered back once, as a card,
    /// until they are saved to Photos.
    @ViewBuilder private var recoveredCard: some View {
        let count = store.recoveredRecordings().count
        if count > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Label(String(format: L.s("recovered_fmt", lang), count),
                      systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.subheadline.bold())
                Text(L.s("recovered_d", lang))
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task {
                        let saved = await store.saveRecoveredToPhotos()
                        rescueMessage = saved > 0 ? String(format: L.s(saved == 1 ? "saved_one_fmt" : "saved_n_fmt", lang), saved)
                                                  : L.s("photos_denied", lang)
                    }
                } label: {
                    Label(L.s("recovered_save", lang), systemImage: "square.and.arrow.down")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                }
                .rcSecondary()
                Button(role: .destructive) { confirmDiscard = true } label: {
                    Label(L.s("delete", lang), systemImage: "trash")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                }
                .rcSecondary(destructive: true)
            }
            .confirmationDialog(L.s("recovered_discard_confirm", lang),
                                isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button(L.s("delete", lang), role: .destructive) { store.discardRecovered() }
                Button(L.s("cancel", lang), role: .cancel) {}
            }
            .padding(14)
            .rcCard()
        }
    }

    /// Pro while a pass runs, with the minutes left; otherwise the way in.
    /// Debug builds also open the tier switch on a long press.
    private var entitlementPill: some View {
        Group {
            if pass.isPro {
                Text(pass.active ? String(format: L.s("pass_pill_fmt", lang), pass.minutesLeft)
                                 : L.s("pro", lang))
                    .font(.caption2.bold())
                    .fixedSize()      // the toolbar squeezes this to nothing otherwise
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.surfaceHigh, in: Capsule())
                    .foregroundStyle(.primary)
            } else {
                // Outlined like ProBadge: a solid volt capsule is a primary button.
                Label(L.s("pass_get", lang), systemImage: "play.rectangle.fill")
                    .font(.caption2.bold())
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1))
                    .foregroundStyle(Theme.accent)
            }
        }
        // Plain gestures rather than a Button: a Button consumes the touch on
        // press, so the debug long press never got a chance to fire.
        .contentShape(Capsule())
        // The pass lands while the ad sheet is closing, so the pill is where
        // the reward shows up: a spark and a success tap, once.
        .changeEffect(.spray {
            Image(systemName: "sparkle").foregroundStyle(Theme.accent)
        }, value: pass.isPro, isEnabled: pass.isPro && !reduceMotion)
        .changeEffect(.feedback(hapticNotification: .success),
                      value: pass.isPro, isEnabled: pass.isPro)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(pass.isPro ? L.s("pro", lang) : L.s("paywall_title", lang))
#if DEBUG
        .onLongPressGesture(minimumDuration: 1.2) {
            showDebug = true
        } onPressingChanged: { _ in }
#endif
        .onTapGesture {
            // A running pass opens the sheet too — that is where it is extended.
            if !pass.isPro || pass.active { showPro = true }
        }
    }

    private func importName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}

// MARK: - Session card

struct SessionCard: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    let session: Session
    /// nil = not in selection mode
    var selected: Bool? = nil
    /// Some finished reel was built from this session.
    var hasReel = false

    var body: some View {
        // A poster tile: everything sits on the frame, white over a scrim.
        // The frame size is the floor; at large text the tile grows and the
        // poster, drawn behind, fills whatever height the text needs.
        ZStack(alignment: .bottomLeading) {
            Color.clear.aspectRatio(16 / 8.5, contentMode: .fit)
            // Bottom 55%, at least 55% black under the text: white on a bright
            // court is unreadable otherwise.
            LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                   .init(color: .black.opacity(0.55), location: 0.7),
                                   .init(color: .black.opacity(0.8), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(L.dateTime(session.playedAt, lang))
                    .font(.headline)
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 6) {
                    Text(fmtDur(session.duration))
                    if let place = session.placeName {
                        Text("·")
                        Label(place, systemImage: "mappin")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                    }
                }
                .lineLimit(1)
                metaLine
                    .fontWeight(.semibold)
                    .lineLimit(2)
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .background { poster }
        .overlay(alignment: .topTrailing) { sportTag }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // The poster overflows its frame (scaledToFill); taps and the
        // long-press lift stop at the tile.
        .contentShape([.interaction, .contextMenuPreview], RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(selected ? Theme.onAccent : Color.white,
                                     selected ? Theme.accent : Color.white.opacity(0.7))
                    .padding(10)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.accent, lineWidth: selected == true ? 3 : 0))
        .opacity(selected == false ? 0.55 : 1)
    }

    @ViewBuilder private var poster: some View {
        if let img = PosterCache.load(store.posterURL(session)) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                Theme.surfaceHigh
                Image(systemName: "sportscourt")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var sportTag: some View {
        Text("\(session.sport.emoji) \(L.s(session.sport.rawValue, lang))")
            .font(.caption.bold())
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
    }

    @ViewBuilder private var metaLine: some View {
        if let stage = store.progress[session.id] {
            StageLabel(stage: stage, color: .white)
        } else if let segs = session.segments {
            Text(meta(segs))
        } else {
            Text(L.s("not_detected", lang))
        }
    }

    /// "9 rallies · Longest 0:42 · Reels ✓". Rallies rather than clips: they
    /// survive "free up clip files", the clips do not.
    private func meta(_ segs: [RallySegment]) -> String {
        var parts = [String(format: L.s(segs.count == 1 ? "rallies_one" : "rallies_n", lang),
                            segs.count)]
        // A minute-plus span is several rallies stuck together, not a long one.
        let real = segs.filter { !$0.looksMerged }
        if let longest = (real.isEmpty ? segs : real).map(\.duration).max() {
            parts.append(L.s("longest", lang) + " " + fmtDur(longest))
        }
        if hasReel { parts.append(L.s("reels", lang) + " ✓") }
        return parts.joined(separator: " · ")
    }
}

struct StageLabel: View {
    @AppStorage("rc_lang") private var lang = "en"
    let stage: ProcessingStage
    /// White on a poster: secondaryText fails contrast over video.
    var color: Color = Theme.secondaryText

    var body: some View {
        HStack(spacing: 6) {
            if case .failed = stage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            } else {
                ProgressView().controlSize(.mini).tint(color)
            }
            Text(text).font(.caption.monospacedDigit()).foregroundStyle(color)
        }
    }

    private var text: String {
        switch stage {
        case .queued: return L.s("stage_queued", lang)
        case .audio: return L.s("stage_audio", lang)
        case .detect: return L.s("stage_detect", lang)
        case .render(let d, let t):
            return L.s("stage_render", lang) + " " + String(d) + "/" + String(t)
        case .merge: return L.s("stage_merge", lang)
        case .reel(let d, let t):
            return L.s("stage_reel", lang) + " " + String(d) + "/" + String(t)
        // The row is too narrow for the reason, and a system error's text
        // was cut off mid-word. The session screen says what went wrong.
        case .failed: return L.s("stage_failed", lang)
        }
    }
}

func fmtDur(_ s: Double) -> String {
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}

/// A position in the video as people read one: "0:03", "12:40", "1:02:05" —
/// no padded "00:03".
func fmtPos(_ s: Double) -> String {
    let t = max(0, Int(s))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}

func fmtTs(_ s: Double) -> String {
    String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60)
}
