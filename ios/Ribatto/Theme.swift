import SwiftUI

/// One place for the app's colours and surfaces.
///
/// Volt lime on near-black: it ties back to the ball in the app icon, reads as
/// sports rather than "generic dark app", and stays legible on video posters.
enum Theme {
    static let accent      = Color(red: 0.784, green: 0.965, blue: 0.243)
    /// Text and glyphs drawn on top of `accent`.
    static let onAccent    = Color(red: 0.055, green: 0.086, blue: 0.020)

    static let background  = Color(red: 0.039, green: 0.043, blue: 0.059)
    static let surface     = Color(red: 0.086, green: 0.094, blue: 0.118)
    static let surfaceHigh = Color(red: 0.129, green: 0.141, blue: 0.173)
    static let hairline    = Color.white.opacity(0.08)

    static let warning     = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let danger      = Color(red: 1.0, green: 0.42, blue: 0.42)

    /// Card background used across the app.
    static func card(_ radius: CGFloat = 16) -> some ShapeStyle { surface }
}

extension View {
    /// Standard elevated card: surface fill plus a hairline edge so panels
    /// separate from the background without heavy borders.
    func rcCard(_ radius: CGFloat = 16) -> some View {
        self
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Filter / choice pill. Selected pills are solid accent, unselected are
/// outlined — the old low-contrast grey fills were easy to miss entirely.
struct ChipStyle: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surfaceHigh),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(active ? .clear : Theme.hairline, lineWidth: 1))
            .foregroundStyle(active ? Theme.onAccent : Color.primary)
    }
}

extension View {
    func chip(active: Bool) -> some View { modifier(ChipStyle(active: active)) }
}


/// A tab's title and its actions on one row, drawn in the content rather than
/// by the navigation bar. A large title bar spends one row on the buttons and
/// a second on the title; on a tab with no buttons the first row is pure gap.
struct TabHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

/// The search field the tabs draw themselves. `.searchable` lives in the
/// navigation bar, and these tabs no longer have one.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.surface, in: Capsule())
    }
}


/// A row of equal-width controls that turns into a column at accessibility text
/// sizes. Held horizontal, each control keeps only 1/n of the width and short
/// labels like "Bottom" break in the middle of the word.
struct AdaptiveButtonRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: spacing) { content() }
        } else {
            HStack(spacing: spacing) { content() }
        }
    }
}


/// Marks a control that free users can see but not use yet.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 10, weight: .black))
            .tracking(0.5)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.accent, in: Capsule())
            .foregroundStyle(Theme.onAccent)
    }
}

// MARK: - Buttons

/// Solid accent button.
///
/// `.borderedProminent` draws its label white, which on volt lime is close to
/// invisible — every primary action in the app was affected. These styles pin
/// the pairing (accent fill, near-black label) so contrast can't drift.
struct RCPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(minHeight: 44)
            .background(Theme.accent.opacity(enabled ? 1 : 0.3), in: Capsule())
            .foregroundStyle(Theme.onAccent)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet companion to the primary button: same shape and height so rows of
/// buttons line up, but it recedes.
struct RCSecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(minHeight: 44)
            .background(Theme.surfaceHigh, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .foregroundStyle(destructive ? Theme.danger : Color.primary)
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func rcPrimary() -> some View { buttonStyle(RCPrimaryButton()) }
    func rcSecondary(destructive: Bool = false) -> some View {
        buttonStyle(RCSecondaryButton(destructive: destructive))
    }
}


extension CaptionColor {
    /// The same components `ClipExporter` burns in, as a SwiftUI colour, so the
    /// editor's preview and the exported frame cannot drift apart.
    var swiftUI: Color {
        let c = rgb
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}
