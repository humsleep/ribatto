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
    @State private var tab = 0
    /// The opening card plays once per launch, over whatever comes next.
    @State private var showIntro = true
    @Environment(\.scenePhase) private var scenePhase

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
                    // Inside each tab the default tint is white: volt is for the
                    // current selection (the tab bar keeps it) and brand moments.
                    TabView(selection: $tab) {
                        LibraryView()
                            .tint(Theme.primaryText)
                            .tabItem {
                                Label(L.s("library", lang), systemImage: "rectangle.stack")
                            }
                            .tag(0)
                        // Three tabs. An "All Clips" tab repeated what each
                        // match already shows, filtered six ways, and was the
                        // tab testers opened once and never again (removed
                        // 2026-10-11). The reels the user built sit between
                        // the matches and the numbers: they are what the app
                        // is for.
                        ReelsView(openLibrary: { tab = 0 })
                            .tint(Theme.primaryText)
                            .tabItem {
                                Label(L.s("reels", lang),
                                      systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                            }
                            .tag(1)
                        StatsView(openLibrary: { tab = 0 })
                            .tint(Theme.primaryText)
                            .tabItem {
                                Label(L.s("season", lang), systemImage: "chart.bar.fill")
                            }
                            .tag(2)
                    }
                } else {
                    OnboardingView(done: $onboarded)
                }
            }
            .overlay {
                if showIntro {
                    IntroView { showIntro = false }
                        .transition(.identity)
                }
            }
            .environmentObject(store)
            .environmentObject(pass)
            .environmentObject(ads)
            // Ads wait for onboarding: the tracking prompt on top of the
            // welcome page would be the first thing a new user sees.
            // They also wait for the app to be active. A tracking request made
            // before that is dropped without a prompt, and an ATT prompt that
            // never appears is a 2.1 rejection. The 1.6 s title card used to
            // buy this time; with it gone the root task runs at first layout,
            // before didBecomeActive.
            // And they wait for the intro: a consent form or tracking prompt
            // landing on the title card reads as a broken launch.
            .task(id: onboarded && !showIntro) {
                guard onboarded, !showIntro else { return }
                while UIApplication.shared.applicationState != .active {
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { return }
                }
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
                // Screenshot data: videos dropped into Documents/seed are
                // imported as matches named after their files and detected.
                if CommandLine.arguments.contains("-seedDemo") {
                    await store.seedDemo()
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
