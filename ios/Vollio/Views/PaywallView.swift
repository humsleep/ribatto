import StoreKit
import SwiftUI

struct PaywallView: View {
    @EnvironmentObject var purchases: PurchaseManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    /// Name of the feature the user just tried to use, if any.
    var feature: String? = nil

    private let accent = Theme.accent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    features
                    priceBlock
                    Text(L.s("paywall_note", lang))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
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
            .onChange(of: purchases.isPro) { _, pro in
                if pro { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [accent.opacity(0.35), .clear],
                                         center: .center, startRadius: 4, endRadius: 90))
                    .frame(width: 180, height: 180)
                Image(systemName: "scissors")
                    .font(.system(size: 56, weight: .medium))
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
            Text(feature == nil ? L.s("paywall_sub", lang) : L.s("paywall_sub_feature", lang))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(spacing: 14) {
            row("infinity", L.s("feat_unlimited", lang), L.s("feat_unlimited_d", lang))
            row("4k.tv", L.s("feat_quality", lang), L.s("feat_quality_d", lang))
            row("person.and.arrow.left.and.arrow.right",
                L.s("feat_smartcrop", lang), L.s("feat_smartcrop_d", lang))
            row("person.fill.viewfinder",
                L.s("feat_target", lang), L.s("feat_target_d", lang))
            row("photo.on.rectangle.angled", L.s("feat_saveall", lang), L.s("feat_saveall_d", lang))
            row("sportscourt", L.s("feat_sports", lang), L.s("feat_sports_d", lang))
            row("iphone.gen3", L.s("feat_offline", lang), L.s("feat_offline_d", lang))
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

    private var priceBlock: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(purchases.priceText).font(.system(size: 34, weight: .heavy))
                Text(L.s("once", lang)).font(.subheadline.bold()).foregroundStyle(.secondary)
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
            .disabled(purchases.isPurchasing)

            if let err = purchases.errorMessage {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
    }
}
