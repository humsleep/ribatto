import SwiftUI

/// The fourth tab: this month's challenges, drawn from the user's own matches.
///
/// It gives the next match something to chase and the match after it
/// something to check — the two moments a once-a-week app gets opened.
/// A row plays the rallies behind its number in the highlights feed.
struct ChallengesView: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    var openLibrary: () -> Void = {}

    @State private var feed: Feed?
    @State private var path: [UUID] = []
    /// Re-read on appear so the month does not go stale on a tab left open.
    @State private var now = Date()

    private struct Feed: Identifiable {
        let id = UUID()
        let only: Set<String>?
    }

    private var locale: Locale { L.locale(lang) }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                TabHeader(title: L.s("ch_tab", lang))
                if store.sessions.allSatisfy({ ($0.segments ?? []).isEmpty }) {
                    EmptyStateBox {
                        VStack(spacing: 10) {
                            Image(systemName: "target")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(Theme.secondaryText)
                            Text(L.s("ch_empty", lang))
                                .font(.subheadline).foregroundStyle(Theme.secondaryText)
                                .multilineTextAlignment(.center)
                            Button(action: openLibrary) {
                                Label(L.s("library", lang), systemImage: "rectangle.stack")
                            }
                            .rcPrimary()
                            .padding(.top, 6)
                        }
                        .padding(32)
                    }
                } else {
                    content
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(Theme.background.ignoresSafeArea())
            .adBanner()
            .navigationDestination(for: UUID.self) { SessionDetailView(sessionID: $0) }
        }
        .onAppear { now = Date() }
        .fullScreenCover(item: $feed) { f in
            HighlightsView(only: f.only, onClose: { feed = nil },
                           openMatch: { feed = nil; path = [$0] })
                .tint(Theme.primaryText)
        }
    }

    private var content: some View {
        let list = Challenges.month(store.sessions, containing: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary(list)
                ForEach(list) { row($0) }
                Button { feed = Feed(only: nil) } label: {
                    Label(L.s("hl_tab", lang), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .rcSecondary()
                past
            }
            .padding(.horizontal, 16)
            // The tab bar floats over the end of the list.
            .padding(.bottom, 62)
        }
    }

    private func summary(_ list: [Challenge]) -> some View {
        let cal = Calendar.current
        let end = cal.dateInterval(of: .month, for: now)?.end ?? now
        let left = (cal.dateComponents([.day], from: cal.startOfDay(for: now), to: end).day ?? 1)
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(format: L.s("ch_month_fmt", lang), monthName(now)))
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            Text(String(format: L.s("ch_done_fmt", lang), list.filter(\.done).count, list.count))
                .font(.system(.largeTitle, weight: .heavy).width(.compressed).monospacedDigit())
            Text(left <= 1 ? L.s("ch_last_day", lang)
                           : String(format: L.s("ch_days_left_fmt", lang), left))
                .font(.footnote).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func row(_ c: Challenge) -> some View {
        let playable = !c.rallies.isEmpty
        return Button {
            feed = Feed(only: Set(c.rallies))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title(c)).font(.body.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if c.done {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.primaryText)
                            .accessibilityHidden(true)
                    }
                }
                ProgressView(value: c.done ? 1 : c.fraction)
                    .tint(Theme.court)
                    .accessibilityHidden(true)
                HStack {
                    Text(progress(c))
                        .font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    if playable {
                        Image(systemName: "play.fill")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        // Not `.disabled`: that greys the whole card, and a challenge with
        // nothing to play yet is not an unavailable one.
        .allowsHitTesting(playable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(c.done ? .isSelected : [])
    }

    /// The last three months with a challenge reached: "October · 3 / 4".
    @ViewBuilder private var past: some View {
        let cal = Calendar.current
        let months = (1...6).compactMap { cal.date(byAdding: .month, value: -$0, to: now) }
            .map { ($0, Challenges.month(store.sessions, containing: $0)) }
            // Only months with something reached: "0 / 3" is a scolding.
            .filter { $0.1.contains(where: \.done) }
            .prefix(3)
        if !months.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L.s("ch_past", lang))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                ForEach(Array(months), id: \.0) { month, list in
                    HStack {
                        Text(monthName(month))
                        Spacer()
                        Text(String(format: L.s("ch_done_fmt", lang),
                                    list.filter(\.done).count, list.count))
                            .monospacedDigit().foregroundStyle(Theme.secondaryText)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: Text

    private func monthName(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).locale(locale))
    }

    private func title(_ c: Challenge) -> String {
        switch c.kind {
        case .matches: String(format: L.s("ch_matches_fmt", lang), Int(c.target))
        case .longRallies: String(format: L.s("ch_long_fmt", lang), Int(c.target), Int(c.threshold))
        case .beatLongest: String(format: L.s("ch_beat_fmt", lang), fmtLen(c.target, lang))
        case .playTime: String(format: L.s("ch_play_fmt", lang), Int(c.target))
        }
    }

    private func progress(_ c: Challenge) -> String {
        switch c.kind {
        // A length against a length: "38 s" is this month's longest so far.
        case .beatLongest: c.value > 0 ? fmtLen(c.value, lang) : "–"
        default: "\(Int(c.value)) / \(Int(c.target))"
        }
    }
}
