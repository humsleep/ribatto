import Pow
import StoreKit
import SwiftUI

/// Ribatto Pro: the three plans, what they open, and — for someone not ready
/// to pay — one job opened by a rewarded ad, up to `ProPass.dailyLimit` a day.
///
/// The buy button stays pinned to the bottom so it is on screen however long
/// the list is; the ad sits below the plans as the way to try first.
struct ProPassView: View {
    @EnvironmentObject var pass: ProPass
    @EnvironmentObject var ads: AdsManager
    @EnvironmentObject var purchases: PurchaseManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Name of the feature the user just tried to use, if any.
    var feature: String? = nil
    @State private var selected = PurchaseManager.yearly
    @State private var message: String?
    @State private var manage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if purchases.owned {
                        owned
                    } else {
                        plans
                        // At accessibility sizes the pinned bar grows until it
                        // owns the whole screen, so there it scrolls instead.
                        if typeSize.isAccessibilitySize { buyBlock }
                        adBlock
                    }
                    features
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if !typeSize.isAccessibilitySize && !purchases.owned {
                    buyBlock
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
            // A pass or a purchase is what this sheet was opened for: back to
            // the action that was interrupted.
            .onChange(of: pass.isPro) { _, pro in
                if pro { dismiss() }
            }
            .task {
                pass.refreshDay()
                if purchases.products.isEmpty { await purchases.refresh() }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil },
                                                       set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            }
            .manageSubscriptionsSheet(isPresented: $manage)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.18), .clear],
                                         center: .center, startRadius: 4, endRadius: 60))
                    .frame(width: 120, height: 120)
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
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
            Text(L.s("pro_sub", lang))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // What the free tier is, so the list below reads as a difference
            // rather than a brochure.
            Text(L.s("paywall_free_ads", lang))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Plans

    @ViewBuilder private var plans: some View {
        if purchases.products.isEmpty {
            VStack(spacing: 10) {
                if purchases.resolved {
                    Text(L.s("pro_unavailable", lang))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { Task { await purchases.refresh() } } label: {
                        Label(L.s("pass_retry", lang), systemImage: "arrow.clockwise")
                            .font(.subheadline.bold())
                    }
                    .rcSecondary()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(spacing: 10) {
                ForEach(purchases.products, id: \.id) { planRow($0) }
                Text(L.s("pro_renew_note", lang))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func planRow(_ p: Product) -> some View {
        let on = selected == p.id
        let title: String, price: String
        switch p.id {
        case PurchaseManager.monthly:
            title = L.s("plan_monthly", lang)
            price = String(format: L.s("plan_month_fmt", lang), p.displayPrice)
        case PurchaseManager.yearly:
            title = L.s("plan_yearly", lang)
            price = String(format: L.s("plan_year_fmt", lang), p.displayPrice)
        default:
            title = L.s("plan_lifetime", lang)
            price = String(format: L.s("plan_once_fmt", lang), p.displayPrice)
        }
        return Button { selected = p.id } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Theme.accent : Theme.tertiaryText)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if p.id == PurchaseManager.yearly, let save = yearlySaving {
                            Text(String(format: L.s("plan_save_fmt", lang), save))
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.18), in: Capsule())
                                .foregroundStyle(Theme.accent)
                                .fixedSize()
                        }
                    }
                    Text(price).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(on ? Theme.accent : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Whole percent the yearly plan saves against twelve months, from the
    /// store's own prices so it holds in every currency.
    private var yearlySaving: Int? {
        guard let m = purchases.product(PurchaseManager.monthly)?.price,
              let y = purchases.product(PurchaseManager.yearly)?.price, m > 0 else { return nil }
        let pct = Int(((1 - NSDecimalNumber(decimal: y / (m * 12)).doubleValue) * 100).rounded(.down))
        return pct >= 5 ? pct : nil
    }

    private var buyBlock: some View {
        VStack(spacing: 8) {
            Button {
                guard let p = purchases.product(selected) else { return }
                Task {
                    switch await purchases.purchase(p) {
                    case .bought, .cancelled: break
                    case .pending: message = L.s("pro_pending", lang)
                    case .failed, .unavailable: message = L.s("pro_failed", lang)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if purchases.busy { ProgressView().tint(Theme.onPrimary) }
                    Text(L.s("pro_buy", lang)).font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .rcPrimary()
            .disabled(purchases.product(selected) == nil || purchases.busy)
            HStack(spacing: 14) {
                Button(L.s("pro_restore", lang)) {
                    Task { if !(await purchases.restore()) { message = L.s("pro_restore_none", lang) } }
                }
                Link(L.s("pro_terms", lang),
                     destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link(L.s("pro_privacy", lang), destination: PrivacyView.policyURL)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .disabled(purchases.busy)
        }
    }

    private var owned: some View {
        VStack(spacing: 12) {
            Label(L.s("pro_owned", lang), systemImage: "checkmark.seal.fill")
                .font(.headline)
            Button(L.s("pro_manage", lang)) { manage = true }
                .font(.subheadline.bold())
                .rcSecondary()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
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

    // MARK: Ad pass

    private var adBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.s("pass_or", lang)).font(.subheadline.bold())
            Text(L.s("pass_watch_d", lang))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if pass.active {
                Label(L.s("pass_armed", lang), systemImage: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .fixedSize(horizontal: false, vertical: true)
            } else if pass.remainingToday == 0 {
                Text(L.s("pass_used_up", lang))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if ads.showing && ads.rewardedFailed && !ads.rewardedReady {
                Button { ads.retryRewarded() } label: {
                    Label(L.s("pass_retry", lang), systemImage: "arrow.clockwise")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .rcSecondary()
                Text(L.s("pass_load_failed", lang))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if ads.showing {
                Button {
                    ads.showRewarded { pass.grant() }
                } label: {
                    HStack(spacing: 8) {
                        if !ads.rewardedReady { ProgressView() }
                        Text(ads.rewardedReady
                             ? String(format: L.s("pass_watch_left_fmt", lang), pass.remainingToday)
                             : L.s("pass_loading", lang))
                            .font(.subheadline.bold())
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .rcSecondary()
                .disabled(!ads.rewardedReady)
                .conditionalEffect(.repeat(.shine(duration: 0.9), every: 3.0),
                                   condition: ads.rewardedReady && !reduceMotion)
            } else {
                // No ad SDK on this build, or it has not started: say so
                // rather than showing a button that can never load.
                Text(L.s("pass_unavailable", lang))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}
