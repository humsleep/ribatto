import SwiftUI

/// Language, privacy, licences and — where the law asks for it — the ad
/// consent switch. These used to hang off a globe in the library header,
/// one of four header buttons; nobody looks for a privacy page under a globe.
/// They change once, so they live one tap further away.
struct AppSettingsView: View {
    @EnvironmentObject var ads: AdsManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivacy = false
    @State private var showLicenses = false

    var body: some View {
        NavigationStack {
            List {
                Section(L.s("language", lang)) {
                    ForEach(L.languages, id: \.code) { l in
                        Button {
                            lang = l.code
                        } label: {
                            HStack {
                                Text(l.label).foregroundStyle(.primary)
                                Spacer()
                                if lang == l.code {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(lang == l.code ? .isSelected : [])
                    }
                }
                Section {
                    // "The video never leaves the phone" is the app's main
                    // promise, so the detail behind it is readable in the app.
                    Button { showPrivacy = true } label: {
                        Label(L.s("privacy", lang), systemImage: "hand.raised")
                    }
                    // The bundled fonts ship under the OFL and Pow under MIT,
                    // which require their licences to be included.
                    Button { showLicenses = true } label: {
                        Label(L.s("licenses", lang), systemImage: "doc.text")
                    }
                    // Only where a consent regime applies; elsewhere it would
                    // be a switch that does nothing.
                    if ads.privacyOptionsRequired {
                        Button {
                            Task { await ads.presentPrivacyOptions() }
                        } label: {
                            Label(L.s("ad_privacy_options", lang), systemImage: "checkmark.shield")
                        }
                    }
                }
                .tint(.primary)
            }
            .navigationTitle(L.s("settings", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.s("done", lang)) { dismiss() }
                        .font(.subheadline.bold())
                }
            }
            .sheet(isPresented: $showPrivacy) { PrivacyView() }
            .sheet(isPresented: $showLicenses) { LicensesView() }
        }
        .preferredColorScheme(.dark)
    }
}
