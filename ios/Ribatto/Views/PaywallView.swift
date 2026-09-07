import StoreKit
import SwiftUI

struct PaywallView: View {
    @EnvironmentObject var purchases: PurchaseManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Name of the feature the user just tried to use, if any.
    var feature: String? = nil

    private let accent = Theme.accent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    features
                    // At accessibility sizes the pinned bar below grows until
                    // it owns the whole screen and the feature list cannot be
                    // reached at all, so there it scrolls with the content
                    // instead.
                    if typeSize.isAccessibilitySize { priceBlock }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            // Otherwise the price and the button stay on screen however long
            // the list is; a buyer should never have to hunt for them.
            .safeAreaInset(edge: .bottom) {
                if !typeSize.isAccessibilitySize {
                    priceBlock
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
                        .background(Theme.background.ignoresSafeArea())
                        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1),
                                 alignment: .top)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.s("restore", lang)) {
                        Task { await purchases.restore() }
                    }
                    .font(.footnote)
                }
            }
            // StoreKit is only queried at launch, so an app first opened
            // offline had no product and a permanently dead Unlock button.
            .task { await purchases.refresh() }
            .onChange(of: purchases.isPro) { _, pro in
                if pro { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var subtitleKey: String {
        if feature != nil { return L.s("paywall_sub_feature", lang) }
        return purchases.remainingFree > 0 ? L.s("paywall_sub_open", lang)
                                           : L.s("paywall_sub", lang)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [accent.opacity(0.35), .clear],
                                         center: .center, startRadius: 4, endRadius: 60))
                    .frame(width: 120, height: 120)
                Image(systemName: "scissors")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(accent)
            }
            Text(L.s("paywall_title", lang))
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            if let feature {
                Label(L.locked(feature, lang), systemImage: "lock.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
            }
            // "You've used your free imports" is only true when they are gone;
            // the pill opens this screen at any time.
            Text(subtitleKey)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Against a subscription competitor this line is the pitch, so it
            // belongs here rather than in grey type at the bottom.
            Label(L.s("no_sub_pitch", lang), systemImage: "checkmark.seal.fill")
                .font(.footnote.bold())
                .foregroundStyle(accent)
                .multilineTextAlignment(.center)
            // What the free tier actually is, so the list below reads as a
            // difference rather than a brochure.
            Text(String(format: L.s("paywall_free_fmt", lang), PurchaseManager.freeLimit))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var features: some View {
        VStack(spacing: 14) {
            row("infinity", L.s("feat_unlimited", lang), L.s("feat_unlimited_d", lang))
            row("4k.tv", L.s("feat_quality", lang), L.s("feat_quality_d", lang))
            row("drop.degreesign.slash", L.s("feat_nowm", lang), L.s("feat_nowm_d", lang))
            row("person.and.arrow.left.and.arrow.right",
                L.s("feat_smartcrop", lang), L.s("feat_smartcrop_d", lang))
            row("person.fill.viewfinder",
                L.s("feat_target", lang), L.s("feat_target_d", lang))
            row("number.circle.fill", L.s("shot_counter", lang), L.s("feat_counter_d", lang))
            row("checkerboard.rectangle", L.s("scoreboard", lang), L.s("scoreboard_d", lang))
            row("photo.on.rectangle.angled", L.s("feat_saveall", lang), L.s("feat_saveall_d", lang))
            row("arrow.triangle.merge", L.s("merge", lang), L.s("feat_merge_d", lang))
        }
        .padding(16)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// A dead Unlock button is right in a shipped build — with no product
    /// there is nothing to buy, and the price above says so — but wrong in a
    /// test build. Launched outside Xcode the `.storekit` config never loads,
    /// so `product` stays nil, and `purchase()`'s DEBUG fallback that unlocks
    /// Pro locally sits behind a button that can never be pressed. That is the
    /// "stuck on loading the price" dead end, and it made the Pro paths
    /// untestable anywhere but a scheme-launched run.
    private var unlockDisabled: Bool {
#if DEBUG
        purchases.isPurchasing
#else
        purchases.isPurchasing || purchases.product == nil
#endif
    }

    private var priceBlock: some View {
        VStack(spacing: 12) {
            // StoreKit may still be fetching the product: a dash next to
            // "once" looked broken, so say what is happening instead.
            if purchases.product == nil {
                VStack(spacing: 6) {
                    Text(L.s("price_loading", lang))
                        .font(.subheadline.bold()).foregroundStyle(.secondary)
                    Button(L.s("retry", lang)) { Task { await purchases.refresh() } }
                        .font(.caption.bold())
                }
                .frame(minHeight: 40)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(purchases.priceText).font(.system(size: 34, weight: .heavy))
                    Text(L.s("once", lang)).font(.subheadline.bold()).foregroundStyle(.secondary)
                }
            }
            Text(L.s("no_subscription", lang))
                .font(.footnote.bold())
                .foregroundStyle(accent)

            Button {
                Task { await purchases.purchase() }
            } label: {
                ZStack {
                    if purchases.isPurchasing {
                        ProgressView().tint(.black)
                    } else {
                        Text(L.s("unlock", lang)).font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .rcPrimary()
            .tint(accent)
            .foregroundStyle(.black)
            .disabled(unlockDisabled)

            if let err = purchases.errorMessage {
                Text(err).font(.caption2).foregroundStyle(Theme.danger)
            }
            Text(L.s("paywall_note", lang))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}
