#if DEBUG
import SwiftUI

/// Debug builds only: turn Pro on without an ad, or end the pass early, so both
/// tiers can be tested on one device. Reached by long-pressing the tier pill.
///
/// Compiled out of Release on purpose — a hidden switch that grants Pro is
/// undocumented functionality, which App Review rejects under 2.3.1. The labels
/// are plain English for the same reason: no user ever sees them.
struct DebugProSheet: View {
    @EnvironmentObject var pass: ProPass
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Force Pro", isOn: Binding(get: { pass.debugPro },
                                                  set: { pass.setDebugPro($0) }))
                Section {
                    Button("Grant a pass") { pass.grant() }
                    Button("End pass", role: .destructive) { pass.endPass() }
                } footer: {
                    Text(pass.active ? "Pass: \(pass.minutesLeft) min left" : "No pass")
                }
            }
            .navigationTitle("Debug · Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
