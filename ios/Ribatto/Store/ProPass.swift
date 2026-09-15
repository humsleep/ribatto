import Foundation

/// Whether Pro is open right now.
///
/// Pro is not sold. Watching a rewarded ad to the end (`AdsManager.showRewarded`)
/// opens every Pro feature for `duration`, and nothing else does. Renders bake
/// the tier at their start, so a pass ending mid-render changes nothing, and
/// clips made inside the hour keep their quality after it.
///
/// The end time is persisted so a relaunch inside the hour keeps Pro. It lives
/// in UserDefaults on purpose: an hour of a free app is not worth a server
/// round-trip to protect.
@MainActor
final class ProPass: ObservableObject {
    /// One hour covers an import, a review and a reel for a normal match; a
    /// longer video means a second ad.
    static let duration: TimeInterval = 60 * 60
    private static let untilKey = "rc_pro_pass_until"

    /// End of the current pass, if one was earned.
    @Published private(set) var until: Date?
    @Published private(set) var isPro = false
    private var expiry: Task<Void, Never>?

#if DEBUG
    /// Debug builds only: pins Pro on without an ad, so the Pro paths can be
    /// tested without sitting through one.
    private static let debugKey = "rc_debug_pro"
    @Published private(set) var debugPro = UserDefaults.standard.bool(forKey: ProPass.debugKey)
#endif

    init() {
        until = UserDefaults.standard.object(forKey: Self.untilKey) as? Date
        recompute()
    }

    var active: Bool { until.map { $0 > Date() } ?? false }

    /// Whole minutes left, never below one while the pass is active, so the
    /// label does not read "0 min left" for the last 59 seconds.
    var minutesLeft: Int {
        guard let until else { return 0 }
        return max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
    }

    /// Called once the rewarded ad has played to the end. A second ad inside
    /// the hour extends from the current end, so watching early never throws
    /// minutes away.
    func grant() {
        let from = max(Date(), until ?? Date())
        until = from.addingTimeInterval(Self.duration)
        UserDefaults.standard.set(until, forKey: Self.untilKey)
        recompute()
    }

#if DEBUG
    func setDebugPro(_ on: Bool) {
        debugPro = on
        UserDefaults.standard.set(on, forKey: Self.debugKey)
        recompute()
    }

    func endPass() {
        until = nil
        UserDefaults.standard.removeObject(forKey: Self.untilKey)
        recompute()
    }
#endif

    /// The one place `isPro` is derived. The expiry task re-runs it so the tier
    /// drops the minute the hour is up, without a relaunch.
    private func recompute() {
        var pro = active
#if DEBUG
        if debugPro { pro = true }
#endif
        isPro = pro
        expiry?.cancel()
        guard let until, until > Date() else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow + 1))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }
}
