import Foundation

/// One of a month's challenges, with how far along it is.
struct Challenge: Identifiable {
    enum Kind: String { case matches, longRallies, beatLongest, playTime }
    let kind: Kind
    var id: String { kind.rawValue }
    let target: Double
    let value: Double
    /// Seconds a rally must last to count, for `.longRallies`.
    var threshold: Double = 0
    /// The rallies behind the number, as the highlights feed keys them
    /// ("<session uuid>/<rally number>"), so the row can play them.
    var rallies: [String] = []

    /// A record is beaten, not matched; everything else is reached.
    var done: Bool { kind == .beatLongest ? value > target : value >= target }
    var fraction: Double { target > 0 ? min(value / target, 1) : 0 }
}

/// The Challenges tab's logic: a few monthly goals drawn from the user's own
/// history, so they are reachable and need no setup.
///
/// Everything is recomputed from the sessions on disk — nothing is stored —
/// so a past month's result is just this function run on that month. Targets
/// come from rally length and match counts, never shot counts: those can be
/// wrong when the next court is audible. Nothing is taken away for a quiet
/// month; there is no streak to break.
enum Challenges {
    static func month(_ sessions: [Session], containing date: Date,
                      cal: Calendar = .current) -> [Challenge] {
        guard let now = cal.dateInterval(of: .month, for: date),
              let prevDay = cal.date(byAdding: .month, value: -1, to: now.start),
              let prev = cal.dateInterval(of: .month, for: prevDay) else { return [] }
        // Same population as the Season tab: matches with rallies, and no
        // 60 s+ blocks — those are several points the detector joined.
        let played = sessions.filter { !($0.segments ?? []).isEmpty }
        func rallies(_ list: [Session]) -> [(id: String, seconds: Double)] {
            list.flatMap { s in
                (s.segments ?? []).enumerated().filter { !$0.element.looksMerged }.map {
                    (s.id.uuidString + "/" + String($0.element.number ?? $0.offset + 1),
                     $0.element.duration)
                }
            }
        }
        let current = played.filter { now.contains($0.playedAt) }
        let last = played.filter { prev.contains($0.playedAt) }
        let earlier = rallies(played.filter { $0.playedAt < now.start })
        let mine = rallies(current)
        var out: [Challenge] = []

        // As many matches as last month, never fewer than two.
        out.append(Challenge(kind: .matches,
                             target: Double(min(max(last.count, 2), 8)),
                             value: Double(current.count)))

        // Long for this player: the top quarter of what they have hit before.
        let lengths = earlier.map(\.seconds).sorted()
        var threshold = 15.0
        if lengths.count >= 20 {
            threshold = min(max((lengths[lengths.count * 3 / 4] / 5).rounded() * 5, 10), 40)
        }
        let long = mine.filter { $0.seconds >= threshold }
        // As many as last month, in fives. A fixed five was over in the first
        // match: a quarter of anyone's rallies clear their own top-quarter bar.
        let lastLong = Double(rallies(last).filter { $0.seconds >= threshold }.count)
        out.append(Challenge(kind: .longRallies,
                             target: min(max((lastLong / 5).rounded(.up) * 5, 5), 50),
                             value: Double(long.count),
                             threshold: threshold, rallies: long.map(\.id)))

        // Only with a record to beat: a first month has nothing to compare to.
        if let best = lengths.last {
            let over = mine.filter { $0.seconds > best }
            out.append(Challenge(kind: .beatLongest, target: best,
                                 value: mine.map(\.seconds).max() ?? 0,
                                 rallies: over.map(\.id)))
        }

        // Minutes of actual rallying, against last month's.
        let lastMinutes = rallies(last).reduce(0) { $0 + $1.seconds } / 60
        out.append(Challenge(kind: .playTime,
                             target: min(max((lastMinutes / 5).rounded(.up) * 5, 10), 120),
                             value: (mine.reduce(0) { $0 + $1.seconds } / 60).rounded(.down),
                             rallies: mine.map(\.id)))
        return out
    }

    #if DEBUG
    /// Assert-based self-check, run once from the Debug launch path.
    static func selfCheck() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        func day(_ s: String) -> Date {
            let f = DateFormatter()
            f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
            return f.date(from: s)!
        }
        func session(_ date: String, _ lengths: [Double]) -> Session {
            var s = Session(id: UUID(), name: "t", createdAt: day(date),
                            duration: 600, width: 1920, height: 1080)
            s.capturedAt = day(date)
            var t = 0.0
            s.segments = lengths.enumerated().map { i, len in
                defer { t += len + 5 }
                return RallySegment(start: t, end: t + len, hits: 4, number: i + 1)
            }
            return s
        }
        let now = day("2026-11-18")
        // First month: no record to beat, floors for the rest.
        let first = month([session("2026-11-03", [16, 8, 70])], containing: now, cal: cal)
        assert(first.map(\.kind) == [.matches, .longRallies, .playTime], "\(first.map(\.kind))")
        assert(first[0].target == 2 && first[0].value == 1 && !first[0].done)
        assert(first[1].value == 1 && first[1].threshold == 15, "70 s block is not a rally")
        assert(first[1].target == 5, "no last month: the floor")
        assert(first[2].target == 10)
        // With an October behind it: three matches to match, 30 s to beat.
        let oct = ["2026-10-05", "2026-10-12", "2026-10-19"].map { session($0, [30, 12]) }
        let nov = [session("2026-11-03", [31, 20]), session("2026-11-10", [9])]
        let second = month(oct + nov, containing: now, cal: cal)
        assert(second[0].target == 3 && second[0].value == 2)
        // Seven 16 s rallies last month → ten to reach, not five.
        let busy = month([session("2026-10-05", Array(repeating: 16, count: 7))] + nov,
                         containing: now, cal: cal)
        assert(busy[1].target == 10 && busy[1].value == 2, "\(busy[1].target)")
        let beat = second.first { $0.kind == .beatLongest }
        assert(beat?.target == 30 && beat?.done == true && beat?.rallies.count == 1)
        // Matching the record is not beating it.
        let tie = month(oct + [session("2026-11-03", [30])], containing: now, cal: cal)
        assert(tie.first { $0.kind == .beatLongest }?.done == false)
    }
    #endif
}
