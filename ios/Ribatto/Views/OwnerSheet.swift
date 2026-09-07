import SwiftUI

/// Developer-only tier switch for the owner's own device.
///
/// TestFlight and App Store builds are Release, so the `#if DEBUG` shortcut
/// isn't there, and a real non-consumable purchase can never be undone — which
/// makes the free tier untestable on the one device that matters. This panel
/// solves both. It is reachable only by long-pressing the entitlement pill and
/// then entering a passphrase, so it offers a user nothing.
struct OwnerSheet: View {
    @EnvironmentObject var purchases: PurchaseManager
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""
    @State private var wrong = false

    var body: some View {
        NavigationStack {
            Group {
                if purchases.ownerMode { panel } else { gate }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(L.s("owner_title", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(.secondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var gate: some View {
        VStack(spacing: 14) {
            SecureField(L.s("owner_pass", lang), text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(attempt)
            if wrong {
                Text(L.s("owner_wrong", lang))
                    .font(.caption).foregroundStyle(Theme.danger)
            }
            Button(L.s("owner_enter", lang), action: attempt)
                .rcPrimary()
                .disabled(passphrase.isEmpty)
        }
    }

    private var panel: some View {
        VStack(spacing: 16) {
            Text(L.s("owner_sub", lang))
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 14) {
                Toggle(isOn: Binding(get: { purchases.ownerPro },
                                     set: { purchases.setOwnerPro($0) })) {
                    HStack(spacing: 8) {
                        Image(systemName: "crown.fill").foregroundStyle(Theme.accent)
                        Text(L.s("owner_pro", lang)).font(.subheadline.bold())
                    }
                }
                .tint(Theme.accent)

                Divider()

                HStack {
                    Text(String(format: L.s("free_left_fmt", lang), purchases.remainingFree))
                        .font(.subheadline)
                    Spacer()
                    Button(L.s("owner_reset", lang)) { purchases.resetFreeCounter() }
                        .rcSecondary()
                }
            }
            .padding(14)
            .rcCard()

            Button(L.s("owner_exit", lang)) {
                purchases.exitOwnerMode()
                dismiss()
            }
            .rcSecondary(destructive: true)
        }
    }

    private func attempt() {
        if purchases.unlockOwnerMode(passphrase: passphrase) {
            wrong = false
        } else {
            wrong = true
        }
        passphrase = ""
    }
}
