import Pow
import SwiftUI

/// What Pro opens, and the one way to open it: a rewarded ad played to the end.
///
/// There is nothing to buy, so the ad is the primary action and sits where a
/// price would. It stays pinned to the bottom so it is on screen however long
/// the feature list is.
struct ProPassView: View {
    @EnvironmentObject var pass: ProPass
    @EnvironmentObject var ads: AdsManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Name of the feature the user just tried to use, if any.
    var feature: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    features
                    // At accessibility sizes the pinned bar grows until it owns
                    // the whole screen and the list cannot be reached, so there
                    // it scrolls with the content instead.
                    if typeSize.isAccessibilitySize { actionBlock }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if !typeSize.isAccessibilitySize {
                    actionBlock
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
                        .background(Theme.background.ignoresSafeArea())
                        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1),
                                 alignment: .top)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L.s("done", lang))
                        .tint(.secondary)
                }
            }
            .onChange(of: pass.isPro) { _, pro in
                if pro { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.35), .clear],
                                         center: .center, startRadius: 4, endRadius: 60))
                    .frame(width: 120, height: 120)
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            Text(L.s("paywall_title", lang))
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            if let feature {
                Label(L.locked(feature, lang), systemImage: "lock.fill")
                    .font(.subheadline.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.surfaceHigh, in: Capsule())
            }
            Text(String(format: L.s("pass_sub_fmt", lang), Int(ProPass.duration / 60)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // What the free tier is, so the list below reads as a difference
            // rather than a brochure.
            Text(L.s("paywall_free_ads", lang))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var features: some View {
        VStack(spacing: 14) {
            row("rectangle.badge.minus", L.s("feat_noads", lang), L.s("feat_noads_d", lang))
            row("4k.tv", L.s("feat_quality", lang), L.s("feat_quality_d", lang))
            row("drop.degreesign.slash", L.s("feat_nowm", lang), L.s("feat_nowm_d", lang))
            row("person.and.arrow.left.and.arrow.right",
                L.s("feat_smartcrop", lang), L.s("feat_smartcrop_d", lang))
            row("person.fill.viewfinder",
                L.s("feat_target", lang), L.s("feat_target_d", lang))
            row("photo.on.rectangle.angled", L.s("feat_saveall", lang), L.s("feat_saveall_d", lang))
            row("arrow.triangle.merge", L.s("merge", lang), L.s("feat_merge_d", lang))
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            // Decoration, not a control, so it is not drawn in the accent.
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actionBlock: some View {
        VStack(spacing: 10) {
            if pass.active {
                Label(String(format: L.s("pass_active_fmt", lang), pass.minutesLeft),
                      systemImage: "clock.badge.checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                // `grant` extends from the current end, so another ad before a
                // long render adds an hour instead of being turned away.
                if ads.rewardedReady {
                    Button {
                        ads.showRewarded { pass.grant() }
                    } label: {
                        Text(String(format: L.s("pass_extend_fmt", lang), Int(ProPass.duration / 60)))
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .rcSecondary()
                }
            } else if ads.showing && ads.rewardedFailed && !ads.rewardedReady {
                Button {
                    ads.retryRewarded()
                } label: {
                    Label(L.s("pass_retry", lang), systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .rcPrimary()
                Text(L.s("pass_load_failed", lang))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if ads.showing {
                Button {
                    ads.showRewarded { pass.grant() }
                } label: {
                    HStack(spacing: 8) {
                        if !ads.rewardedReady { ProgressView().tint(Theme.onAccent) }
                        Text(ads.rewardedReady
                             ? String(format: L.s("pass_watch_fmt", lang),
                                      Int(ProPass.duration / 60))
                             : L.s("pass_loading", lang))
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .rcPrimary()
                .disabled(!ads.rewardedReady)
                // A slow shine once the ad is loaded: the one moment the
                // button changes from "wait" to "press".
                .conditionalEffect(.repeat(.shine(duration: 0.9), every: 3.0),
                                   condition: ads.rewardedReady && !reduceMotion)
                Text(L.s("pass_watch_d", lang))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // No ad SDK on this build, or it has not started: say so
                // rather than showing a button that can never load.
                Text(L.s("pass_unavailable", lang))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            // Not localised on purpose: only a developer install can show it.
            // TestFlight used to show it too, but App Review installs carry the
            // same sandbox receipt, so the reviewer would have met an orange
            // debug line on the pass sheet. Google's own "Test mode" tag on
            // every test ad already tells a TestFlight tester what they see.
            if AdsManager.distribution == .debug {
                Text("TEST ADS — \(AdsManager.distribution.rawValue) install")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
    }
}
