import Foundation

/// Placeholders a caption can carry, filled in per clip from what the detector
/// found — one caption that reads differently on every rally, instead of the
/// user typing fourteen of them before posting.
enum CaptionText {
    static let tokens = ["{rank}", "{shots}", "{tempo}", "{duration}",
                         "{rally}", "{place}", "{date}", "{sport}"]
    /// Tokens the app no longer fills. A caption saved while they existed still
    /// carries them, and left in place they would burn in as literal braces.
    private static let retired = ["{score}", "{opponent}"]
    static let example = "{rank} · {shots} · {place}"

    /// L10n key for the chip that inserts a token.
    static func labelKey(_ token: String) -> String {
        "tok_" + token.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    }

    static func hasTokens(_ text: String) -> Bool {
        (tokens + retired).contains { text.contains($0) }
    }

    static func removing(_ token: String, from text: String) -> String {
        tidy(text.replacingOccurrences(of: token, with: ""))
    }

    static func adding(_ token: String, to text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? token : t + " · " + token
    }

    /// The caption as it should be burned into clip `index`. Captions without
    /// tokens pass through untouched. A caption that resolves to nothing (only
    /// `{place}` on a session with no court name) is switched off rather than
    /// drawn as an empty pill.
    static func resolve(_ caption: CaptionSettings?, session: Session,
                        segments: [RallySegment], index: Int, lang: String) -> CaptionSettings? {
        guard var c = caption, c.enabled, hasTokens(c.text) else { return caption }
        // A clip index can outrun a freshly re-detected session. Returning the
        // caption unresolved would burn the literal "{rank} · {shots}" into the
        // video, so the caption is dropped instead.
        guard index < segments.count else {
            c.enabled = false
            return c
        }
        let seg = segments[index]
        var out = c.text
        func put(_ token: String, _ value: String) {
            out = out.replacingOccurrences(of: token, with: value)
        }
        put("{shots}", String(format: L.s("tok_shots_fmt", lang), seg.hits))
        for token in retired { put(token, "") }
        put("{tempo}", seg.tempo.map {
            String(format: L.s("tempo_fmt", lang), Int($0.rounded())) } ?? "")
        put("{duration}", String(format: L.s("tok_duration_fmt", lang), Int(seg.duration.rounded())))
        put("{rally}", String(format: L.s("tok_rally_fmt", lang), index + 1))
        put("{rank}", rank(in: segments, index).map {
            String(format: L.s("tok_rank_fmt", lang), $0) } ?? "")
        put("{place}", session.placeName ?? "")
        put("{date}", L.dateOnly(session.playedAt, lang))
        put("{sport}", L.s(session.sport.rawValue, lang))
        c.text = tidy(out)
        if c.text.isEmpty { c.enabled = false }
        return c
    }

    /// 1-based place by score; nil for rallies detected before scoring existed.
    static func rank(in segments: [RallySegment], _ index: Int) -> Int? {
        guard segments[index].score != nil else { return nil }
        let order = segments.indices.sorted {
            (segments[$0].score ?? -1) > (segments[$1].score ?? -1)
        }
        return (order.firstIndex(of: index) ?? index) + 1
    }

    /// Drops empty pieces and the doubled separators an empty value leaves.
    static func tidy(_ text: String) -> String {
        text.split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
