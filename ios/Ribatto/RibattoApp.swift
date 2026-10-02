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
    @Environment(\.scenePhase) private var scenePhase
    /// The title card on top of everything for a moment after launch. The
    /// app underneath loads at the same time, so it costs no startup time.
    @State private var showIntro = true

    /// Before any view reads `rc_lang`: seeding it from a `.task` would let the
    /// first screen render in English and then switch, which is worse than
    /// either language on its own.
    init() { L.seedLanguageFromDevice() }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    // The banner is NOT attached here. A `safeAreaInset`
                    // applied outside a tab's `NavigationStack` never reaches
                    // the scroll views inside it, so the ad painted over the
                    // last 63pt of every list and sliced the pinned selection
                    // bars in half (2026-09-23). Each tab root adds the slot
                    // inside its own stack instead.
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
            .accessibilityHidden(showIntro)
            .overlay {
                if showIntro {
                    IntroView {
                        withAnimation(.easeOut(duration: 0.35)) { showIntro = false }
                    }
                    .transition(.opacity)
                }
            }
            .environmentObject(store)
            .environmentObject(pass)
            .environmentObject(ads)
            // Ads wait for onboarding: the tracking prompt on top of the
            // welcome pages would be the first thing a new user sees.
            // ...and for the title card: the consent form or the tracking
            // prompt would otherwise land on it mid-animation. Waiting it out
            // also puts the tracking request after launch has settled — one
            // made before the scene is active is dropped without a prompt, and
            // an ATT prompt that never appears is a 2.1 rejection.
            .task(id: onboarded && !showIntro) {
                guard onboarded, !showIntro else { return }
                await ads.start(isPro: pass.isPro)
            }
            .task {
                store.isPro = pass.isPro
                store.missingSourceMessage = L.s("source_missing", lang)
                store.interruptedMessage = L.s("interrupted", lang)
                store.placeLocale = L.locale(lang)
                store.resolveMissingPlaceNames()
                store.backfillCaptureDates()
                #if DEBUG
                if CommandLine.arguments.contains("-diagRender") {
                    await store.runDiagnostics()
                }
                #endif
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
            // A consent lookup that failed on a fresh install leaves the SDK
            // unstarted, and with it no banner, no interstitial and no
            // rewarded ad — which is the only way into Pro. Coming back to
            // the foreground is when the network is most likely to be back,
            // so retry there rather than waiting for a relaunch.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, onboarded, !showIntro else { return }
                Task { await ads.retryIfNeverStarted() }
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
