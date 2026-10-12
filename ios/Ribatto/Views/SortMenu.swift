import SwiftUI

/// How the session screen orders its clips. `time` is the clips' own order
/// there, so that screen skips sorting for it; the others go through
/// `precedes`. `best` also picks the hero and the highlight reel.
///
/// Three orders, down from eight: longest/shortest, most/fewest shots and
/// loudest crowd were each a guess at "the good ones", which `best` already
/// scores from all of them — and shot counts are the number CLAUDE.md calls
/// unreliable. Nothing persists the choice, so no stored value needs mapping.
enum ClipSort: String, CaseIterable {
    case best, time, favourite

    var key: String {
        switch self {
        case .time: return "sort_time"
        case .best: return "sort_best"
        case .favourite: return "sort_fav"
        }
    }

    /// Unscored clips (detected before scoring existed) sort last rather than
    /// mixing in at zero, so an old session doesn't look bad.
    func precedes(_ a: ClipInfo, _ b: ClipInfo) -> Bool {
        switch self {
        case .time: return a.index < b.index
        case .best: return (a.segment.score ?? -1) > (b.segment.score ?? -1)
        // Starred first, then newest-detected order inside each group.
        case .favourite:
            if a.segment.isFavourite != b.segment.isFavourite { return a.segment.isFavourite }
            return a.index < b.index
        }
    }
}

/// A pill showing the current order that opens a checklist. Kept a menu at
/// three: a segmented control of "Best · Timeline · Starred" breaks in German.
struct SortMenu: View {
    @Binding var sort: ClipSort
    @AppStorage("rc_lang") private var lang = "en"

    var body: some View {
        Menu {
            Picker(L.s("sort", lang), selection: $sort) {
                ForEach(ClipSort.allCases, id: \.self) { s in
                    Text(L.s(s.key, lang)).tag(s)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption.weight(.bold))
                Text(L.s(sort.key, lang))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            // A pill in a toolbar row cannot grow without bound: at the largest
            // accessibility size it became one letter per line, swallowed the
            // header and pushed the grid off screen.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .chip(active: false)
        }
        .tint(.primary)
    }
}
