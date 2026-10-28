import SwiftUI

/// One page: what the app does, which sport, start. Three swipe pages used to
/// explain the detector before the user had seen a single clip; the sport is
/// the one thing the first detection actually needs.
struct OnboardingView: View {
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var store: SessionStore
    @Binding var done: Bool
    /// Mirrors `store.lastSport`, which is a plain UserDefaults read and does
    /// not redraw the chips on its own.
    @State private var sport: Sport?

    /// Tennis first: most users play it. Not `Sport.allCases`, whose order is
    /// the detector's.
    private let sports: [Sport] = [.tennis, .pickleball, .padel, .badminton]

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10),
              count: typeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                languageMenu
                Spacer()
            }
            // Chrome. Unbounded, "한국어" broke into two lines on a 4.7" screen.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // Scrollable: at the largest text size the fixed layout cut the
            // headline off mid-word — on the first screen a new user sees.
            ScrollView {
                VStack(spacing: 16) {
                    Spacer(minLength: 12)
                    Image("AppLogo")
                        .resizable()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)
                    Text(L.s("ob1_t", lang))
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L.s("ob1_d", lang))
                        .font(.body)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)

                    Text(L.s("ask_sport_title", lang))
                        .font(.headline)
                        .padding(.top, 20)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(sports) { sp in
                            Button {
                                sport = sp
                                store.lastSport = sp
                            } label: {
                                Text("\(sp.emoji) \(L.s(sp.rawValue, lang))")
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, minHeight: 28)
                                    .chip(active: sport == sp)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(sport == sp ? .isSelected : [])
                        }
                    }
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            }

            // No sport picked is fine: the library asks before the first
            // import, as it does for anyone who skipped this page before.
            Button { done = true } label: {
                Text(L.s("get_started", lang))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .rcPrimary()
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { sport = store.lastSport }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(L.languages, id: \.code) { l in
                Button {
                    lang = l.code
                } label: {
                    if lang == l.code { Label(l.label, systemImage: "checkmark") }
                    else { Text(l.label) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                Text(L.languages.first { $0.code == lang }?.label ?? "English")
                    .font(.footnote)
                    .lineLimit(1)
            }
            .tint(.secondary)
        }
    }
}
