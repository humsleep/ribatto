import SwiftUI
import UIKit

/// The opening seconds, picked up from the system launch screen.
///
/// The launch screen is the icon's ground colour alone (#091100) — an image
/// there was served from a stale system snapshot and came up blank — so this
/// view owns the whole entrance. The mark pops in, then the brand plays once: the ball is struck — a short squash, a rigid haptic
/// and three rings of sound leaving it, the same "strike" the app listens for
/// — and the wordmark lands under it before the whole card fades into the app.
///
/// About 1.6 s, any tap skips it, and Reduce Motion gets a still card and a
/// fade. Ads wait for `done` (RibattoApp), so the consent and tracking
/// prompts never land on top of it.
struct IntroView: View {
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var hit = false
    @State private var rings = false
    @State private var lifted = false
    @State private var wordmark = false
    @State private var leaving = false
    @State private var finished = false

    /// The launch screen's background, so the hand-off is seamless.
    static let ground = Color(red: 0.037, green: 0.069, blue: 0.0)
    private let logoSize: CGFloat = 120

    var body: some View {
        ZStack {
            Self.ground.ignoresSafeArea()
            // A faint volt glow that swells with the strike.
            RadialGradient(colors: [Theme.accent.opacity(rings ? 0.16 : 0), .clear],
                           center: .center, startRadius: 0, endRadius: 320)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    // Invisible until the strike, then each ring flashes and
                    // travels out — sound leaving the ball.
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(Theme.accent, lineWidth: 3)
                            .frame(width: logoSize, height: logoSize)
                            .keyframeAnimator(initialValue: Ring(), trigger: rings) { view, r in
                                view.scaleEffect(r.scale).opacity(r.opacity)
                            } keyframes: { _ in
                                KeyframeTrack(\.scale) {
                                    LinearKeyframe(0.9, duration: Double(i) * 0.09)
                                    CubicKeyframe(2.1 + Double(i) * 0.55, duration: 0.85)
                                }
                                KeyframeTrack(\.opacity) {
                                    LinearKeyframe(0, duration: Double(i) * 0.09)
                                    LinearKeyframe(0.6, duration: 0.05)
                                    CubicKeyframe(0, duration: 0.8)
                                }
                            }
                    }
                    // The mark alone (no icon tile): the glow behind it would
                    // otherwise outline the tile's dark square.
                    Image("AppMark")
                        .resizable()
                        .frame(width: logoSize, height: logoSize)
                        .modifier(StrikeScale(active: hit))
                        .scaleEffect(appeared ? 1 : 0.6)
                        .opacity(appeared ? 1 : 0)
                        .shadow(color: Theme.accent.opacity(rings ? 0.35 : 0), radius: 24)
                }
                .offset(y: lifted ? -18 : 0)

                Text("RIBATTO")
                    .font(.system(size: 46, weight: .black).width(.compressed).italic())
                    .tracking(wordmark ? 3 : 14)
                    .foregroundStyle(Theme.accent)
                    .opacity(wordmark ? 1 : 0)
                    .offset(y: wordmark ? -18 : 6)
                    .accessibilityHidden(true)
            }
            .offset(y: 18)
        }
        .opacity(leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ribatto")
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            appeared = true
            wordmark = true
            lifted = true
            try? await Task.sleep(for: .milliseconds(700))
            finish()
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.spring(response: 0.38, dampingFraction: 0.68)) { appeared = true }
        try? await Task.sleep(for: .milliseconds(380))
        // The strike.
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { hit = true }
        rings = true
        try? await Task.sleep(for: .milliseconds(320))
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            lifted = true
            wordmark = true
        }
        try? await Task.sleep(for: .milliseconds(1050))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeOut(duration: 0.35)) { leaving = true }
        Task {
            try? await Task.sleep(for: .milliseconds(360))
            done()
        }
    }
}

private struct Ring {
    var scale: CGFloat = 0.9
    var opacity: Double = 0
}

/// A quick squash and recoil, like a ball compressing on the strings.
private struct StrikeScale: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(1), trigger: active) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(0.88, duration: 0.08)
                SpringKeyframe(1.08, duration: 0.18, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.3, spring: .smooth)
            }
        }
    }
}

#Preview { IntroView {} }
