import AVKit
import PhotosUI
import SwiftUI

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
    @EnvironmentObject var purchases: PurchaseManager
    @AppStorage("rc_lang") private var lang = "en"
    @State private var showLicenses = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var importing = false
    @State private var showPaywall = false
    @State private var paywallFeature: String?
    @State private var recording = false
    @State private var cameraAlert = false
    @State private var importError: String?
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmDelete = false
    @State private var search = ""
    @State private var sportFilter: Sport?
    @State private var placeFilter: String?
    @State private var showOwner = false

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
            Group {
                if store.sessions.isEmpty && !importing {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if importing { ProgressView().padding() }
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
                    .searchable(text: $search, prompt: L.s("search_sessions", lang))
                }
            }
            .navigationTitle(L.s("my_sessions", lang))
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 10) {
                        languageMenu
                        entitlementPill
                    }
                }
                if !store.sessions.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selecting ? L.s("done", lang) : L.s("select", lang)) {
                            selecting.toggle()
                            selection.removeAll()
                        }
                        .font(.subheadline.bold())
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { importButton }
                ToolbarItem(placement: .topBarTrailing) { recordButton }
            }
            .sheet(isPresented: $showPaywall) { PaywallView(feature: paywallFeature) }
            .sheet(isPresented: $showOwner) { OwnerSheet() }
            .sheet(isPresented: $showLicenses) { LicensesView() }
            .fullScreenCover(isPresented: $recording) {
                VideoRecorder { url in
                    importing = true
                    Task {
                        // the store spends the free import the moment the
                        // session is written, so nothing is counted here
                        if await store.importVideo(from: url, name: importName()) == false {
                            importError = L.s("import_failed", lang)
                        }
                        importing = false
                    }
                }
                .ignoresSafeArea()
            }
            .alert(L.s("camera_unavailable", lang), isPresented: $cameraAlert) {
                Button("OK", role: .cancel) {}
            }
            .alert(importError ?? "", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            }
            .confirmationDialog(
                String(format: L.s("delete_n_sessions", lang), selection.count),
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
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                importing = true
                Task {
                    let copy = try? await item.loadTransferable(type: MovieFile.self)
                    let created: Bool
                    if let id = item.itemIdentifier {
                        // reference the library original instead of duplicating it
                        created = await store.importFromPhotos(identifier: id,
                                                               fallback: copy?.url,
                                                               name: importName())
                    } else if let copy {
                        created = await store.importVideo(from: copy.url, name: importName())
                    } else {
                        created = false
                    }
                    if !created { importError = L.s("import_failed", lang) }
                    importing = false
                    pickerItem = nil
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sportscourt")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
            Text(L.s("lib_empty_title", lang)).font(.title3.bold())
            Text(L.s("lib_empty_body", lang))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Group {
                    if purchases.canImport {
                        PhotosPicker(selection: $pickerItem, matching: .videos,
                                 photoLibrary: .shared()) { bigImportLabel }
                    } else {
                        Button { showPaywall = true } label: { bigImportLabel }
                    }
                }
                Button {
                    guard purchases.canImport else { showPaywall = true; return }
                    guard VideoRecorder.isAvailable else { cameraAlert = true; return }
                    recording = true
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
            HStack {
                Label(L.s("filter", lang), systemImage: "line.3.horizontal.decrease")
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: L.s("n_sessions", lang), visibleSessions.count))
                    .font(.caption).foregroundStyle(.secondary)
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
            guard purchases.canImport else { showPaywall = true; return }
            guard VideoRecorder.isAvailable else { cameraAlert = true; return }
            recording = true
        } label: {
            Label(L.s("record", lang), systemImage: "video.fill")
        }
    }

    @ViewBuilder private var importButton: some View {
        if purchases.canImport {
            PhotosPicker(selection: $pickerItem, matching: .videos,
                         photoLibrary: .shared()) {
                Label(L.s("import_video", lang), systemImage: "plus")
            }
        } else {
            Button {
                paywallFeature = L.s("feat_unlimited", lang)
                showPaywall = true
            } label: {
                Label(L.s("import_video", lang), systemImage: "lock.fill")
            }
        }
    }

    /// Long-pressing this opens the owner panel. There is nothing to see for
    /// anyone without the passphrase, and no affordance hints at it.
    @ViewBuilder private var entitlementPill: some View {
        Group {
            if purchases.isPro {
                Text(purchases.ownerMode ? L.s("owner_on", lang) : L.s("pro", lang))
                    .font(.caption2.bold())
                    .fixedSize()      // the toolbar squeezes this to nothing otherwise
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.black)
            } else {
                Text(String(format: L.s("free_left_fmt", lang), purchases.remainingFree))
                    .font(.caption2.bold())
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(purchases.ownerMode ? Theme.warning.opacity(0.25)
                                                    : Theme.surfaceHigh, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        // Plain gestures rather than a Button: a Button consumes the touch on
        // press, so the long press never got a chance to fire.
        .contentShape(Capsule())
        // Debug-only: a passphrase-gated switch that grants the paid
        // entitlement is undocumented functionality in a shipped build, which
        // App Review rejects under 2.3.1.
#if DEBUG
        .onLongPressGesture(minimumDuration: 1.2) {
            showOwner = true
        } onPressingChanged: { _ in }
#endif
        .onTapGesture {
            if !purchases.isPro { showPaywall = true }
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
            // The bundled fonts ship under the OFL, which requires their
            // licence to be included with them. This is where it lives.
            Button {
                showLicenses = true
            } label: {
                Label(L.s("licenses", lang), systemImage: "doc.text")
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
        if let img = UIImage(contentsOfFile: store.posterURL(session).path) {
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
            Text("\(String(segs.count)) \(L.s(segs.count == 1 ? "clip_one" : "clips", lang))")
                .font(.caption.bold()).foregroundStyle(.tint)
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
        case .failed(let msg): return msg
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
