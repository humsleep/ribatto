import Foundation

/// Turns a sequence of point winners into the score line each rally ended on.
///
/// Why the app asks rather than infers: serve order, lets and untagged points
/// all break any guess made from audio alone, and a scoreboard that is wrong
/// once is worse than no scoreboard at all. The user taps a winner per rally;
/// this only does the arithmetic.
///
/// Racket sports do not share one rulebook, so the shape of a "game" comes from
/// the sport: tennis and padel score 15/30/40 with games and sets, badminton and
/// pickleball are straight rally-point races. Untagged rallies are skipped and
/// leave the running score where it was.
enum TennisScore {
    /// The score to show on each rally, in the same order as `segments`.
    /// A rally with no winner tagged yet gets nil.
    static func line(for segments: [RallySegment],
                     sport: Sport = .tennis, lang: String = "en") -> [String] {
        sport.usesGameScoring ? classic(segments, lang)
                              : race(segments, to: sport.raceTo, lang)
    }

    // MARK: - 15/30/40

    private static let calls = ["0", "15", "30", "40"]

    private static func classic(_ segments: [RallySegment], _ lang: String) -> [String] {
        var pts = [0, 0]          // points in the current game
        var games = [0, 0]
        var sets = [0, 0]
        var out: [String] = []

        for seg in segments {
            guard let w = seg.winner else { out.append(""); continue }
            let i = w == .me ? 0 : 1, j = 1 - i
            pts[i] += 1
            // deuce/advantage, then the game
            if pts[i] >= 4 && pts[i] - pts[j] >= 2 {
                games[i] += 1
                pts = [0, 0]
                // 6 games with two clear, or 7 either way after a tiebreak
                if (games[i] >= 6 && games[i] - games[j] >= 2) || games[i] == 7 {
                    sets[i] += 1
                    games = [0, 0]
                }
            }
            out.append(text(pts: pts, games: games, sets: sets, lang))
        }
        return out
    }

    /// Reads the way a player would say it: "15–0" at the start of a match,
    /// not "0–0 · 15–0". A 0–0 component is dropped unless it is the only
    /// thing there is to say.
    private static func text(pts: [Int], games: [Int], sets: [Int], _ lang: String) -> String {
        var parts: [String] = []
        if sets[0] > 0 || sets[1] > 0 {
            parts.append("\(sets[0])–\(sets[1]) " + L.s("sc_sets", lang))
        }
        let point = gameText(pts, lang)
        if games != [0, 0] || (parts.isEmpty && point == nil) {
            parts.append("\(games[0])–\(games[1])")
        }
        if let point { parts.append(point) }
        return parts.joined(separator: " · ")
    }

    /// nil at the start of a game, where "0-0" adds nothing to the games line.
    private static func gameText(_ pts: [Int], _ lang: String) -> String? {
        if pts == [0, 0] { return nil }
        if pts[0] >= 3 && pts[1] >= 3 {
            if pts[0] == pts[1] { return L.s("sc_deuce", lang) }
            return L.s(pts[0] > pts[1] ? "sc_ad_in" : "sc_ad_out", lang)
        }
        return "\(calls[min(pts[0], 3)])–\(calls[min(pts[1], 3)])"
    }

    // MARK: - Rally point

    private static func race(_ segments: [RallySegment], to target: Int,
                             _ lang: String) -> [String] {
        var pts = [0, 0]
        var games = [0, 0]
        var out: [String] = []
        for seg in segments {
            guard let w = seg.winner else { out.append(""); continue }
            let i = w == .me ? 0 : 1, j = 1 - i
            pts[i] += 1
            if pts[i] >= target && pts[i] - pts[j] >= 2 {
                games[i] += 1
                pts = [0, 0]
            }
            // Same rule as the classic scoreline: a fresh 0–0 after a game is
            // won says nothing the games line hasn't already said.
            var parts: [String] = []
            if games != [0, 0] {
                parts.append("\(games[0])–\(games[1]) " + L.s("sc_games", lang))
            }
            if pts != [0, 0] || parts.isEmpty {
                parts.append("\(pts[0])–\(pts[1])")
            }
            out.append(parts.joined(separator: " · "))
        }
        return out
    }

    /// Where the match stands after every tagged point, for the session header.
    static func summary(for segments: [RallySegment], sport: Sport = .tennis,
                        lang: String = "en") -> String? {
        line(for: segments, sport: sport, lang: lang).last { !$0.isEmpty }
    }

    /// Points won by each side, for the stats screen.
    static func record(_ segments: [RallySegment]) -> (me: Int, them: Int) {
        (segments.filter { $0.winner == .me }.count,
         segments.filter { $0.winner == .them }.count)
    }
}

extension Sport {
    /// Tennis and padel run 15/30/40 games and sets; badminton and pickleball
    /// are rally-point races.
    var usesGameScoring: Bool { self == .tennis || self == .padel }
    /// Points that take a game in the rally-point sports.
    var raceTo: Int { self == .badminton ? 21 : 11 }
}
