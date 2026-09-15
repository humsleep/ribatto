import SwiftUI

/// What the app does with the user's data, stated in the app itself.
///
/// App Store Connect wants a hosted policy URL, which is the developer's to
/// publish; this is the version a user can read without leaving the app, and
/// it is written to match what the code actually does — including the one
/// thing that does leave the device, the coordinate sent to Apple's geocoder
/// in `PlaceLookup`, and the ad SDK in `AdsManager` that the free tier runs.
/// If either ever changes, this screen changes with it.
struct PrivacyView: View {
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss

    private static let sections = [
        ("iphone.gen3", "p_video_t", "p_video_d"),
        ("person.crop.circle.badge.xmark", "p_account_t", "p_account_d"),
        ("mappin.and.ellipse", "p_place_t", "p_place_d"),
        ("rectangle.badge.plus", "p_ads_t", "p_ads_d"),
        ("eye.slash", "p_analytics_t", "p_analytics_d"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L.s("privacy_head", lang))
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Self.sections, id: \.1) { icon, title, body in
                        HStack(alignment: .top, spacing: 13) {
                            Image(systemName: icon)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L.s(title, lang)).font(.subheadline.bold())
                                Text(L.s(body, lang))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(L.s("privacy", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(.secondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
