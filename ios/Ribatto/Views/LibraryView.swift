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
    @State private var showLicenses = false
    @State private var showPrivacy = false
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

    enum ImportSource { case photos, files, record, sample }

    /// The bundled demo match, when the build carries one. The empty library is
    /// the first thing a new user — and the App Review tester — sees, usually
    /// on a phone with no match video on it.
    static var sampleURL: URL? { Bundle.main.url(forResource: "sample_match", withExtension: "mp4") }

    /// Text match on the sport and the date shown on the card, plus the
    /// sport chip — enough to find "that badminton match last week".
    private var visibleSessions: [Session] {
        store.sessions.filter { s in
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            TabHeader(title: L.s("my_sessions", lang)) {
                if !store.sessions.isEmpty {
                    Button(selecting ? L.s("done", lang) : L.s("select", lang)) {
                        selecting.toggle()
                        selection.removeAll()
                    }
                    .font(.subheadline.bold())
                }
                // A toolbar collapses a Label to its icon; in the content it
                // would spell out "Import video" and "Record" and push the
                // title out of the row.
                importButton
                    .labelStyle(.iconOnly)
                    .font(.title3)
                recordButton
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
            // Language and the free-import count are secondary to the actions,
            // so they sit under the title rather than competing with it.
            HStack(spacing: 10) {
                languageMenu
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
                            SearchField(prompt: L.s("search_sessions", lang), text: $search)
                            if importing { ProgressView().padding() }
                            recoveredCard
                            // one session doesn't need filtering — chips would be noise
                            if store.sessions.count > 1 { sportFilterBar }
                            if visibleSessions.isEmpty {
                                Text(L.s("no_match", lang))
                                    .font(.subheadline).foregroundStyle(.secondary)
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
                                        SessionCard(session: session)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            if selecting { deleteBar }
                            Color.clear.frame(height: 62)
                        }
                        .padding()
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
            .sheet(isPresented: $showPro) { ProPassView() }
#if DEBUG
            .sheet(isPresented: $showDebug) { DebugProSheet() }
#endif
            .sheet(isPresented: $showLicenses) { LicensesView() }
            .sheet(isPresented: $showPrivacy) { PrivacyView() }
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
            .confirmationDialog(L.s("ask_sport_title", lang), isPresented: $askSport,
                                titleVisibility: .visible) {
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
            .confirmationDialog(
                String(format: L.s(selection.count == 1 ? "delete_one_session"
                                        : "delete_n_sessions", lang), selection.count),
                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L.s("delete", lang), role: .destructive) {
                    for id in selection {
                        if let s = store.sessions.first(where: { $0.id == id }) {
                            store.deleteSession(s)
                        }
                    }
                    selection.removeAll()
                    selecting = false
                }
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
                    pickerItems = []
                    importing = false
                    if failed > 0 { importError = L.s("import_failed", lang) }
                    await store.processQueued(ids)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sportscourt")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text(L.s("lib_empty_title", lang)).font(.title3.bold())
            Text(L.s("lib_empty_body", lang))
                .font(.subheadline).foregroundStyle(.secondary)
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
                if Self.sampleURL != nil {
                    Button {
                        begin(.sample)
                    } label: {
                        Label(L.s("try_sample", lang), systemImage: "play.circle")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                }
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
                .font(.caption).foregroundStyle(.secondary)
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
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { confirmDelete = true } label: {
                Label(L.s("delete", lang), systemImage: "trash")
                    .font(.subheadline.bold())
            }
            .rcSecondary(destructive: true)
            .disabled(selection.isEmpty)
        }
        .padding(14)
        .rcCard()
        .padding(.top, 4)
    }

    private var bigImportLabel: some View {
        Label(L.s("import_video", lang), systemImage: "plus")
            .font(.headline)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.tint, in: Capsule())
            .foregroundStyle(.black)
    }

    /// Shoot a match in-app; the recording goes straight into detection.
    @ViewBuilder private var recordButton: some View {
        Button {
            begin(.record)
        } label: {
            Label(L.s("record", lang), systemImage: "video.fill")
        }
    }

    private var importButton: some View {
        Menu { importMenuItems } label: {
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
        switch source {
        case .photos: showPhotoPicker = true
        case .files: showFileImporter = true
        case .record:
            guard VideoRecorder.isAvailable else { cameraAlert = true; return }
            recording = true
        case .sample: importSample()
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
            await store.processQueued(ids)
        }
    }

    private func importSample() {
        guard let sample = Self.sampleURL else { return }
        importing = true
        Task {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            var id: UUID?
            if (try? FileManager.default.copyItem(at: sample, to: dest)) != nil {
                id = await store.importVideo(from: dest, name: L.s("sample_name", lang), detect: false)
            }
            importing = false
            guard let id else { importError = L.s("import_failed", lang); return }
            await store.processQueued([id])
        }
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
                    .font(.caption).foregroundStyle(.secondary)
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
                Label(L.s("pass_get", lang), systemImage: "play.rectangle.fill")
                    .font(.caption2.bold())
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(Theme.onAccent)
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

    private var languageMenu: some View {
        Menu {
            ForEach(L.languages, id: \.code) { l in
                Button {
                    lang = l.code
                } label: {
                    if lang == l.code { Label(l.label, systemImage: "checkmark") }
                    else { Text(l.label) }
                }
            }
            Divider()
            // "No account, and the video never leaves the phone" is the app's
            // main promise, so the detail behind it should be readable without
            // leaving the app.
            Button {
                showPrivacy = true
            } label: {
                Label(L.s("privacy", lang), systemImage: "hand.raised")
            }
            // The bundled fonts ship under the OFL, which requires their
            // licence to be included with them. This is where it lives.
            Button {
                showLicenses = true
            } label: {
                Label(L.s("licenses", lang), systemImage: "doc.text")
            }
            if ads.privacyOptionsRequired {
                Button {
                    Task { await ads.presentPrivacyOptions() }
                } label: {
                    Label(L.s("ad_privacy_options", lang), systemImage: "checkmark.shield")
                }
            }
        } label: {
            Image(systemName: "globe")
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

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                poster
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 8.5, contentMode: .fit)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.75)],
                               startPoint: .center, endPoint: .bottom)
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
                        } else {
                            Text("· \(String(session.width))×\(String(session.height))")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(12)
                sportTag
            }
            HStack {
                aspectBadge
                statusView
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(selected ? Color.black : Color.white,
                                     selected ? Color.accentColor : Color.white.opacity(0.7))
                    .padding(10)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(.tint, lineWidth: selected == true ? 3 : 0))
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
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sportTag: some View {
        VStack {
            HStack {
                Spacer()
                Text("\(session.sport.emoji) \(L.s(session.sport.rawValue, lang))")
                    .font(.caption.bold())
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
            Spacer()
        }
    }

    private var aspectBadge: some View {
        Text(OutputFrame(session.effectiveOrientation).label)
            .font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.surfaceHigh, in: Capsule())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var statusView: some View {
        if let stage = store.progress[session.id] {
            StageLabel(stage: stage)
        } else if let segs = session.segments {
            // Rallies survive "free up clip files"; the clips do not. Counting
            // segments and calling them clips left the card promising 13 clips
            // for a session whose files had been cleared.
            let unit = store.hasClipFiles(session)
                ? L.s(segs.count == 1 ? "clip_one" : "clips", lang)
                : L.s("rallies", lang)
            Text("\(String(segs.count)) \(unit)")
                .font(.caption.bold()).foregroundStyle(.secondary)
        } else {
            Text(L.s("not_detected", lang))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct StageLabel: View {
    @AppStorage("rc_lang") private var lang = "en"
    let stage: ProcessingStage

    var body: some View {
        HStack(spacing: 6) {
            if case .failed = stage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(text).font(.caption).foregroundStyle(.secondary)
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

func fmtTs(_ s: Double) -> String {
    String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60)
}
