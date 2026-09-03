import CryptoKit
import Foundation
import StoreKit

/// One-time unlock. The free tier allows `freeLimit` imported sessions;
/// after that, importing requires Pro. Counting uses a lifetime counter so
/// deleting sessions doesn't hand out more free imports.
@MainActor
final class PurchaseManager: ObservableObject {
    static let productID = "com.vollio.pro"
#if DEBUG
    /// Debug builds only — lets Pro be exercised without a StoreKit product.
    /// Never compiled into a Release/App Store build.
    static let testProKey = "rc_test_pro"
#endif
    static let freeLimit = 3
    private static let counterKey = "rc_sessions_created"

    // MARK: Owner override
    //
    // Lets the developer's own device flip between free and Pro in a Release
    // build, which neither the DEBUG path nor a real purchase can do: TestFlight
    // and App Store builds are Release, and a bought non-consumable can't be
    // un-bought. Gated behind a passphrase only the owner knows, and reachable
    // only by long-pressing the entitlement pill, so it isn't discoverable
    // — it grants nothing to a user who stumbles into it.
    //
    // Stored as a hash so the passphrase itself never appears in the binary.
    // To change it: shasum -a 256 <<< "new phrase" (without a trailing newline:
    // printf '%s' "new phrase" | shasum -a 256).
    private static let ownerHash =
        "be63bbfcef9bdb67fb6b8ed1085f20cc4b796511bd66a7f8f3d27642a7a38bf8"
    private static let ownerModeKey = "rc_owner_mode"
    private static let ownerProKey = "rc_owner_pro"

    @Published private(set) var isPro = false
    @Published private(set) var product: Product?
    @Published private(set) var sessionsCreated =
        UserDefaults.standard.integer(forKey: PurchaseManager.counterKey)
    @Published var isPurchasing = false
    @Published var errorMessage: String?
    /// True once the owner passphrase has been accepted on this device.
    @Published private(set) var ownerMode =
        UserDefaults.standard.bool(forKey: PurchaseManager.ownerModeKey)
    /// The owner's chosen tier while `ownerMode` is on.
    @Published private(set) var ownerPro =
        UserDefaults.standard.bool(forKey: PurchaseManager.ownerProKey)

    private var updateTask: Task<Void, Never>?

    init() {
        updateTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.redeem(result)
            }
        }
        Task { await refresh() }
    }

    deinit { updateTask?.cancel() }

    var remainingFree: Int { max(0, Self.freeLimit - sessionsCreated) }
    var canImport: Bool { isPro || remainingFree > 0 }
    /// Only StoreKit knows the price in the viewer's storefront. A hard-coded
    /// fallback would show the wrong currency to most of the world and a stale
    /// number to everyone, so an unloaded product shows a placeholder instead —
    /// the purchase can't proceed in that state anyway.
    var priceText: String { product?.displayPrice ?? "—" }

    func noteSessionCreated() {
        sessionsCreated += 1
        UserDefaults.standard.set(sessionsCreated, forKey: Self.counterKey)
    }

    // MARK: - Owner override

    /// Returns false on a wrong passphrase; the caller shows nothing either way
    /// so a bystander learns nothing from trying.
    func unlockOwnerMode(passphrase: String) -> Bool {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == Self.ownerHash else { return false }
        ownerMode = true
        UserDefaults.standard.set(true, forKey: Self.ownerModeKey)
        return true
    }

    func setOwnerPro(_ on: Bool) {
        ownerPro = on
        UserDefaults.standard.set(on, forKey: Self.ownerProKey)
        Task { await updateEntitlement() }
    }

    func exitOwnerMode() {
        ownerMode = false
        ownerPro = false
        UserDefaults.standard.set(false, forKey: Self.ownerModeKey)
        UserDefaults.standard.set(false, forKey: Self.ownerProKey)
        Task { await updateEntitlement() }
    }

    /// The owner can also hand themselves free imports back.
    func resetFreeCounter() {
        sessionsCreated = 0
        UserDefaults.standard.set(0, forKey: Self.counterKey)
    }

    // MARK: - StoreKit

    func refresh() async {
        if product == nil {
            product = try? await Product.products(for: [Self.productID]).first
        }
        await updateEntitlement()
    }

    func purchase() async {
        isPurchasing = true
        defer { isPurchasing = false }

        if let product {
            do {
                switch try await product.purchase() {
                case .success(let verification):
                    await redeem(verification)
                    return
                case .userCancelled, .pending:
                    return
                @unknown default:
                    return
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

#if DEBUG
        // Running without the .storekit config (e.g. launched outside Xcode):
        // unlock locally so the Pro paths can still be tested.
        UserDefaults.standard.set(true, forKey: Self.testProKey)
        errorMessage = nil
        await updateEntitlement()
#else
        if product == nil { errorMessage = "Product unavailable" }
#endif
    }

    func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }
#if DEBUG
        // In test builds the Restore button doubles as "back to free" so the
        // free tier can be re-tested without reinstalling.
        if UserDefaults.standard.bool(forKey: Self.testProKey) {
            UserDefaults.standard.set(false, forKey: Self.testProKey)
            await updateEntitlement()
            return
        }
#endif
        try? await AppStore.sync()
        await updateEntitlement()
    }

    private func redeem(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await updateEntitlement()
    }

    private func updateEntitlement() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result,
               t.productID == Self.productID, t.revocationDate == nil {
                owned = true
            }
        }
#if DEBUG
        if UserDefaults.standard.bool(forKey: Self.testProKey) { owned = true }
#endif
        // The owner's switch wins in both directions, so the free tier can be
        // re-tested on a device that has genuinely bought Pro.
        if ownerMode { owned = ownerPro }
        isPro = owned
    }
}
