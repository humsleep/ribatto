import SwiftUI

struct OnboardingView: View {
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var done: Bool
    @State private var page = 0

    private let accent = Theme.accent

    private var pages: [(symbol: String, title: String, body: String)] {
        [("sportscourt", L.s("ob1_t", lang), L.s("ob1_d", lang)),
         ("waveform", L.s("ob2_t", lang), L.s("ob2_d", lang)),
         ("square.and.arrow.up", L.s("ob3_t", lang), L.s("ob3_d", lang))]
    }

    /// The artwork yields to the words when the words need the room.
    private var art: CGFloat { typeSize.isAccessibilitySize ? 120 : 220 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                languageMenu
                Spacer()
                Button(L.s("skip", lang)) { done = true }
                    .font(.footnote)
                    .tint(.secondary)
            }
            // Both are chrome. Unbounded, "한국어" broke into two lines and ran
            // into "건너뛰기" on a 4.7" screen.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    // Scrollable, and the artwork shrinks: at the largest text
                    // size the fixed layout cut the headline and the body off
                    // mid-word — on the first screen a new user ever sees.
                    ScrollView {
                        VStack(spacing: 16) {
                            Spacer(minLength: 12)
                            ZStack {
                                Circle()
                                    .fill(RadialGradient(colors: [accent.opacity(0.3), .clear],
                                                         center: .center,
                                                         startRadius: 4, endRadius: 110))
                                    .frame(width: art, height: art)
                                Image(systemName: pages[i].symbol)
                                    .font(.system(size: art * 0.32, weight: .light))
                                    .foregroundStyle(accent)
                            }
                            Text(pages[i].title)
                                .font(.title.bold())
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(pages[i].body)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 34)
                            Spacer(minLength: 12)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Our own dots, below the pages rather than floating over them.
            // TabView's own indicator sits on top of the scroll view, and at
            // the largest text size it landed in the middle of the sentence.
            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 6)

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    done = true
                }
            } label: {
                Text(page < pages.count - 1 ? L.s("next", lang) : L.s("get_started", lang))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .rcPrimary()
            .tint(accent)
            .foregroundStyle(.black)
            .padding(20)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
