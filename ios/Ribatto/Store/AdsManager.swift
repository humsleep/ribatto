import AppTrackingTransparency
import GoogleMobileAds
import SwiftUI
import UIKit

/// Ads for the free tier: a banner under the tab bar and an interstitial
/// after a render. Pro removes both.
///
/// Why ads at all: a free app can go through review before the paid-apps
/// agreement, bank account and tax forms are accepted, and a match-clipping
/// tool is opened once or twice a week, so the free import cap that fed the
/// paywall mostly fed uninstalls. The cap is gone; the banner pays for the
/// render instead, and the interstitial sits where the user is already
/// waiting — the end of a render — never in a player or an editor.
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
        #if DEBUG
        static let banner = "ca-app-pub-3940256099942544/2435281174"
        static let interstitial = "ca-app-pub-3940256099942544/4411468910"
        static let rewarded = "ca-app-pub-3940256099942544/1712485313"
        #else
        static let banner = ""
        static let interstitial = ""
        static let rewarded = ""
        #endif
    }

    /// Shortest gap between two interstitials. A render can finish every few
    /// seconds when the user trims several clips in a row; one ad per trim
    /// would be the fastest way to lose them.
    static let interstitialInterval: TimeInterval = 180

    /// True while ads should be on screen: SDK started, user not Pro.
    @Published private(set) var showing = false
    /// Height the banner needs, so the layout can reserve it before the ad
    /// arrives and nothing jumps when it does.
    @Published private(set) var bannerHeight: CGFloat = 0
    /// A rewarded ad is loaded and can be shown. The paywall's "watch an ad"
    /// button reads this so it never promises an ad that is not there.
    @Published private(set) var rewardedReady = false

    private var isPro = false
    private var started = false
    private var interstitial: InterstitialAd?
    private var loadingInterstitial = false
    /// The rewarded ad: the highest-paying format AdMob has, and the one
    /// the user has to sit through to the end. In exchange it opens every
    /// Pro feature for `PurchaseManager.passDuration`.
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
        guard !isPro, !started, Self.configured else { refreshShowing(); return }
        started = true
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
        await MobileAds.shared.start()
        bannerHeight = Self.adaptiveSize(width: Self.screenWidth).size.height
        refreshShowing()
        loadInterstitial()
        loadRewarded()
    }

    /// Pro switches ads off the moment the purchase lands; a refund or an
    /// owner-mode toggle switches them back on without a relaunch.
    func setPro(_ pro: Bool) {
        isPro = pro
        refreshShowing()
        if !pro && !started { Task { await start(isPro: false) } }
    }

    private func refreshShowing() {
        showing = started && !isPro && Self.configured
        if showing { loadRewarded() }
    }

    // MARK: - Rewarded

    /// Plays the rewarded ad and calls `onReward` only if it ran to the end —
    /// the SDK withholds the reward callback on an early close, which is what
    /// makes this format worth what it pays. Returns false when no ad is
    /// loaded; the caller shows nothing and the button was disabled anyway.
    @discardableResult
    func showRewarded(onReward: @escaping () -> Void) -> Bool {
        guard showing, let ad = rewarded else { return false }
        rewarded = nil
        rewardedReady = false
        ad.present(from: nil) { onReward() }
        return true
    }

    private func loadRewarded() {
        guard showing, rewarded == nil, !loadingRewarded, !Unit.rewarded.isEmpty else { return }
        loadingRewarded = true
        Task {
            defer { loadingRewarded = false }
            do {
                let ad = try await RewardedAd.load(with: Unit.rewarded, request: Request())
                ad.fullScreenContentDelegate = self
                rewarded = ad
                rewardedReady = true
            } catch {
                #if DEBUG
                print("[ads] rewarded load failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    // MARK: - Interstitial

    /// Shows the loaded interstitial if enough time has passed since the last
    /// one, then preloads the next. Safe to call after every render; the
    /// interval does the rationing.
    func showInterstitialIfDue() {
        guard showing, let ad = interstitial,
              Date().timeIntervalSince(lastInterstitial) >= Self.interstitialInterval
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

/// The banner, sized to the screen width. Lives under the tab bar in
/// `RibattoApp`, so every tab shares one view and one ad request.
struct AdBannerView: UIViewRepresentable {
    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdsManager.adaptiveSize(width: AdsManager.screenWidth))
        banner.adUnitID = AdsManager.Unit.banner
        banner.rootViewController = Self.rootController
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}

    private static var rootController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.rootViewController
    }
}
