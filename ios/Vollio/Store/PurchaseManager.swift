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
    /// The last answer the App Store gave about this purchase.
    ///
    /// Ownership lives on the Apple ID, not the device, so `currentEntitlements`
    /// restores a purchase on a new phone with no action from the user. What it
    /// cannot do is answer while StoreKit is unreachable — and an empty result
    /// reads exactly like "never bought". Caching the last real answer is what
    /// stops a first launch in airplane mode from quietly demoting someone who
    /// paid.
    private static let entitlementKey = "rc_entitled"

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

    /// Starts from the cached answer so a paying customer is Pro from the first
    /// frame, then is confirmed or corrected once the App Store replies.
    @Published private(set) var isPro =
        UserDefaults.standard.bool(forKey: PurchaseManager.entitlementKey)
    /// False until the App Store has answered once this launch. Anything that
    /// bakes the tier into a file — a render — waits for this.
    @Published private(set) var entitlementResolved = false
    @Published private(set) var product: Product?
    @Published private(set) var sessionsCreated =
        UserDefaults.standard.integer(forKey: PurchaseManager.counterKey)
    @Published var isPurchasing = false
    @Published var errorMessage: String?
    /// Set by the app so this type stays free of the L10n table; shown when the
    /// App Store has no product to sell (offline, or a store outage).
    var unavailableMessage = "Product unavailable"
    /// Shown when Restore completes and finds nothing. Without it the button
    /// spins and then looks broken, which is a common review complaint.
    var nothingToRestoreMessage = "No purchase found on this Apple ID"
    /// True once the owner passphrase has been accepted on this device.
    @Published private(set) var ownerMode =
        PurchaseManager.storedOwnerFlag(PurchaseManager.ownerModeKey)
    /// The owner's chosen tier while `ownerMode` is on.
    @Published private(set) var ownerPro =
        PurchaseManager.storedOwnerFlag(PurchaseManager.ownerProKey)

    /// Always false outside DEBUG, and it clears the stored value on the way
    /// past so a flag set in a development build cannot survive into the
    /// Release build installed over it.
    private static func storedOwnerFlag(_ key: String) -> Bool {
#if DEBUG
        return UserDefaults.standard.bool(forKey: key)
#else
        if UserDefaults.standard.object(forKey: key) != nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return false
#endif
    }

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
        // A successful product lookup is the evidence that StoreKit could be
        // reached, which is what makes an empty entitlement set trustworthy.
        await updateEntitlement(storeReachable: product != nil)
    }

    /// Suspends until the App Store has answered once, so a render started
    /// seconds after launch cannot bake a watermark into a paying customer's
    /// clips. Gives up after a few seconds: a dead network must not block the
    /// pipeline, and the cached answer is already in `isPro`.
    func waitForEntitlement() async {
        let deadline = Date().addingTimeInterval(5)
        while !entitlementResolved && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    func purchase() async {
        isPurchasing = true
        defer { isPurchasing = false }
        // A message from an earlier attempt must not outlive it, or a
        // successful purchase still shows the old failure underneath.
        errorMessage = nil

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
        if product == nil { errorMessage = unavailableMessage }
#endif
    }

    func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }
        errorMessage = nil
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
        await refresh()
        if !isPro { errorMessage = nothingToRestoreMessage }
    }

    private func redeem(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await updateEntitlement()
    }

    private func updateEntitlement(storeReachable: Bool = true) async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result,
               t.productID == Self.productID, t.revocationDate == nil {
                owned = true
            }
        }

        // An empty result means both "you never bought this" and "I couldn't
        // ask". Only the first is worth remembering; the second falls back to
        // what the App Store last said, so a flight or a store outage doesn't
        // hand a paying customer a watermark.
        if owned || storeReachable {
            UserDefaults.standard.set(owned, forKey: Self.entitlementKey)
        } else {
            owned = UserDefaults.standard.bool(forKey: Self.entitlementKey)
        }
        entitlementResolved = true

        // The overrides below are for testing and must never reach the cache.
#if DEBUG
        if UserDefaults.standard.bool(forKey: Self.testProKey) { owned = true }
#endif
        // The owner's switch wins in both directions, so the free tier can be
        // re-tested on a device that has genuinely bought Pro.
        //
        // DEBUG only, and not merely because of App Review: the switch that
        // turns it off lives behind a DEBUG-gated long press, so a device that
        // carried `rc_owner_mode = true` with the free tier selected into a
        // Release build had no way out — a real purchase would succeed and
        // still leave the user on the free tier for good.
#if DEBUG
        if ownerMode { owned = ownerPro }
#endif
        isPro = owned
    }
}
