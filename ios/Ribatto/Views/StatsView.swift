import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Everything the app knows about how much you've played, derived from the
/// sessions already on disk.
struct SeasonStats {
    var matches = 0
    var rallies = 0
    var totalSeconds = 0.0
    var shots = 0
    var longest: (seconds: Double, date: Date)?
    var busiest: (rallies: Int, date: Date)?
    var monthMatches = 0
    var monthRallies = 0
    /// All-time shots per rally — this is a personal record, not a monthly one.
    var avgShots = 0.0
    /// Month-over-month comparison, kept apart from the record above.
    var monthAvgShots = 0.0
    var prevAvgShots = 0.0
    var monthSeconds = 0.0
    /// Courts played at, most visited first.
    var places: [(name: String, visits: Int, rallies: Int)] = []
    /// Rallies per month, oldest first, always 6 entries.
    var monthly: [(month: Date, rallies: Int, matches: Int)] = []
    /// Points won and lost against each named opponent, most played first.
    /// Only sessions where points were actually tagged appear.
    var opponents: [(name: String, won: Int, lost: Int, matches: Int)] = []
    /// Strikes per minute of play, all time.
    var tempo: Double = 0

    /// Only meaningful when both months actually have rallies; otherwise a
    /// quiet month reads as a collapse in form.
    var avgTrend: Double {
        (prevAvgShots > 0 && monthAvgShots > 0) ? monthAvgShots - prevAvgShots : 0
    }
}

struct StatsView: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var shareURL: URL?
    @State private var building = false

    private var stats: SeasonStats { Self.compute(store: store) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            TabHeader(title: L.s("season", lang))
            Group {
                if store.sessions.isEmpty {
                    EmptyStateBox {
                        VStack(spacing: 10) {
                            Image(systemName: "chart.bar")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.secondary)
                            Text(L.s("stats_empty", lang))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(32)
                    }
                } else {
                    content
                }
            }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var content: some View {
        let s = stats
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                card {
                    Text(L.s("this_month", lang)).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 22) {
                        big(String(s.monthMatches), L.s("matches", lang))
                        big(String(s.monthRallies), L.s("rallies", lang))
                        big(fmtDur(s.monthSeconds), L.s("total", lang))
                    }
                }

                card {
                    Text(L.s("activity", lang)).font(.caption).foregroundStyle(.secondary)
                    activityChart(s)
                }

                if let l = s.longest {
                    card {
                        Text(L.s("records", lang)).font(.caption).foregroundStyle(.secondary)
                        record("flame.fill", L.s("rec_longest", lang),
                               String(Int(l.seconds)) + L.s("sec", lang),
                               L.dateOnly(l.date, lang))
                        if let b = s.busiest {
                            record("chart.bar.fill", L.s("rec_busiest", lang),
                                   String(b.rallies), L.dateOnly(b.date, lang))
                        }
                        // The trend compares this month with last, so the
                        // figure beside it has to be this month's too. Pairing
                        // it with the all-time average read as the record
                        // itself having moved.
                        record("figure.tennis", L.s("rec_avg", lang),
                               String(format: "%.1f", s.monthAvgShots > 0 ? s.monthAvgShots
                                                                          : s.avgShots),
                               s.avgTrend == 0 ? "" :
                                   String(format: "%@%.1f", s.avgTrend > 0 ? "+" : "", s.avgTrend))
                    }
                }

                // Head-to-head only appears once points have been tagged; an
                // empty card would read as a broken feature.
                if !s.opponents.isEmpty {
                    card {
                        Text(L.s("opponent", lang)).font(.caption).foregroundStyle(.secondary)
                        ForEach(s.opponents.prefix(6), id: \.name) { o in
                            // Same treatment as the record rows: side by side,
                            // the score wrapped to "4– / 0 / poi / nts" and took
                            // the width the name needed, leaving "Cl…" — and
                            // pinning the score to one line squeezed the name
                            // out entirely.
                            statRow(icon: "person.2.fill", name: o.name) {
                                Text(String(format: L.s("record_fmt", lang), o.won, o.lost))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(String(format: L.s(o.matches == 1 ? "matches_one" : "matches_n", lang), o.matches))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                            }
                        }
                    }
                }

                if !s.places.isEmpty {
                    card {
                        Text(L.s("courts", lang)).font(.caption).foregroundStyle(.secondary)
                        ForEach(s.places.prefix(6), id: \.name) { place in
                            statRow(icon: "mappin.and.ellipse", name: place.name) {
                                Text(String(format: L.s(place.visits == 1 ? "visits_one" : "visits_fmt", lang), place.visits))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                card {
                    Text(L.s("all_time", lang)).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 22) {
                        big(String(s.matches), L.s("matches", lang))
                        big(String(s.rallies), L.s("rallies", lang))
                        big(String(s.shots), L.s("shots", lang))
                        if s.tempo > 0 {
                            big(String(Int(s.tempo.rounded())), L.s("tempo", lang))
                        }
                    }
                }

                Button {
                    Task { await makeCard(s) }
                } label: {
                    HStack {
                        if building { ProgressView().controlSize(.small) }
                        Label(L.s("share_card", lang), systemImage: "square.and.arrow.up")
                            .font(.subheadline.bold())
                    }
                    .frame(maxWidth: .infinity, minHeight: 26)
                }
                .rcPrimary()
                .disabled(building)
            }
            .padding()
            .padding(.bottom, 62)     // clear the floating tab bar
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) },
                             set: { if $0 == nil { shareURL = nil } })) { item in
            ShareSheet(url: item.url)
        }
    }

    // MARK: - Pieces

    /// Six-month rally count, the fitness-app "am I playing enough?" glance.
    private func activityChart(_ s: SeasonStats) -> some View {
        let current = Calendar.current.startOfMonth(for: Date())
        return Chart(s.monthly, id: \.month) { entry in
            BarMark(
                x: .value("month", monthLabel(entry.month)),
                y: .value("rallies", entry.rallies)
            )
            .foregroundStyle(entry.month == current ? Theme.accent : Theme.surfaceHigh)
            .cornerRadius(5)
            .annotation(position: .top, spacing: 4) {
                if entry.rallies > 0 {
                    Text(String(entry.rallies))
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(entry.month == current ? .primary : .secondary)
                }
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.caption2).foregroundStyle(Color.secondary)
            }
        }
        // Axis labels are chrome sized to the bars beneath them. Left to scale
        // they merged into one run and no longer sat under their own bar.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .frame(height: 130)
        .padding(.top, 4)
    }

    private func monthLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L.locale(lang)
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f.string(from: date)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: 14))
    }

    private func big(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A name on the left and a value on the right, stacked once the text is
    /// big enough that they would fight for the same width.
    @ViewBuilder
    private func statRow<V: View>(icon: String, name: String,
                                  @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            // The glyph scales with Dynamic Type but its column does not, so at
            // accessibility sizes it drew well outside the 22pt frame and over
            // the label beside it. It is decorative, so it is capped rather
            // than given the width it asks for.
            Image(systemName: icon).foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(width: 22)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    // Vertical too: side by side the score itself truncated
                    // once the name had the width it needed.
                    VStack(alignment: .leading, spacing: 2) { value() }
                }
                Spacer(minLength: 0)
            } else {
                Text(name).font(.subheadline).lineLimit(1)
                Spacer(minLength: 8)
                value()
            }
        }
    }

    private func record(_ icon: String, _ title: String,
                        _ value: String, _ sub: String) -> some View {
        // At accessibility sizes the label wraps to several lines and the row
        // stacks: side by side the icon ended up drawn over the second line and
        // the value column took the width the name needed.
        let stacked = typeSize.isAccessibilitySize
        return HStack(alignment: stacked ? .top : .center, spacing: 11) {
            // The glyph scales with Dynamic Type but its column does not, so at
            // accessibility sizes it drew well outside the 22pt frame and over
            // the label beside it. It is decorative, so it is capped rather
            // than given the width it asks for.
            Image(systemName: icon).foregroundStyle(.tint)
                .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(width: 22)
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline)
                    HStack(spacing: 8) {
                        Text(value).font(.subheadline.bold().monospacedDigit())
                        if !sub.isEmpty {
                            Text(sub).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            } else {
                Text(title).font(.subheadline)
                Spacer(minLength: 8)
                Text(value).font(.subheadline.bold().monospacedDigit())
                if !sub.isEmpty {
                    Text(sub).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Instagram-ready card

    @MainActor
    private func makeCard(_ s: SeasonStats) async {
        building = true
        defer { building = false }
        // the newest match's poster becomes the backdrop — the card is about
        // the user's own season, so it should look like it
        let poster = store.sessions.first.flatMap {
            PosterCache.load(store.posterURL($0))
        }
        let renderer = ImageRenderer(
            content: ShareCard(stats: s, lang: lang, poster: poster))
        renderer.scale = 1   // the card is already 1080x1350 points
        guard let img = renderer.uiImage,
              let data = img.pngData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ribatto-season.png")
        // A fixed path plus a swallowed failure meant a full disk shared last
        // month's card as this month's.
        guard (try? data.write(to: url)) != nil else { return }
        shareURL = url
    }
}

/// 4:5 card — the aspect Instagram feed posts keep at full size.
/// Mirrors every section of the Season screen so the shared image matches
/// what the user is looking at.
private struct ShareCard: View {
    let stats: SeasonStats
    let lang: String
    var poster: UIImage? = nil

    private let accent = Theme.accent
    private let lime = Color(red: 0.84, green: 0.93, blue: 0.42)
    private var dim: Color { .white.opacity(0.55) }
    /// Letter-spacing looks right on Latin but breaks Korean/Japanese words.
    private var isLatin: Bool { lang == "en" }
    private func track(_ v: CGFloat) -> CGFloat { isLatin ? v : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 24)
            hero
            Spacer().frame(height: 46)
            monthRow
            if stats.longest != nil {
                Spacer().frame(height: 22)
                records
            }
            Spacer(minLength: 24)
            footer
        }
        .padding(64)
        .frame(width: 1080, height: 1350)
        .background(background)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            mark
            Text("RIBATTO")
                .font(.system(size: 25, weight: .black, design: .rounded))
                .tracking(3)
            Spacer()
            Text(L.dateOnly(Date(), lang))
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(dim)
        }
    }

    /// The app mark: a ball with its rally trail.
    private var mark: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .trim(from: 0.30, to: 0.70)
                    .stroke(accent.opacity(0.95 - Double(i) * 0.32),
                            style: StrokeStyle(lineWidth: 5 - CGFloat(i), lineCap: .round))
                    .frame(width: 34 + CGFloat(i) * 15, height: 34 + CGFloat(i) * 15)
            }
            Circle()
                .fill(LinearGradient(colors: [.white, lime],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
                .offset(x: 5)
        }
        .frame(width: 66, height: 66)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.s("this_month", lang).uppercased())
                .font(.system(size: 22, weight: .heavy))
                .tracking(track(5))
                .foregroundStyle(accent)
            Text(String(stats.monthRallies))
                .font(.system(size: 176, weight: .black, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
                .foregroundStyle(
                    LinearGradient(colors: [.white, lime],
                                   startPoint: .top, endPoint: .bottom))
            Text(L.s("rallies", lang).uppercased())
                .font(.system(size: 30, weight: .heavy))
                .tracking(track(6))
                .foregroundStyle(dim)
        }
    }

    private var monthRow: some View {
        HStack(spacing: 14) {
            pill(String(stats.monthMatches), L.s("matches", lang))
            // This row sits under the THIS MONTH heading; the all-time total
            // here told everyone who saw the card that a 40-minute month was
            // thirty hours.
            pill(fmtDur(stats.monthSeconds), L.s("total", lang))
            if let l = stats.longest {
                pill(String(Int(l.seconds)) + L.s("sec", lang), L.s("longest", lang))
            }
        }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.s("records", lang).uppercased())
                .font(.system(size: 19, weight: .heavy))
                .tracking(track(4))
                .foregroundStyle(dim)
            if let l = stats.longest {
                line("flame.fill", L.s("rec_longest", lang),
                     String(Int(l.seconds)) + L.s("sec", lang))
            }
            if let b = stats.busiest {
                line("chart.bar.fill", L.s("rec_busiest", lang), String(b.rallies))
            }
            line("figure.tennis", L.s("rec_avg", lang),
                 String(format: "%.1f", stats.avgShots),
                 trend: stats.avgTrend)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26)
            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var footer: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.s("all_time", lang).uppercased())
                    .font(.system(size: 17, weight: .heavy))
                    .tracking(track(3))
                    .foregroundStyle(dim)
                Text("\(String(stats.matches)) \(L.s("matches", lang))  ·  "
                     + "\(String(stats.rallies)) \(L.s("rallies", lang))  ·  "
                     + "\(String(stats.shots)) \(L.s("shots", lang))")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
            }
            Spacer()
            Text("ribatto.app")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.30))
        }
    }

    // MARK: - Pieces

    private func pill(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 46, weight: .black, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(dim)
                .lineLimit(1)
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 22))
    }

    private func line(_ icon: String, _ title: String, _ value: String,
                      trend: Double = 0) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(accent)
                .frame(width: 34)
            Text(title).font(.system(size: 26, weight: .medium))
            Spacer()
            if trend != 0 {
                Text(String(format: "%@%.1f", trend > 0 ? "+" : "", trend))
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(trend > 0 ? accent : .orange)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background((trend > 0 ? accent : .orange).opacity(0.15),
                                in: Capsule())
            }
            Text(value)
                .font(.system(size: 32, weight: .black, design: .rounded))
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.14, blue: 0.11),
                                    Color(red: 0.02, green: 0.04, blue: 0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1080, height: 1350)
                    .blur(radius: 9)
                    .opacity(0.55)
                    .clipped()
                // scrim: keeps the photo readable underneath the numbers
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.55), location: 0.00),
                    .init(color: .black.opacity(0.30), location: 0.30),
                    .init(color: .black.opacity(0.78), location: 0.72),
                    .init(color: .black.opacity(0.92), location: 1.00),
                ], startPoint: .top, endPoint: .bottom)
            }

            RadialGradient(colors: [accent.opacity(poster == nil ? 0.30 : 0.18), .clear],
                           center: .init(x: 0.16, y: 0.30),
                           startRadius: 20, endRadius: 760)
            RadialGradient(colors: [lime.opacity(0.12), .clear],
                           center: .init(x: 0.95, y: 0.92),
                           startRadius: 20, endRadius: 620)
        }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Aggregation

extension StatsView {
    static func compute(store: SessionStore) -> SeasonStats {
        var s = SeasonStats()
        let cal = Calendar.current
        let now = Date()
        var monthShots = 0, monthRallyCount = 0
        var prevShots = 0, prevRallyCount = 0

        // value carries the first-seen spelling, so the row still reads the way
        // the user typed it
        var opponentTotals: [String: (won: Int, lost: Int, matches: Int, name: String)] = [:]
        var tempoSum = 0.0, tempoCount = 0

        for session in store.sessions {
            let clips = store.clips(of: session)
            guard !clips.isEmpty else { continue }
            for t in clips.compactMap(\.segment.tempo) {
                tempoSum += t; tempoCount += 1
            }
            if let name = session.opponent, session.taggedPoints > 0 {
                // Keyed case-insensitively: iOS autocapitalises the first
                // typing and a later paste often does not, which split one
                // person's head-to-head into two half-records.
                let key = name.lowercased()
                let r = TennisScore.record(session.segments ?? [])
                var entry = opponentTotals[key] ?? (0, 0, 0, name)
                entry.won += r.me; entry.lost += r.them; entry.matches += 1
                opponentTotals[key] = entry
            }
            s.matches += 1
            s.rallies += clips.count
            let secs = clips.reduce(0) { $0 + $1.duration }
            let hits = clips.reduce(0) { $0 + $1.segment.hits }
            s.totalSeconds += secs
            s.shots += hits

            if let longest = clips.map(\.duration).max(),
               longest > (s.longest?.seconds ?? 0) {
                s.longest = (longest, session.playedAt)
            }
            if clips.count > (s.busiest?.rallies ?? 0) {
                s.busiest = (clips.count, session.playedAt)
            }

            if cal.isDate(session.playedAt, equalTo: now, toGranularity: .month) {
                s.monthMatches += 1
                s.monthRallies += clips.count
                s.monthSeconds += secs
                monthShots += hits
                monthRallyCount += clips.count
            } else if let prev = cal.date(byAdding: .month, value: -1, to: now),
                      cal.isDate(session.playedAt, equalTo: prev, toGranularity: .month) {
                prevShots += hits
                prevRallyCount += clips.count
            }
        }
        // last six months of activity, zero-filled so the chart keeps its shape
        let months: [Date] = (0..<6).reversed().compactMap {
            cal.date(byAdding: .month, value: -$0, to: cal.startOfMonth(for: now))
        }
        var tally: [Date: (rallies: Int, matches: Int)] = [:]
        for session in store.sessions {
            let key = cal.startOfMonth(for: session.playedAt)
            let clips = store.clips(of: session).count
            guard clips > 0 else { continue }
            let cur = tally[key] ?? (0, 0)
            tally[key] = (cur.rallies + clips, cur.matches + 1)
        }
        s.monthly = months.map {
            let t = tally[$0] ?? (0, 0)
            return (month: $0, rallies: t.rallies, matches: t.matches)
        }

        // where the season was played
        var byPlace: [String: (visits: Int, rallies: Int)] = [:]
        for session in store.sessions {
            guard let place = session.placeName else { continue }
            let clips = store.clips(of: session).count
            guard clips > 0 else { continue }
            let current = byPlace[place] ?? (0, 0)
            byPlace[place] = (current.visits + 1, current.rallies + clips)
        }
        s.places = byPlace
            .map { (name: $0.key, visits: $0.value.visits, rallies: $0.value.rallies) }
            .sorted { ($0.visits, $0.rallies) > ($1.visits, $1.rallies) }

        s.avgShots = s.rallies > 0 ? Double(s.shots) / Double(s.rallies) : 0
        s.monthAvgShots = monthRallyCount > 0 ? Double(monthShots) / Double(monthRallyCount) : 0
        s.prevAvgShots = prevRallyCount > 0 ? Double(prevShots) / Double(prevRallyCount) : 0
        s.tempo = tempoCount > 0 ? tempoSum / Double(tempoCount) : 0
        s.opponents = opponentTotals
            .map { (name: $0.value.name, won: $0.value.won, lost: $0.value.lost,
                    matches: $0.value.matches) }
            .sorted { $0.matches > $1.matches }
        return s
    }
}


private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
}
