import SwiftUI

/// A pass offer, about one rally of one match.
struct PassOfferRequest: Identifiable {
    let id = UUID()
    let session: Session
    /// The rally whose frame is drawn both ways. nil draws placeholders.
    let segment: RallySegment?
    /// That rally's clip poster, shown at once while the real frames render.
    var poster: URL? = nil
    /// The title names what the user was reaching for — "follow the rally to
    /// fill the frame" for smart crop — rather than a generic pitch.
    var titleKey = "offer_title"
    /// The "not now" button. It names what happens instead — "Later · save
    /// free" when the user was saving — so declining is never a dead end.
    var declineKey = "offer_later"
    /// Shown without being asked for (on a free reel's save). Counts toward
    /// the caps in `PassOfferGate`; explicit gates do not.
    var passive = false
}

enum PassOfferOutcome { case granted, declined }

/// How often the offer may appear on its own. Explicit gates (a PASS feature
/// the user tapped) are not limited; only the passive one on a reel's save
/// is: once per launch, twice a day, and a week's rest after three "later"s
/// in a row. An offer that keeps coming back after being turned down is a
/// nag, not an offer.
@MainActor
enum PassOfferGate {
    private static var shownThisLaunch = false
    private static let dayKey = "rc_offer_day_start"
    private static let countKey = "rc_offer_day_count"
    private static let declinesKey = "rc_offer_declines"
    private static let snoozeKey = "rc_offer_snooze_until"

    /// Start of today in the user's calendar, as a number: a formatted date
    /// string drifted with the formatter's locale and calendar.
    private static var today: Double {
        Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    }

    static var allowsPassive: Bool {
        let d = UserDefaults.standard
        guard !shownThisLaunch,
              d.double(forKey: snoozeKey) < Date().timeIntervalSince1970 else { return false }
        let count = d.double(forKey: dayKey) == today ? d.integer(forKey: countKey) : 0
        return count < 2
    }

    static func recordShown() {
        let d = UserDefaults.standard
        shownThisLaunch = true
        let count = d.double(forKey: dayKey) == today ? d.integer(forKey: countKey) : 0
        d.set(today, forKey: dayKey)
        d.set(count + 1, forKey: countKey)
    }

    static func record(_ outcome: PassOfferOutcome) {
        let d = UserDefaults.standard
        switch outcome {
        case .granted:
            d.set(0, forKey: declinesKey)
        case .declined:
            let n = d.integer(forKey: declinesKey) + 1
            if n >= 3 {
                d.set(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970,
                      forKey: snoozeKey)
                d.set(0, forKey: declinesKey)
            } else {
                d.set(n, forKey: declinesKey)
            }
        }
    }
}

/// The half-sheet that offers the PASS at the moment it matters, showing the
/// difference on the user's own rally instead of a feature list: the same
/// frame as the free clip draws it and as the PASS does.
///
/// The presenter keeps the action that was interrupted and runs it after the
/// sheet closes — at PASS quality when `outcome` is `.granted`, on the free
/// tier when `.declined`, and not at all when the sheet was swiped away.
struct PassOfferSheet: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var pass: ProPass
    @EnvironmentObject var ads: AdsManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let request: PassOfferRequest
    @Binding var outcome: PassOfferOutcome?

    /// The SmartCrop-rendered pair, once ready. Until then `provisional`
    /// stands in, cut from the clip's own poster, so the sheet never opens on
    /// two empty boxes — the real pair took about ten seconds.
    @State private var frames: (free: UIImage, pass: UIImage)?
    @State private var provisional: (free: UIImage, pass: UIImage)?
    @State private var showFull = false
    /// Small enough that frames, title, line and both buttons all fit the
    /// half sheet on a large phone; capped so big type does not grow them.
    @ScaledMetric(relativeTo: .body) private var scaledFrame: CGFloat = 112
    /// 130 in the half sheet, where everything has to fit; taller when the
    /// sheet opens full, because the frames are the argument.
    private var frameHeight: CGFloat { fitsHalf ? min(scaledFrame, 130) : 170 }

    /// Rendered pairs by rally, so reopening the offer is instant. A few
    /// only: each pair is two bitmaps, and old matches are rarely reopened.
    private static var cache: [String: (free: UIImage, pass: UIImage)] = [:]
    private static var cacheOrder: [String] = []
    private var cacheKey: String? {
        request.segment.map { "\(request.session.id)|\($0.start)|\($0.end)" }
    }

    /// The half sheet only where everything fits in it: frames, title, line,
    /// two buttons and the link need about 430pt, and a 4.7" phone's half
    /// sheet is far shorter. There, and at accessibility sizes, it opens full.
    private var fitsHalf: Bool {
        guard !typeSize.isAccessibilitySize else { return false }
        let height = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.screen.bounds.height ?? 0
        return height >= 900
    }

    var body: some View {
        // No navigation bar and no X: the grabber and "later" close it, and a
        // bar cost the half sheet the space its title needed.
        ScrollView {
            VStack(spacing: 12) {
                comparison
                VStack(spacing: 4) {
                    Text(L.s(request.titleKey, lang))
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L.s("offer_sub", lang))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // In the flow, never pinned: pinned, the buttons sat on top of
                // the title at the half-sheet height.
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showFull) { ProPassView() }
        .presentationDetents(fitsHalf ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        // Closed only once the rewarded ad has gone: dismissing under a
        // full-screen ad raced its own dismissal. Covers a pass opened from
        // the full sheet linked below as well.
        .onChange(of: ads.rewardedClosed) { _, _ in
            guard pass.isPro else { return }
            outcome = .granted
            if request.passive { PassOfferGate.record(.granted) }
            dismiss()
        }
        // A swipe away is a "not now" for the passive offer's counter.
        .onDisappear {
            if outcome == nil && request.passive { PassOfferGate.record(.declined) }
        }
        .task { await loadFrames() }
    }

    // MARK: Frames

    @ViewBuilder private var comparison: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        layout {
            framed(frames?.free, provisional?.free, label: L.s("offer_free", lang),
                   ax: L.s("offer_ax_free", lang))
            framed(frames?.pass, provisional?.pass, label: L.s("offer_pass", lang),
                   ax: L.s("offer_ax_pass", lang))
        }
        .frame(maxWidth: .infinity)
    }

    private func framed(_ image: UIImage?, _ stand: UIImage?, label: String,
                        ax: String) -> some View {
        VStack(spacing: 4) {
            Color.clear
                .aspectRatio(9 / 16, contentMode: .fit)
                .frame(height: frameHeight)
                .overlay {
                    ZStack {
                        if let stand {
                            Image(uiImage: stand).resizable().scaledToFill()
                        } else {
                            Theme.surfaceHigh
                        }
                        // Laid over the stand-in and faded in, so the swap
                        // moves nothing.
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.35), value: image != nil)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: frameHeight * 9 / 16 + 40)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ax)
    }

    private func loadFrames() async {
        guard frames == nil else { return }
        if let key = cacheKey, let hit = Self.cache[key] {
            frames = hit
            return
        }
        // At once: the clip's poster as the free side, and a centre crop of
        // the same picture standing in for the PASS frame.
        if provisional == nil, let poster = request.poster {
            provisional = await Task.detached(priority: .userInitiated) {
                Self.standIns(from: poster)
            }.value
        }
        // Local originals only: a preview is not worth an iCloud download.
        // Without one the poster stand-ins stay.
        guard let segment = request.segment,
              let asset = await store.loadLocalAsset(request.session),
              !Task.isCancelled else { return }
        // The rally's last strike, where the point is decided; its middle
        // when the detector kept no strike times.
        let time = segment.hitTimes?.filter { $0 >= segment.start && $0 <= segment.end }.max()
            ?? (segment.start + segment.end) / 2
        let work = Task.detached(priority: .userInitiated) {
            await ClipExporter.passPreview(asset: asset, segment: segment, at: time)
        }
        // Closing the sheet stops the render instead of letting it finish
        // for nobody.
        let made = await withTaskCancellationHandler { await work.value }
            onCancel: { work.cancel() }
        guard let made, !Task.isCancelled else { return }
        let pair = (free: UIImage(cgImage: made.free), pass: UIImage(cgImage: made.pass))
        if let key = cacheKey {
            Self.cache[key] = pair
            Self.cacheOrder.removeAll { $0 == key }
            Self.cacheOrder.append(key)
            while Self.cacheOrder.count > 6 {
                Self.cache[Self.cacheOrder.removeFirst()] = nil
            }
        }
        frames = pair
    }

    /// The poster as-is, and its middle cut to a full-height 9:16 window —
    /// the shape of the PASS crop. On a free portrait poster the picture is
    /// the strip across the middle (a 16:9 frame at full width), so the
    /// window is that strip's height.
    nonisolated private static func standIns(from url: URL) -> (free: UIImage, pass: UIImage)? {
        guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage
        else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let windowH = h > w ? w * 9 / 16 : h
        let windowW = windowH * 9 / 16
        let rect = CGRect(x: (w - windowW) / 2, y: (h - windowH) / 2,
                          width: windowW, height: windowH).integral
        guard let crop = cg.cropping(to: rect) else { return nil }
        return (image, UIImage(cgImage: crop))
    }

    // MARK: Actions

    /// Primary and secondary the same size: "later" is a real choice here,
    /// not a fine-print escape, and it always works — even while the ad loads.
    @ViewBuilder private var actions: some View {
        VStack(spacing: 10) {
            primary
            Button {
                outcome = .declined
                ads.declinePassOffer()
                if request.passive { PassOfferGate.record(.declined) }
                dismiss()
            } label: {
                Text(L.s(request.declineKey, lang))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .rcSecondary()
            Button { showFull = true } label: {
                Text(L.s("offer_included", lang))
                    .font(.footnote.bold())
                    .underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    /// The same states as the full pass sheet: watch, loading, retry after
    /// failed loads, or no ads on this build at all.
    @ViewBuilder private var primary: some View {
        if ads.showing && ads.rewardedFailed && !ads.rewardedReady {
            Button { ads.retryRewarded() } label: {
                Label(L.s("pass_retry", lang), systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .rcPrimary()
            Text(L.s("pass_load_failed", lang))
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else if ads.showing {
            Button {
                ads.showRewarded { pass.grant() }
            } label: {
                HStack(spacing: 8) {
                    if !ads.rewardedReady { ProgressView().tint(Theme.onAccent) }
                    Text(L.s("offer_watch", lang))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .rcPrimary()
            .disabled(!ads.rewardedReady)
        } else {
            Text(L.s("pass_unavailable", lang))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

// MARK: - "PASS is on" toast

/// "PASS on · until 15:42", in the user's language and clock. Said once the
/// reward has landed and before the interrupted action carries on, so the
/// user knows why the next thing looks different.
@MainActor
func passOpenedText(_ pass: ProPass, _ lang: String) -> String {
    let f = DateFormatter()
    f.locale = L.locale(lang)
    f.timeStyle = .short
    f.dateStyle = .none
    return String(format: L.s("pass_opened_fmt", lang), f.string(from: pass.until ?? Date()))
}

/// A capsule that slides in at the top for a couple of seconds.
struct PassToast: ViewModifier {
    @Binding var text: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let text {
                Label(text, systemImage: "checkmark.seal.fill")
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.surfaceHigh, in: Capsule())
                    .padding(.top, 8)
                    .padding(.horizontal, 20)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.text = nil }
                    }
                    .onAppear {
                        UIAccessibility.post(notification: .announcement, argument: text)
                    }
            }
        }
        .animation(.easeOut(duration: 0.25), value: text)
    }
}

extension View {
    func passToast(_ text: Binding<String?>) -> some View { modifier(PassToast(text: text)) }
}
