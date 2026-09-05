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
            Group {
                let reels = store.reels()
                if reels.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(L.s("reels_empty", lang))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
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
                            Text(ByteCountFormatter.string(fromByteCount: store.reelsBytes(),
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
            .navigationTitle(L.s("reels", lang))
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
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomTrailing)
                    Text(L.s("reel_" + reel.target, lang))
                        .font(.caption2.bold())
                        .lineLimit(1)
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
        if let img = UIImage(contentsOfFile: reel.thumbURL.path) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Theme.surfaceHigh
        }
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(OutputFrame(reel.frame).aspectRatio, contentMode: .fit)
                }
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Button {
                        Task { saved = await store.saveToPhotos(reel.url) }
                    } label: {
                        Label(saved ? L.s("reel_saved", lang) : L.s("reel_save", lang),
                              systemImage: saved ? "checkmark" : "square.and.arrow.down")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .rcPrimary()
                    ShareLink(item: reel.url) {
                        Label(L.s("share", lang), systemImage: "square.and.arrow.up")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .rcSecondary()
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(L.s("reel_" + reel.target, lang))
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
                    store.deleteReel(reel); dismiss()
                }
            }
            .onAppear { if player == nil { player = AVPlayer(url: reel.url) } }
        }
        .preferredColorScheme(.dark)
    }
}
