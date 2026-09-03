import AVKit
import SwiftUI

/// The clips a reel is being built from. Wrapped in a type so it can drive a
/// `.sheet(item:)` — an array of tuples can't.
struct ReelRequest: Identifiable {
    let id = UUID()
    let pairs: [(session: Session, clip: ClipInfo)]
}

/// Turns one or more rallies into a single vertical video sized for the place
/// it's going, then hands it off to Photos or the share sheet.
struct ReelSheet: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    let request: ReelRequest

    @State private var target: ReelTarget = .reels
    @State private var frame: OutputFrame = .vertical
    @State private var pace: ReelPace = .full
    /// nil keeps whatever each session's own caption looks like.
    @State private var preset: ReelPreset? = nil
    @State private var building = false
    @State private var done: (url: URL, plan: ReelPlan)?
    @State private var player: AVPlayer?
    @State private var message: String?
    @State private var savedToPhotos = false
    /// The running order, with each rally's own in/out switch. Seeded from the
    /// request in timeline order and then owned by this screen, so reordering
    /// and excluding don't have to reach back into the selection that made it.
    @State private var entries: [Entry] = []

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let done {
                        resultView(done)
                    } else {
                        setupView
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(L.s("reel_title", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(.secondary)
                        .disabled(building)
                }
            }
            .alert(message ?? "", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(building)
        .onAppear {
            guard entries.isEmpty else { return }
            entries = request.pairs
                .sorted { ($0.session.playedAt, $0.clip.segment.start)
                        < ($1.session.playedAt, $1.clip.segment.start) }
                .map { Entry(id: $0.session.id.uuidString + "-" + $0.clip.id,
                             session: $0.session, clip: $0.clip) }
        }
    }

    // MARK: - Setup

    /// Presets sit above the individual controls because they set several of
    /// them at once: picking one seeds the pace and the frame, and keeps
    /// restyling the caption. Every control below stays editable afterwards —
    /// a preset is a starting point, not a mode.
    private var presetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.s("reel_preset", lang))
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        preset = nil
                    } label: {
                        Text(L.s("preset_own", lang)).chip(active: preset == nil)
                    }
                    .buttonStyle(.plain)
                    ForEach(ReelPreset.allCases) { p in
                        Button {
                            preset = p
                            pace = p.pace
                            frame = p.frame
                        } label: {
                            Text(L.s("preset_" + p.rawValue, lang))
                                .chip(active: preset == p)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            Text(L.s(preset == nil ? "preset_own_d" : "preset_" + preset!.rawValue + "_d", lang))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .rcCard()
    }

    private var setupView: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                Text(String(format: L.s("reel_included_fmt", lang),
                            chosen.count, entries.count)
                     + " · " + fmtDur(cappedSeconds))
                    .font(.headline)
                    .foregroundStyle(chosen.isEmpty ? Theme.warning : .primary)
                if overCap {
                    Label(L.s("reel_over_cap", lang) + " · " + fmtDur(totalSeconds),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                Text(L.s("reel_sub", lang))
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            presetCard
            if entries.count > 1 { runningOrderCard }
            paceCard

            VStack(alignment: .leading, spacing: 10) {
                Text(L.s("reel_platform", lang))
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(ReelTarget.allCases) { t in
                    targetRow(t)
                }
            }
            .padding(14)
            .rcCard()

            frameCard

            if request.pairs.count > 1 {
                Label(L.s("reel_order_note", lang), systemImage: "arrow.down.right.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if building {
                VStack(spacing: 8) {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                    Text(buildingLabel)
                        .font(.caption).foregroundStyle(.secondary)
                    Label(L.s("keep_awake", lang), systemImage: "iphone.gen3")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
            } else {
                Button {
                    Task { await build() }
                } label: {
                    Label(L.s("reel_build", lang), systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .rcPrimary()
                .disabled(chosen.isEmpty)
            }
        }
    }

    private var buildingLabel: String {
        let key = request.pairs.first?.session.id
        if let key, case .reel(let d, let t)? = store.progress[key], t > 0 {
            return L.s("reel_building", lang) + "  \(d)/\(t)"
        }
        return L.s("reel_building", lang)
    }

    /// The running order, with a switch per rally and a shortcut that keeps
    /// only the best-scoring ones. Picking which fifteen seconds to post is the
    /// actual work in a 26-minute match, so the shortcut leads.
    private var runningOrderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.s("reel_reorder", lang))
                    .font(.subheadline.bold())
                Spacer()
                if entries.count > 3, entries.contains(where: { $0.clip.segment.score != nil }) {
                    ForEach([3, 5], id: \.self) { n in
                        Button(String(format: L.s("reel_pick_top", lang), n)) { keepTop(n) }
                            .font(.caption.bold())
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .padding(.leading, 8)
                    }
                }
            }
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
                        VStack(alignment: .leading, spacing: 1) {
                            Text("#\(entry.clip.index + 1) · "
                                 + fmtDur(pace.estimatedLength(of: entry.clip.segment)))
                                .font(.subheadline.weight(.medium))
                            Text(String(entry.clip.segment.hits) + " " + L.s("shots_n", lang)
                                 + (entry.clip.segment.score.map {
                                     " · ★ " + String(format: "%.2f", $0) } ?? ""))
                                .font(.caption2).foregroundStyle(.secondary)
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
            .scrollDisabled(true)
            .environment(\.editMode, .constant(.active))
            .frame(height: min(CGFloat(entries.count) * 52 + 8, 320))
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

    private var paceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.s("reel_pace", lang))
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(ReelPace.allCases) { p in
                Button { pace = p } label: {
                    HStack(spacing: 12) {
                        Image(systemName: p.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(pace == p ? Theme.onAccent : Theme.accent)
                            .frame(width: 26, height: 26)
                            .background(pace == p ? Theme.accent : Theme.surfaceHigh, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L.s("pace_" + p.rawValue, lang)).font(.subheadline.bold())
                            Text(L.s("pace_" + p.rawValue + "_d", lang))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: pace == p ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(pace == p ? Theme.accent
                                             : Color.secondary.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .rcCard()
        .disabled(building)
    }

    /// 9:16 vs 4:5. Worth a choice rather than a constant: 9:16 keeps 31.6% of
    /// a wide match's width, which on real footage leaves the opponent right on
    /// the edge; 4:5 keeps 45% and holds both players with margin.
    private var frameCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.s("reel_frame", lang))
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                frameButton(.vertical, detail: L.s("frame_916_d", lang))
                frameButton(.portrait45, detail: L.s("frame_45_d", lang))
            }
        }
        .padding(14)
        .rcCard()
    }

    private func frameButton(_ f: OutputFrame, detail: String) -> some View {
        let active = frame == f
        return Button { frame = f } label: {
            VStack(spacing: 3) {
                Text(f.label).font(.subheadline.bold())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(active ? Theme.accent.opacity(0.18) : Theme.surfaceHigh,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(active ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(building)
    }

    private func targetRow(_ t: ReelTarget) -> some View {
        Button { target = t } label: {
            HStack(spacing: 12) {
                Image(systemName: t.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(target == t ? Theme.onAccent : Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(target == t ? Theme.accent : Theme.surfaceHigh, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(L.s("reel_" + t.rawValue, lang))
                        .font(.subheadline.bold())
                    Text(capLabel(t))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Image(systemName: target == t ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(target == t ? Theme.accent : Color.secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(building)
    }

    /// Says both the cap and whether the current selection actually hits it.
    private func capLabel(_ t: ReelTarget) -> String {
        guard let max = t.maxDuration else { return L.s("reel_nocap", lang) }
        let cap = String(format: L.s("reel_cap_fmt", lang), Int(max))
        return totalSeconds > max ? cap + " · " + fmtDur(max) : cap
    }

    // MARK: - Result

    private func resultView(_ done: (url: URL, plan: ReelPlan)) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                Text(L.s("reel_ready", lang)).font(.headline)
            }

            if let player {
                ZoomableVideo(player: player)
                    .frame(height: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(String(format: L.s("reel_used_fmt", lang),
                             done.plan.used, fmtDur(done.plan.duration)),
                      systemImage: "film")
                    .font(.subheadline.bold())
                if done.plan.trimmed {
                    Label(L.s("reel_trimmed", lang), systemImage: "scissors")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                if done.plan.dropped > 0 {
                    Label(String(format: L.s("reel_dropped_fmt", lang), done.plan.dropped),
                          systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .rcCard()

            VStack(spacing: 10) {
                Button {
                    Task {
                        savedToPhotos = await store.saveToPhotos(done.url)
                        message = savedToPhotos ? L.s("reel_saved", lang)
                                                : L.s("photos_denied", lang)
                    }
                } label: {
                    Label(savedToPhotos ? L.s("reel_saved", lang) : L.s("reel_save", lang),
                          systemImage: savedToPhotos ? "checkmark" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .rcPrimary()

                HStack(spacing: 10) {
                    Button { open("instagram://app", L.s("reel_open_ig", lang)) } label: {
                        Label(L.s("reel_open_ig", lang), systemImage: "camera.aperture")
                            .frame(maxWidth: .infinity)
                    }
                    .rcSecondary()
                    Button { open("youtube://", L.s("reel_open_yt", lang)) } label: {
                        Label(L.s("reel_open_yt", lang), systemImage: "play.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .rcSecondary()
                }

                ShareLink(item: done.url) {
                    Label(L.s("share", lang), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .rcSecondary()
            }
        }
    }

    // MARK: - Actions

    private func build() async {
        building = true
        defer { building = false }
        let pairs = chosen.map { (session: $0.session, clip: $0.clip) }
        guard !pairs.isEmpty,
              let out = await store.buildReel(from: pairs, target: target,
                                              frame: frame, pace: pace,
                                              preset: preset) else {
            message = L.s("source_missing", lang)
            return
        }
        player = AVPlayer(url: out.url)
        done = out
    }

    /// iOS reports whether the target app was there, so a missing app gets a
    /// real message instead of a button that quietly does nothing.
    private func open(_ scheme: String, _ name: String) {
        guard let url = URL(string: scheme) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok { message = name }
        }
    }
}
