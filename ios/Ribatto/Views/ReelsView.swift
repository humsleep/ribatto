import AVKit
import SwiftUI

/// Everything the user has actually built.
///
/// Before this screen a finished reel was written to disk, shown once in the
/// sheet that made it, and then unreachable — the app's whole output had no way
/// back to it, and the files piled up where nobody could see or clear them.
struct ReelsView: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"

    @State private var playing: ReelInfo?
    @State private var confirmDelete: ReelInfo?
    @State private var saveMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 10)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            TabHeader(title: L.s("reels", lang))
            Group {
                // One scan per pass: `reelsBytes()` used to run the whole
                // listing a second time just to total the sizes.
                let reels = store.reels()
                let bytes = reels.reduce(Int64(0)) { $0 + $1.bytes }
                if reels.isEmpty {
                    EmptyStateBox {
                        VStack(spacing: 10) {
                            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.secondary)
                            Text(L.s("reels_empty", lang))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(32)
                    }
                } else {
                    ScrollView {
                        // Reels are the biggest files the app writes, so the
                        // total is stated rather than left to be discovered in
                        // the Settings storage list.
                        HStack {
                            Text(String(format: L.s(reels.count == 1 ? "reels_one_fmt"
                                                                       : "reels_count_fmt", lang),
                                        reels.count))
                                .font(.headline)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: bytes,
                                                           countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)

                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(reels) { reel in
                                card(reel)
                            }
                        }
                        .padding(.horizontal)
                        Color.clear.frame(height: 62)     // clear the tab bar
                    }
                }
            }
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(Theme.background.ignoresSafeArea())
            .sheet(item: $playing) { reel in
                ReelPlayerSheet(reel: reel)
            }
            .confirmationDialog(L.s("reel_delete", lang),
                                isPresented: Binding(get: { confirmDelete != nil },
                                                     set: { if !$0 { confirmDelete = nil } })) {
                Button(L.s("delete", lang), role: .destructive) {
                    if let r = confirmDelete { store.deleteReel(r) }
                    confirmDelete = nil
                }
            }
        }
    }

    private func card(_ reel: ReelInfo) -> some View {
        Button { playing = reel } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .aspectRatio(OutputFrame(reel.frame).aspectRatio, contentMode: .fit)
                        .overlay { thumb(reel) }
                        .clipped()
                    Text(fmtDur(reel.duration))
                        .font(.caption2.bold())
                        // Badges sit on a fixed-size thumbnail, as on the clip
                        // cards: scaled with the body text they cover the frame
                        // they are meant to annotate.
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomTrailing)
                    Text(L.s("reel_" + reel.target, lang))
                        .font(.caption2.bold())
                        .lineLimit(1)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L.s(reel.rallies == 1 ? "rallies_one" : "rallies_n", lang),
                                reel.rallies))
                        .font(.caption2.bold())
                    Text(reel.place ?? L.dateOnly(reel.createdAt, lang))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The grid fixes the cell width, so unbounded these two lines
                // wrap one syllable per row and swallow the card.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(8)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { confirmDelete = reel } label: {
                Label(L.s("delete", lang), systemImage: "trash")
            }
        }
    }

    @ViewBuilder private func thumb(_ reel: ReelInfo) -> some View {
        PosterImage(url: reel.thumbURL)
    }
}

/// Plays one saved reel and offers the two things you do with it afterwards.
struct ReelPlayerSheet: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    let reel: ReelInfo

    @State private var player: AVPlayer?
    @State private var saved = false
    @State private var confirmDelete = false
    /// The reel on screen. A recaption re-renders into a new file, so this
    /// moves off the one the sheet was opened with.
    @State private var current: ReelInfo?
    @State private var editingCaption = false
    @State private var rebuilding = false
    @State private var message: String?

    private var shown: ReelInfo { current ?? reel }
    /// The rallies this reel can be rebuilt from — recorded in its sidecar, or
    /// worked back out for a reel made before that was recorded.
    private var rebuildSources: [ReelSource]? { store.recoverSources(for: shown) }
    /// The session the caption editor previews against — the one the reel's
    /// first rally came from.
    private var captionSession: Session? {
        guard let first = rebuildSources?.first else { return nil }
        return store.sessions.first { $0.id == first.sessionID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(OutputFrame(reel.frame).aspectRatio, contentMode: .fit)
                }
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    // A reel's caption is burned in, so changing it means
                    // rendering the reel again — which is only possible for a
                    // reel that recorded where its rallies came from.
                    if let session = captionSession {
                        Button {
                            editingCaption = true
                        } label: {
                            Label(rebuilding ? L.s("reel_recaptioning", lang)
                                             : L.s("edit_caption", lang),
                                  systemImage: "textformat")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, minHeight: 24)
                        }
                        .rcSecondary()
                        .disabled(rebuilding)
                        .sheet(isPresented: $editingCaption) {
                            CaptionEditorView(session: session,
                                              caption: shown.caption,
                                              frame: OutputFrame(shown.frame)) { edited in
                                recaption(edited)
                            }
                        }
                    }
                    Button {
                        Task { saved = await store.saveToPhotos(shown.url) }
                    } label: {
                        Label(saved ? L.s("reel_saved", lang) : L.s("reel_save", lang),
                              systemImage: saved ? "checkmark" : "square.and.arrow.down")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .rcPrimary()
                    .disabled(rebuilding)
                    ShareLink(item: shown.url) {
                        Label(L.s("share", lang), systemImage: "square.and.arrow.up")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .rcSecondary()
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(L.s("reel_" + shown.target, lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .confirmationDialog(L.s("reel_delete", lang), isPresented: $confirmDelete) {
                Button(L.s("delete", lang), role: .destructive) {
                    store.deleteReel(shown); dismiss()
                }
            }
            .alert(message ?? "", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            }
            .onAppear { if player == nil { player = AVPlayer(url: shown.url) } }
        }
        .preferredColorScheme(.dark)
    }

    /// Renders the reel again with a new caption and swaps the player over to
    /// the new file.
    private func recaption(_ caption: CaptionSettings) {
        rebuilding = true
        Task {
            let rebuilt = await store.rebuildReel(shown, caption: caption)
            rebuilding = false
            guard let rebuilt else {
                message = L.s("reel_recaption_failed", lang)
                return
            }
            current = rebuilt
            saved = false
            player = AVPlayer(url: rebuilt.url)
            player?.play()
        }
    }
}
