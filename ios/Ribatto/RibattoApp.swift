import SwiftUI

@main
struct RibattoApp: App {
    // Supplies the orientation callback. SwiftUI has no per-screen orientation
    // control, so the app delegate answers UIKit's question and the player
    // screens flip the switch it reads.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()
    @StateObject private var pass = ProPass()
    @StateObject private var ads = AdsManager()
    @AppStorage("rc_lang") private var lang = "en"
    @AppStorage("rc_onboarded") private var onboarded = false

    /// Before any view reads `rc_lang`: seeding it from a `.task` would let the
    /// first screen render in English and then switch, which is worse than
    /// either language on its own.
    init() { L.seedLanguageFromDevice() }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    // The banner sits under the tab bar, outside every tab,
                    // so the four tabs share one ad view and the 62pt tab-bar
                    // clearance the lists already keep stays correct. Sheets
                    // cover it, which is the point: no ad next to a player.
                    VStack(spacing: 0) {
                    TabView {
                        LibraryView()
                            .tabItem {
                                Label(L.s("library", lang), systemImage: "rectangle.stack")
                            }
                        AllClipsView()
                            .tabItem {
                                Label(L.s("all_clips", lang), systemImage: "film.stack")
                            }
                        // The reels the user built. Sits between the raw
                        // material and the numbers because it is the thing the
                        // app is for.
                        ReelsView()
                            .tabItem {
                                Label(L.s("reels", lang),
                                      systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                            }
                        StatsView()
                            .tabItem {
                                Label(L.s("season", lang), systemImage: "chart.bar.fill")
                            }
                    }
                    if ads.showing {
                        AdBannerView()
                            .frame(height: ads.bannerHeight)
                            .frame(maxWidth: .infinity)
                            .background(Theme.background)
                    }
                    }
                } else {
                    OnboardingView(done: $onboarded)
                }
            }
            .environmentObject(store)
            .environmentObject(pass)
            .environmentObject(ads)
            // Ads wait for onboarding: the tracking prompt on top of the
            // welcome pages would be the first thing a new user sees.
            .task(id: onboarded) {
                guard onboarded else { return }
                await ads.start(isPro: pass.isPro)
            }
            .task {
                store.isPro = pass.isPro
                store.missingSourceMessage = L.s("source_missing", lang)
                store.interruptedMessage = L.s("interrupted", lang)
                store.placeLocale = L.locale(lang)
                store.resolveMissingPlaceNames()
                store.backfillCaptureDates()
            }
            .onChange(of: lang) { _, l in
                store.missingSourceMessage = L.s("source_missing", l)
                store.interruptedMessage = L.s("interrupted", l)
                store.placeLocale = L.locale(l)
            }
            // exports stop when iOS suspends the app, so hold the screen on
            // for as long as something is rendering
            // `.failed` is a message that stays on screen, not work in flight,
            // so `progress` being non-empty is not the same as being busy. Using
            // it here meant one failed detect stopped the display from ever
            // auto-locking again.
            .onChange(of: store.busyCount) { _, busy in
                UIApplication.shared.isIdleTimerDisabled = busy > 0
            }
            .onChange(of: pass.isPro) { _, pro in
                store.isPro = pro
                ads.setPro(pro)
            }
            .preferredColorScheme(.dark)
            .background(Theme.background)
            .tint(Theme.accent)
        }
    }
}
