import SwiftUI

struct OnboardingView: View {
    @AppStorage("rc_lang") private var lang = "en"
    @Binding var done: Bool
    @State private var page = 0

    private let accent = Theme.accent

    private var pages: [(symbol: String, title: String, body: String)] {
        [("sportscourt", L.s("ob1_t", lang), L.s("ob1_d", lang)),
         ("waveform", L.s("ob2_t", lang), L.s("ob2_d", lang)),
         ("square.and.arrow.up", L.s("ob3_t", lang), L.s("ob3_d", lang))]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                languageMenu
                Spacer()
                Button(L.s("skip", lang)) { done = true }
                    .font(.footnote)
                    .tint(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 16) {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(RadialGradient(colors: [accent.opacity(0.3), .clear],
                                                     center: .center,
                                                     startRadius: 4, endRadius: 110))
                                .frame(width: 220, height: 220)
                            Image(systemName: pages[i].symbol)
                                .font(.system(size: 70, weight: .light))
                                .foregroundStyle(accent)
                        }
                        Text(pages[i].title)
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                        Text(pages[i].body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 34)
                        Spacer()
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

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
            }
            .tint(.secondary)
        }
    }
}
