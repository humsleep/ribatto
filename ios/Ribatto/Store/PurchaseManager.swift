import Foundation
import StoreKit

/// Ribatto Pro, sold three ways: monthly and yearly subscriptions in one group,
/// and a lifetime unlock. Owning any of them makes `owned` true.
///
/// Restored from the `pro-iap-snapshot` tag (a single one-time unlock) and cut
/// down: no owner passphrase, no import counter, no pass — the pass is
/// `ProPass`'s alone.
@MainActor
final class PurchaseManager: ObservableObject {
    static let monthly = "com.ribatto.pro.monthly"
    static let yearly = "com.ribatto.pro.yearly"
    static let lifetime = "com.ribatto.pro.lifetime"
    static let ids = [monthly, yearly, lifetime]
    /// The last answer the App Store gave. Ownership lives on the Apple ID, so
    /// `currentEntitlements` restores it on a new phone; what it cannot do is
    /// answer while StoreKit is unreachable, and an empty result then reads
    /// exactly like "never bought". The cache stops an offline launch from
    /// demoting someone who paid.
    private static let ownedKey = "rc_entitled"

    enum Outcome { case bought, cancelled, pending, failed, unavailable }

    /// In `ids` order, once the App Store has answered.
    @Published private(set) var products: [Product] = []
    @Published private(set) var owned = UserDefaults.standard.bool(forKey: PurchaseManager.ownedKey)
    /// False until the App Store has answered once this launch.
    @Published private(set) var resolved = false
    @Published private(set) var busy = false
    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates { await self?.redeem(result) }
        }
        Task { await refresh() }
    }

    deinit { updates?.cancel() }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    func refresh() async {
        if products.isEmpty, let found = try? await Product.products(for: Self.ids) {
            products = found.sorted { (Self.ids.firstIndex(of: $0.id) ?? 9) < (Self.ids.firstIndex(of: $1.id) ?? 9) }
        }
        // Products that loaded are the evidence the store could be reached,
        // which is what makes an empty entitlement set trustworthy.
        await updateOwned(storeReachable: !products.isEmpty)
    }

    /// Suspends until the App Store has answered once, for at most a few
    /// seconds: a buyer reinstalling must not meet the ad consent form, and a
    /// dead network must not hold up launch.
    func waitUntilResolved() async {
        let deadline = Date().addingTimeInterval(4)
        while !resolved && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    func purchase(_ product: Product) async -> Outcome {
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await redeem(verification)
                return owned ? .bought : .failed
            case .userCancelled: return .cancelled
            case .pending: return .pending
            @unknown default: return .failed
            }
        } catch {
            return .failed
        }
    }

    /// True when something was found to restore.
    func restore() async -> Bool {
        busy = true
        defer { busy = false }
        try? await AppStore.sync()
        await refresh()
        return owned
    }

    private func redeem(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await updateOwned()
    }

    private func updateOwned(storeReachable: Bool = true) async {
        var found = false
        // Active subscriptions and owned unlocks only; a refund sets revocation.
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, Self.ids.contains(t.productID), t.revocationDate == nil {
                found = true
            }
        }
        // An empty set means both "never bought" and "couldn't ask". Only the
        // first is worth remembering; the second keeps the last answer.
        if found || storeReachable {
            UserDefaults.standard.set(found, forKey: Self.ownedKey)
        } else {
            found = UserDefaults.standard.bool(forKey: Self.ownedKey)
        }
        owned = found
        resolved = true
    }
}
