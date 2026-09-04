import SwiftUI

@main
struct VollioApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var purchases = PurchaseManager()
    @AppStorage("rc_lang") private var lang = "en"
    @AppStorage("rc_onboarded") private var onboarded = false

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
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
                } else {
                    OnboardingView(done: $onboarded)
                }
            }
            .environmentObject(store)
            .environmentObject(purchases)
            .task {
                store.isPro = purchases.isPro
                store.onSessionRegistered = { purchases.noteSessionCreated() }
                purchases.unavailableMessage = L.s("store_unavailable", lang)
                purchases.nothingToRestoreMessage = L.s("restore_none", lang)
                store.awaitEntitlement = { await purchases.waitForEntitlement() }
                store.missingSourceMessage = L.s("source_missing", lang)
                store.placeLocale = L.locale(lang)
                store.resolveMissingPlaceNames()
                store.backfillCaptureDates()
            }
            .onChange(of: lang) { _, l in
                purchases.unavailableMessage = L.s("store_unavailable", l)
                purchases.nothingToRestoreMessage = L.s("restore_none", l)
                store.missingSourceMessage = L.s("source_missing", l)
                store.placeLocale = L.locale(l)
            }
            // exports stop when iOS suspends the app, so hold the screen on
            // for as long as something is rendering
            .onChange(of: store.progress.isEmpty) { _, idle in
                UIApplication.shared.isIdleTimerDisabled = !idle
            }
            .onChange(of: purchases.isPro) { _, pro in store.isPro = pro }
            .preferredColorScheme(.dark)
            .background(Theme.background)
            .tint(Theme.accent)
        }
    }
}
