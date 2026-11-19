import Foundation

/// Whether Pro is open right now: bought, or one job opened by an ad.
///
/// Buying (`PurchaseManager`) opens everything for good. Without it, a
/// rewarded ad played to the end (`AdsManager.showRewarded`) opens Pro for the
/// **next job** — one match render, one reel, one batch save or one merge —
/// up to `dailyLimit` ads a day. The job takes the pass when it starts
/// (`consume`), and renders bake the tier at their start, so what it made
/// keeps its quality after.
///
/// It was an hour of everything until 2026-11-19. A player brings one match a
/// day, and an hour covers it, so three hours a day was no limit at all and
/// nobody ever reached the point where buying made sense.
///
/// State lives in UserDefaults on purpose: one job of a free app is not worth
/// a server round-trip to protect.
@MainActor
final class ProPass: ObservableObject {
    /// Ads a day that can open a job, counted when the ad is watched.
    static let dailyLimit = 3
    /// An unused pass lapses after this, so it is not a standing ad-free mode.
    static let lifetime: TimeInterval = 24 * 60 * 60
    private static let untilKey = "rc_pro_pass_until"
    private static let dayKey = "rc_pass_day"
    private static let countKey = "rc_pass_day_count"

    /// When an unused pass lapses; nil when there is none.
    @Published private(set) var until: Date?
    @Published private(set) var isPro = false
    /// Bought Pro, as `PurchaseManager` last reported it.
    @Published var owned = false { didSet { if owned != oldValue { recompute() } } }
    @Published private(set) var usedToday = 0
    private var expiry: Task<Void, Never>?

#if DEBUG
    /// Debug builds only: pins Pro on without an ad, so the Pro paths can be
    /// tested without sitting through one.
    private static let debugKey = "rc_debug_pro"
    @Published private(set) var debugPro = UserDefaults.standard.bool(forKey: ProPass.debugKey)
#endif

    init() {
        until = UserDefaults.standard.object(forKey: Self.untilKey) as? Date
        usedToday = Self.count()
        recompute()
    }

    /// A pass is waiting for the next job.
    var active: Bool { until.map { $0 > Date() } ?? false }
    var remainingToday: Int { max(0, Self.dailyLimit - usedToday) }
    /// Another ad can open a job: none waiting and today's ads not used up.
    var canEarn: Bool { !owned && !active && remainingToday > 0 }

    /// Start of today in the user's calendar, as a number: a formatted date
    /// string drifted with the formatter's locale and calendar.
    private static var today: Double { Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 }

    private static func count() -> Int {
        let d = UserDefaults.standard
        return d.double(forKey: dayKey) == today ? d.integer(forKey: countKey) : 0
    }

    /// Called once the rewarded ad has played to the end. A second ad while a
    /// pass waits is not counted again: it opens nothing more.
    func grant() {
        guard !active else { return }
        usedToday = Self.count() + 1
        let d = UserDefaults.standard
        d.set(Self.today, forKey: Self.dayKey)
        d.set(usedToday, forKey: Self.countKey)
        until = Date().addingTimeInterval(Self.lifetime)
        d.set(until, forKey: Self.untilKey)
        recompute()
    }

    /// A Pro job has started on the pass. Bought Pro has nothing to take.
    func consume() {
        guard active, !owned else { return }
#if DEBUG
        if debugPro { return }
#endif
        until = nil
        UserDefaults.standard.removeObject(forKey: Self.untilKey)
        recompute()
    }

    /// The count rolls over at midnight; called whenever the sheet that shows it opens.
    func refreshDay() { usedToday = Self.count() }

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

    func resetDay() {
        UserDefaults.standard.set(0, forKey: Self.countKey)
        usedToday = 0
    }
#endif

    /// The one place `isPro` is derived. The expiry task re-runs it so an
    /// unused pass drops the moment it lapses, without a relaunch.
    private func recompute() {
        var pro = owned || active
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
