import SwiftUI

/// Title card shown for a moment on every cold launch.
///
/// English only, whatever the in-app language: "Ribatto" is a name, and the
/// one-line tagline under it is part of the mark rather than something to read.
///
/// The system launch screen (UILaunchScreen in Ribatto-Info.plist) draws the
/// same logo at the same size in the same place, so this view starts where the
/// launch screen left off — the logo lifts and the name fades in under it,
/// with no jump between the two.
struct IntroView: View {
    /// Called once, when the card should go away.
    var finished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var done = false

    private static let logoSize: CGFloat = 120

    init(finished: @escaping () -> Void) {
        self.finished = finished
        _ = ClipExporter.bundledFontsRegistered
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            // Soft court-green glow behind the logo, the same teal as the icon.
            RadialGradient(colors: [Color(red: 0.12, green: 0.42, blue: 0.47).opacity(0.45), .clear],
                           center: .center, startRadius: 0, endRadius: 320)
                .ignoresSafeArea()
                .opacity(revealed ? 1 : 0)

            Image("AppLogo")
                .resizable()
                .frame(width: Self.logoSize, height: Self.logoSize)
                .shadow(color: Theme.accent.opacity(revealed ? 0.25 : 0), radius: 24)
                .offset(y: revealed ? -70 : 0)

            VStack(spacing: 10) {
                Text("RIBATTO")
                    .font(.custom("BebasNeue-Regular", fixedSize: 64))
                    .tracking(6)
                    .foregroundStyle(.white)
                Text("Every rally, cut for reels.")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: revealed ? 44 : 0, height: 4)
                    .padding(.top, 6)
            }
            .offset(y: 70)
            .opacity(revealed ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ribatto")
        .accessibilityAddTraits(.isHeader)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2)
                                       : .spring(response: 0.6, dampingFraction: 0.8)) {
                revealed = true
            }
            try? await Task.sleep(for: .seconds(1.6))
            finish()
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        finished()
    }
}

#Preview { IntroView {} }
