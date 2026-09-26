import AppTrackingTransparency
import GoogleMobileAds
import UserMessagingPlatform
import SwiftUI
import UIKit

/// Ads for the free tier: a banner above the tab bar, an interstitial after a
/// render, and the rewarded ad that opens Pro. A pass removes the first two.
///
/// Why ads: a free app can go through review without the paid-apps agreement,
/// bank account and tax forms, and a match-clipping tool opened once or twice a
/// week is a poor fit for a price. The banner pays for the render, and the
/// interstitial sits where the user is already waiting — the end of a render —
/// never in a player or an editor.
///
/// What the SDK sends: the advertising identifier (only after the ATT prompt
/// is accepted), IP address and coarse device data. Never the video, the clips
/// or any match data — those stay on the device, and PrivacyView says so in
/// the same words. If this class ever changes what leaves the phone, that
/// screen and the published policy change with it.
@MainActor
final class AdsManager: NSObject, ObservableObject {
    /// Ad unit ids. Debug builds use Google's public test units, which serve
    /// labelled test ads on any device. Release ids come from the AdMob
    /// console (RELEASE.md 4-2); while they are empty a Release build runs
    /// without ads instead of crashing on an invalid unit.
    enum Unit {
        /// Google's public test units. They fill on any device, for any
        /// account, whether or not the app is on the store — which is the only
        /// way to see an ad before release, because AdMob does not serve real
        /// ads to an app it has not reviewed, and it cannot review one that is
        /// not published yet.
        enum Test {
            static let banner = "ca-app-pub-3940256099942544/2435281174"
            static let interstitial = "ca-app-pub-3940256099942544/4411468910"
            static let rewarded = "ca-app-pub-3940256099942544/1712485313"
        }
        /// The real units, from the AdMob console. They pay; they also return
        /// nothing until the app is published and reviewed.
        enum Live {
            static let banner = "ca-app-pub-4073994600346533/4778238789"
            static let interstitial = "ca-app-pub-4073994600346533/5843908440"
            static let rewarded = "ca-app-pub-4073994600346533/2103973988"
        }

        /// Which set this install uses. Decided at runtime from `distribution`,
        /// not from the build configuration: TestFlight and Xcode installs are
        /// Release builds too, so `#if DEBUG` alone left them asking for real
        /// ads — which AdMob will not fill before the app is published, and
        /// which would count developer taps as invalid traffic once it is.
        static var usesTestAds: Bool { distribution != .appstore }
        static var banner: String { usesTestAds ? Test.banner : Live.banner }
        static var interstitial: String {
            usesTestAds ? Test.interstitial : Live.interstitial
        }
        static var rewarded: String { usesTestAds ? Test.rewarded : Live.rewarded }
    }

    /// How this copy of the app was installed.
    ///
    /// The distinction matters because only an App Store install may request
    /// real ads. A developer testing a TestFlight build taps their own ads;
    /// AdMob counts that as invalid traffic and suspends accounts that keep
    /// doing it. Checking the build configuration is not enough — TestFlight,
    /// Xcode installs and Ad-hoc are all Release builds.
    ///
    /// - `embedded.mobileprovision` exists in development and Ad-hoc installs
    ///   and in neither App Store nor TestFlight builds.
    /// - A TestFlight receipt is named `sandboxReceipt`; a store one is not.
    ///
    /// Borrowed from FC Scope, which ships the same check on this account.
    enum Distribution: String { case debug, testflight, appstore }

    static let distribution: Distribution = {
        #if DEBUG || targetEnvironment(simulator)
        return .debug
        #else
        if Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil {
            return .debug
        }
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return .testflight
        }
        return .appstore
        #endif
    }()

    /// Shortest gap between two interstitials. A render can finish every few
    /// seconds when the user trims several clips in a row; one ad per trim
    /// would be the fastest way to lose them.
    static let interstitialInterval: TimeInterval = 180

    /// True while ads should be on screen: SDK started, user not Pro.
    @Published private(set) var showing = false
    /// Height the banner takes once an ad is on it.
    @Published private(set) var bannerHeight: CGFloat = 0
    /// An ad is actually on the banner. The slot above the tab bar opens only
    /// then: reserving the height at SDK start left a blank strip under the
    /// tab bar for as long as AdMob had nothing to fill it with — every
    /// TestFlight build of a not-yet-reviewed app looked broken.
    @Published private(set) var bannerLoaded = false
    /// One banner for the four tabs: each tab's slot re-parents this view when
    /// it comes on screen (`AdBannerHost`). Four views would mean four
    /// requests, three of them for tabs nobody is looking at.
    private(set) var banner: BannerView?
    private var bannerAttempts = 0
    private var loadingBanner = false
    /// An ad has rendered on this banner at least once. Distinguishes "never
    /// filled" (hide the slot) from "a later refresh failed" (keep showing).
    private var bannerFilled = false
    /// A rewarded ad is loaded and can be shown. The Pro sheet's "watch an ad"
    /// button reads this so it never promises an ad that is not there.
    @Published private(set) var rewardedReady = false
    /// The last rewarded load failed and no retry is scheduled. The Pro sheet
    /// then offers "try again" instead of a spinner that never ends — this ad
    /// is the only way into Pro, so a single network blip used to lock the
    /// user out until the app was relaunched.
    @Published private(set) var rewardedFailed = false
    private var rewardedAttempts = 0

    /// The user's region needs a way back into the consent choices (EEA, UK,
    /// Switzerland). Google requires that entry point wherever this is true;
    /// the Library's globe menu shows it.
    @Published private(set) var privacyOptionsRequired = false

    private var isPro = false
    private var started = false
    /// `start` is between the consent gate and the SDK handshake. Keeps a
    /// second call from running the sequence twice without claiming the SDK
    /// is up, which `started` would.
    private var starting = false
    /// Consent allows ad requests. Outside the regions that need consent this
    /// is true as soon as the check returns.
    private var consentAllows = false
    private var interstitial: InterstitialAd?
    private var loadingInterstitial = false
    /// The rewarded ad: the highest-paying format AdMob has, and the one
    /// the user has to sit through to the end. In exchange it opens every
    /// Pro feature for `ProPass.duration`.
    private var rewarded: RewardedAd?
    private var loadingRewarded = false
    private var lastInterstitial = Date.distantPast

    /// Whether the build carries a usable AdMob app id. The SDK throws at
    /// `start` when GADApplicationIdentifier is missing or malformed; checking
    /// first turns a forgotten Release setting into "no ads" rather than a
    /// crash on the App Store.
    static var configured: Bool {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String
        else { return false }
        return id.hasPrefix("ca-app-pub-") && id.contains("~") && !Unit.banner.isEmpty
    }

    /// Called once the tier is known. Asks for tracking permission first —
    /// the prompt has to precede the first ad request or the identifier is
    /// never shared — then starts the SDK. A Pro user never sees the prompt.
    func start(isPro: Bool) async {
        self.isPro = isPro
        guard !isPro, !starting, !started, Self.configured else { refreshShowing(); return }
        // `starting`, not `started`: marking the SDK started before the
        // consent gate below meant that one failed consent call on a fresh
        // install left `started == true` with `consentAllows == false`, and
        // nothing could ever re-enter. That kills the banner, the
        // interstitial AND the rewarded ad — and the rewarded ad is the only
        // way into Pro, so a single first-launch network blip locked the user
        // out of every paid feature until they force-quit the app.
        starting = true
        defer { starting = false }
        // Consent first (GDPR / UK / Swiss regions, via Google's UMP form),
        // then Apple's tracking prompt, then the SDK — the order Google
        // documents. Serving ads to an EEA user without a consent message is
        // an AdMob policy violation that ends in limited or no ads there.
        await gatherConsent()
        // Not consented (or the consent lookup failed): leave `started`
        // false so a later attempt — foreground, pass expiry, the privacy
        // options form — can run the whole sequence again.
        guard consentAllows else { refreshShowing(); return }
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
        await MobileAds.shared.start()
        started = true
        bannerHeight = Self.adaptiveSize(width: Self.screenWidth).size.height
        refreshShowing()
    }

    /// Re-runs `start` when an earlier attempt never got past the consent
    /// gate. Called when the app comes back to the foreground, which is the
    /// natural moment for "the user turned the network back on".
    func retryIfNeverStarted() async {
        guard !started, !starting, !isPro else { return }
        await start(isPro: isPro)
    }

    /// A pass switches ads off the moment it is granted, and back on the
    /// minute it ends, without a relaunch.
    func setPro(_ pro: Bool) {
        isPro = pro
        refreshShowing()
        if !pro && !started { Task { await start(isPro: false) } }
    }

    private func gatherConsent() async {
        let info = ConsentInformation.shared
        do {
            try await info.requestConsentInfoUpdate(with: RequestParameters())
            try await ConsentForm.loadAndPresentIfRequired(from: nil)
        } catch {
            // A failed update keeps the last stored answer; `canRequestAds`
            // below reads that, so an offline launch still honours it.
            #if DEBUG
            print("[ads] consent: \(error.localizedDescription)")
            #endif
        }
        consentAllows = info.canRequestAds
        privacyOptionsRequired = info.privacyOptionsRequirementStatus == .required
    }

    /// Reopens the consent choices. Afterwards the SDK is started if the user
    /// now allows ads and it was not running.
    func presentPrivacyOptions() async {
        try? await ConsentForm.presentPrivacyOptionsForm(from: nil)
        let allowed = ConsentInformation.shared.canRequestAds
        if allowed && !consentAllows {
            consentAllows = true
            await MobileAds.shared.start()
            started = true
            bannerHeight = Self.adaptiveSize(width: Self.screenWidth).size.height
        }
        consentAllows = allowed
        // `refreshShowing` loads the banner and the interstitial on the
        // false -> true edge. Calling them before it left `showing` stale at
        // false, so both guards bailed and an EEA user who re-consented got
        // no ads at all for the rest of the session.
        refreshShowing()
    }

    // MARK: - Banner

    /// Creates the shared banner on first use and requests an ad. The view is
    /// only sized and shown by the tab slot after `bannerViewDidReceiveAd`.
    private func loadBanner() {
        guard showing, !Unit.banner.isEmpty, !loadingBanner else { return }
        loadingBanner = true
        if banner == nil {
            let view = BannerView(adSize: Self.adaptiveSize(width: Self.screenWidth))
            view.adUnitID = Unit.banner
            view.delegate = self
            banner = view
        }
        // `rootViewController` stays nil on purpose: the SDK then presents
        // from the controller that actually contains the banner, which is the
        // right one for a view that moves between tabs.
        banner?.load(Request())
    }

    /// Recomputes `showing` and arms whatever that transition calls for.
    /// Every caller that changes tier or consent goes through here, so the
    /// "who reloads what" question has exactly one answer.
    private func refreshShowing() {
        let was = showing
        showing = started && consentAllows && !isPro && Self.configured
        if showing && !was {
            // false -> true: a pass expired, or consent was just granted.
            // Nothing re-requested here meant the banner and the interstitial
            // stayed dead for the rest of the session.
            loadBanner()
            loadInterstitial()
        } else if !showing && was {
            // true -> false: a pass started. Release the banner — the SDK
            // keeps its refresh timer running on a view with no window, and
            // an impression recorded for an ad nobody can see is exactly what
            // the invalid-traffic rules are about. There is no pause API.
            banner?.removeFromSuperview()
            banner = nil
            bannerLoaded = false
            bannerFilled = false
            bannerAttempts = 0
        }
        // The rewarded ad stays loaded during a pass too: watching another one
        // is how a pass is extended before a long render.
        if started && consentAllows && Self.configured { loadRewarded() }
    }

    // MARK: - Rewarded

    /// Plays the rewarded ad and calls `onReward` only if it ran to the end —
    /// the SDK withholds the reward callback on an early close, which is what
    /// makes this format worth what it pays. Returns false when no ad is
    /// loaded; the caller shows nothing and the button was disabled anyway.
    @discardableResult
    func showRewarded(onReward: @escaping () -> Void) -> Bool {
        guard started, let ad = rewarded else { return false }
        rewarded = nil
        rewardedReady = false
        ad.present(from: nil) { onReward() }
        return true
    }

    private func loadRewarded() {
        guard started, consentAllows, Self.configured, rewarded == nil, !loadingRewarded,
              !Unit.rewarded.isEmpty else { return }
        loadingRewarded = true
        Task {
            defer { loadingRewarded = false }
            do {
                let ad = try await RewardedAd.load(with: Unit.rewarded, request: Request())
                ad.fullScreenContentDelegate = self
                rewarded = ad
                rewardedReady = true
                rewardedFailed = false
                rewardedAttempts = 0
            } catch {
                #if DEBUG
                print("[ads] rewarded load failed: \(error.localizedDescription)")
                #endif
                rewardedAttempts += 1
                // Two quiet retries (10 s, then 30 s) cover a flaky network;
                // after that the button hands the decision to the user rather
                // than polling AdMob forever.
                if rewardedAttempts <= 2 {
                    let delay: UInt64 = rewardedAttempts == 1 ? 10 : 30
                    Task {
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        loadRewarded()
                    }
                } else {
                    rewardedFailed = true
                }
            }
        }
    }

    /// The user pressed "try again" after the automatic retries ran out.
    func retryRewarded() {
        rewardedFailed = false
        rewardedAttempts = 0
        loadRewarded()
    }

    // MARK: - Interstitial

    /// Shows the loaded interstitial if enough time has passed since the last
    /// one, then preloads the next. Safe to call after every render; the
    /// interval does the rationing.
    func showInterstitialIfDue() {
        // Reload first: a single failed load used to end interstitials for
        // the whole session, because the guard below returns on a nil ad and
        // the only reload sat after a successful present. No-fill is the
        // normal answer for a new app, so that was the common case.
        guard showing else { return }
        guard let ad = interstitial else { loadInterstitial(); return }
        guard Date().timeIntervalSince(lastInterstitial) >= Self.interstitialInterval
        else { return }
        interstitial = nil
        lastInterstitial = Date()
        // nil lets the SDK present from the top-most controller, which is the
        // sheet when the trigger came from ReelSheet.
        ad.present(from: nil)
        loadInterstitial()
    }

    private func loadInterstitial() {
        guard showing, interstitial == nil, !loadingInterstitial else { return }
        loadingInterstitial = true
        Task {
            defer { loadingInterstitial = false }
            do {
                let ad = try await InterstitialAd.load(with: Unit.interstitial, request: Request())
                ad.fullScreenContentDelegate = self
                interstitial = ad
            } catch {
                // No retry loop: the next render calls `showInterstitialIfDue`,
                // which finds nothing loaded and reloads via the next call.
                #if DEBUG
                print("[ads] interstitial load failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    // MARK: - Sizing

    static var screenWidth: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.screen.bounds.width ?? UIScreen.main.bounds.width
    }

    static func adaptiveSize(width: CGFloat) -> AdSize {
        currentOrientationAnchoredAdaptiveBanner(width: width)
    }
}

extension AdsManager: FullScreenContentDelegate {
    // Both formats share the delegate; reloading both after either closes is
    // cheap and keeps whichever one just played ready for the next time.
    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in
            loadInterstitial()
            loadRewarded()
        }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd,
                        didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in
            interstitial = nil
            rewarded = nil
            rewardedReady = false
            loadInterstitial()
            loadRewarded()
        }
    }
}

extension AdsManager: BannerViewDelegate {
    nonisolated func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        Task { @MainActor in
            loadingBanner = false
            bannerLoaded = true
            bannerFilled = true
            bannerAttempts = 0
        }
    }

    nonisolated func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        Task { @MainActor in
            #if DEBUG
            print("[ads] banner load failed: \(error.localizedDescription)")
            #endif
            loadingBanner = false
            // Only collapse the slot if nothing has ever rendered. A failed
            // auto-refresh of an ad that is already on screen is not a reason
            // to remove it: doing so dropped the tab bar 63pt mid-scroll and
            // put it back again on the next success.
            if !bannerFilled { bannerLoaded = false }
            // No fill is the normal answer for a new app for hours at a time.
            // Back off (30 s, 1, 2, 4, 5 min, then every 5 min) instead of
            // either hammering AdMob or giving up until the next launch.
            bannerAttempts += 1
            let delay = min(30 * pow(2, Double(bannerAttempts - 1)), 300)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.loadBanner()
            }
        }
    }
}

/// The slot each tab keeps above its tab bar. Empty until an ad has loaded,
/// so a tab bar with no ad under it sits on the bottom edge like any other
/// app's, and grows to the banner's height the moment there is something to
/// show. Sheets cover it, which is the point: no ad next to a player.
struct AdBannerSlot: View {
    @EnvironmentObject private var ads: AdsManager

    var body: some View {
        if ads.showing, ads.bannerLoaded, let banner = ads.banner {
            AdBannerHost(banner: banner)
                .frame(height: ads.bannerHeight)
                .frame(maxWidth: .infinity)
                .background(Theme.background)
        }
    }
}

extension View {
    /// Puts the free tier's banner between this tab's content and the tab bar.
    /// Applied to each tab root rather than the `TabView`: an inset on the
    /// `TabView` lands *under* the tab bar and lifts it off the screen edge.
    func adBanner() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { AdBannerSlot() }
    }
}

/// Hosts the shared `BannerView`. The container claims the banner whenever it
/// enters a window — `UITabBarController` takes a deselected tab's view out
/// of the window, so the one container that has a window is always the tab
/// the user is looking at. That is more reliable than SwiftUI's `onAppear`,
/// which fires for tabs the user has never opened.
struct AdBannerHost: UIViewRepresentable {
    let banner: BannerView

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.banner = banner
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ uiView: Container, context: Context) {
        uiView.banner = banner
        uiView.claimIfVisible()
    }

    final class Container: UIView {
        var banner: BannerView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            claimIfVisible()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            banner?.frame = bounds
        }

        func claimIfVisible() {
            guard window != nil, let banner, banner.superview !== self else { return }
            banner.removeFromSuperview()
            addSubview(banner)
            banner.frame = bounds
        }
    }
}
