import SwiftUI

/// One ordering shared by every clip list in the app. `time` is the only mode
/// that needs context a clip alone doesn't carry (its session's date), so each
/// list handles that case itself and delegates the rest to `precedes`.
enum ClipSort: CaseIterable {
    case time, best, long, short, hitsMany, hitsFew, cheer, favourite

    var key: String {
        switch self {
        case .time: return "sort_time"
        case .best: return "sort_best"
        case .long: return "sort_long"
        case .short: return "sort_short"
        case .hitsMany: return "sort_hits_many"
        case .hitsFew: return "sort_hits_few"
        case .cheer: return "sort_cheer"
        case .favourite: return "sort_fav"
        }
    }

    /// Unscored clips (detected before scoring existed) sort last rather than
    /// mixing in at zero, so an old session doesn't look bad.
    func precedes(_ a: ClipInfo, _ b: ClipInfo) -> Bool {
        switch self {
        case .time: return a.index < b.index
        case .best: return (a.segment.score ?? -1) > (b.segment.score ?? -1)
        case .long: return a.duration > b.duration
        case .short: return a.duration < b.duration
        case .hitsMany: return a.segment.hits > b.segment.hits
        case .hitsFew: return a.segment.hits < b.segment.hits
        case .cheer: return (a.segment.cheer ?? -1) > (b.segment.cheer ?? -1)
        // Starred first, then newest-detected order inside each group.
        case .favourite:
            if a.segment.isFavourite != b.segment.isFavourite { return a.segment.isFavourite }
            return a.index < b.index
        }
    }
}

/// Six orderings no longer fit a segmented control, so this is a menu: a pill
/// showing the current order that opens a checklist.
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
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .chip(active: false)
        }
        .tint(.primary)
    }
}
