import SwiftUI

/// One place for the app's colours and surfaces.
///
/// Volt lime on near-black: it ties back to the ball in the app icon, reads as
/// sports rather than "generic dark app", and stays legible on video posters.
///
/// Where the accent is allowed: things you can press, and the thing that is
/// currently selected. Not values, not status text, not row decoration — a
/// screen that paints its counts, its stats and its list glyphs in the accent
/// has nothing left to mark the one button that matters, which is what the
/// library, session and season screens had become.
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
/// Scrolls its content only when asked to.
///
/// A sheet whose main content is a video cannot live in a ScrollView at normal
/// sizes — the player would collapse to its ideal height instead of filling the
/// screen. At accessibility sizes the opposite is true: the controls alone are
/// taller than the phone, and in a fixed stack they squeeze the video to
/// nothing and drive the last button off the bottom.
struct AdaptiveScroll<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        if scrolls {
            ScrollView { content() }
        } else {
            content()
        }
    }
}

/// A tab's empty state: centred while it fits, scrollable once it does not.
///
/// Filling the space is not enough on its own. At accessibility sizes the
/// icon, the two lines of explanation and the buttons are taller than the
/// screen, and a view that cannot scroll answers that by truncating its text —
/// the first screen of a new install read "Ancora nessuna parti…".
struct EmptyStateBox<Content: View>: View {
    @ViewBuilder var content: () -> Content

    /// Matches the spacer the scrolling tabs put at the end of their lists:
    /// the tab bar floats over the content, and without the clearance the last
    /// button of a tall empty state ends its scroll underneath it.
    private let tabBarClearance: CGFloat = 62

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity,
                           minHeight: max(0, geo.size.height - tabBarClearance))
                    .padding(.bottom, tabBarClearance)
            }
        }
    }
}

struct TabHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        Group {
            // Side by side there is no width left for a long title once the
            // actions have taken theirs: German at the largest setting showed
            // "Meine Matches" as "Mein…" and its button as "Auswä…". The rest
            // of the app stacks its rows at these sizes; the header does too.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    titleText
                    HStack(spacing: 10) {
                        actions
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleText
                    Spacer(minLength: 4)
                    actions
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var titleText: some View {
        Text(title)
            .font(.largeTitle.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// Bounded even when stacked: unbounded, a two-syllable button wrapped
    /// mid-word and the icon glyphs grew as tall as three lines.
    private var actions: some View {
        trailing()
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .lineLimit(1)
    }
}

/// The search field the tabs draw themselves. `.searchable` lives in the
/// navigation bar, and these tabs no longer have one.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    @AppStorage("rc_lang") private var lang = "en"

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
                .accessibilityLabel(L.s("clear", lang))
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
///
/// Tinted rather than filled: a solid accent capsule is what the primary
/// buttons look like, so a badge drawn that way reads as something to press.
/// Four of them sat on the session screen next to one real button.
struct ProBadge: View {
    @AppStorage("rc_lang") private var lang = "en"

    var body: some View {
        Text(L.s("pro", lang).uppercased())
            .font(.system(size: 10, weight: .black))
            .tracking(0.5)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.accent.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1))
            .foregroundStyle(Theme.accent)
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
