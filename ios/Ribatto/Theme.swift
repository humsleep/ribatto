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
    // 2026-10-28 redesign (ios/REDESIGN_DIRECTIONS.md): a warm graphite ground
    // instead of the blue-black one, which fought the volt; a brighter volt;
    // and a court cyan kept for data only. Three colour roles, no more:
    // brand (accent), data (court), state (warning / danger).
    /// #D4FF3F. The same volt is burned into clips (`CaptionColor.volt`).
    static let accent      = Color(red: 0.831, green: 1.0, blue: 0.247)
    /// #0D1500. Text and glyphs drawn on top of `accent` (16.2:1).
    static let onAccent    = Color(red: 0.051, green: 0.082, blue: 0.0)

    static let background  = Color(red: 0.043, green: 0.047, blue: 0.039)   // #0B0C0A
    static let surface     = Color(red: 0.090, green: 0.098, blue: 0.082)   // #171915
    static let surfaceHigh = Color(red: 0.137, green: 0.149, blue: 0.122)   // #23261F
    static let hairline    = Color.white.opacity(0.09)
    /// #A6AC9D. Dates, hints, units, section headers: 6.6:1 or better on every
    /// surface, where `.tertiary` read 2.4:1.
    static let secondaryText = Color(red: 0.651, green: 0.675, blue: 0.616)
    /// #5CC8DE. Data only — waveforms, chart bars, ranges. Never on a button.
    static let court       = Color(red: 0.361, green: 0.784, blue: 0.871)

    static let warning     = Color(red: 1.0, green: 0.710, blue: 0.278)     // #FFB547
    static let danger      = Color(red: 1.0, green: 0.420, blue: 0.369)     // #FF6B5E

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
        // 16, the list's own inset: at 20 the title started inside the cards' edge.
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var titleText: some View {
        Text(title)
            // The app's typographic voice: heavy, condensed SF. Bebas has no
            // Dynamic Type and no CJK, so it stays in burned-in video text.
            .font(.largeTitle.weight(.heavy).width(.condensed))
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
            // 11pt and up with the text size, capped: 10pt Black closed up パス and 通行证.
            .font(.caption2.weight(.heavy))
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
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
            // Two lines before truncating: long German and Italian labels wrap.
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 50)
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
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 50)
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
