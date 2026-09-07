import SwiftUI

/// Compose the caption burned into every clip of a session. The preview is the
/// editor: drag the caption to put it wherever you want it.
struct CaptionEditorView: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss

    /// The session the preview borrows its poster and sample words from. For a
    /// reel that is simply the session its first rally came from.
    let session: Session
    /// The shape to preview in. A reel is vertical whatever its session was.
    private let previewFrame: OutputFrame
    /// Set when the caption belongs to something other than the session — a
    /// reel — in which case applying hands it back instead of writing it to
    /// the session.
    private let onApply: ((CaptionSettings) -> Void)?
    @State private var draft: CaptionSettings
    @State private var dragging = false

    private let accent = Theme.accent

    init(session: Session) {
        self.session = session
        self.previewFrame = OutputFrame(session.effectiveOrientation)
        self.onApply = nil
        _draft = State(initialValue: session.caption ?? CaptionSettings())
    }

    init(session: Session,
         caption: CaptionSettings?,
         frame: OutputFrame,
         onApply: @escaping (CaptionSettings) -> Void) {
        self.session = session
        self.previewFrame = frame
        self.onApply = onApply
        _draft = State(initialValue: caption ?? session.caption ?? CaptionSettings())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    Text(L.s("drag_hint", lang))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    textField
                    autoText
                    lookPicker
                    fontPicker
                    stylePicker
                    colorPicker
                    sizeSlider
                    quickPositions
                }
                .padding()
            }
            .navigationTitle(L.s("caption", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.s("cancel", lang)) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.s("apply", lang)) {
                        if let onApply { onApply(draft) } else { store.setCaption(session, draft) }
                        dismiss()
                    }
                    .font(.headline)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Preview / drag target

    private var preview: some View {
        let frame = previewFrame
        return GeometryReader { geo in
            let w = geo.size.width
            let h = w / frame.aspectRatio
            ZStack(alignment: .topLeading) {
                poster.frame(width: w, height: h).clipped()

                if draft.isVisible {
                    captionText(scaledTo: h)
                        .position(x: draft.x * w, y: draft.y * h)
                        .shadow(color: .black.opacity(dragging ? 0.6 : 0), radius: 10)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    dragging = true
                                    draft.x = min(max(Double(value.location.x / w), 0.04), 0.96)
                                    draft.y = min(max(Double(value.location.y / h), 0.04), 0.96)
                                }
                                .onEnded { _ in dragging = false }
                        )
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(dragging ? accent : .clear, lineWidth: 2))
        }
        .aspectRatio(frame.aspectRatio, contentMode: .fit)
        .frame(maxWidth: frame.isPortrait ? 260 : .infinity)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var poster: some View {
        if let img = PosterCache.load(store.posterURL(session)) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Theme.surfaceHigh
        }
    }

    /// What the caption will say on the session's best rally, so a token
    /// caption previews as words rather than braces.
    private var previewText: String {
        let segs = session.segments ?? []
        guard !segs.isEmpty else { return draft.text }
        let best = segs.indices.max { (segs[$0].score ?? -1) < (segs[$1].score ?? -1) } ?? 0
        return CaptionText.resolve(draft, session: session, segments: segs,
                                   index: best, lang: lang)?.text ?? draft.text
    }

    /// Mirrors what ClipExporter burns in: 4.5% of frame height × multiplier.
    private func captionText(scaledTo height: CGFloat) -> some View {
        Self.styled(previewText, font: draft.font, color: draft.color,
                    style: draft.style, size: max(9, height * 0.045 * draft.size))
    }

    /// One drawing of a caption, used by the live preview and by the preset
    /// chips so a chip can't promise a look the export won't produce.
    @ViewBuilder
    static func styled(_ string: String, font: CaptionFont, color: CaptionColor,
                       style: CaptionStyle, size: CGFloat) -> some View {
        let text = Text(string)
            .font(font.font(size: size))
            .lineLimit(1)
        let tint = color.swiftUI
        let onFill: Color = color.isLight ? Color(red: 0.05, green: 0.06, blue: 0.08) : .white
        let edge: Color = color.isLight ? .black : .white
        Group {
            switch style {
            case .plain:
                text.foregroundStyle(tint).shadow(radius: size * 0.35)
            case .bar:
                text.foregroundStyle(tint)
                    .padding(.horizontal, size * 0.72)
                    .padding(.vertical, size * 0.40)
                    .background(.black.opacity(0.55), in: Capsule())
            case .accent:
                text.foregroundStyle(onFill)
                    .padding(.horizontal, size * 0.72)
                    .padding(.vertical, size * 0.40)
                    .background(tint, in: Capsule())
            case .outline:
                // SwiftUI has no stroke on Text; four hard offset shadows
                // approximate the edge CoreText draws in the export.
                text.foregroundStyle(tint)
                    .shadow(color: edge, radius: 0, x: size * 0.045, y: 0)
                    .shadow(color: edge, radius: 0, x: -size * 0.045, y: 0)
                    .shadow(color: edge, radius: 0, x: 0, y: size * 0.045)
                    .shadow(color: edge, radius: 0, x: 0, y: -size * 0.045)
            }
        }
    }

    // MARK: - Presets

    /// A whole look in one tap. Font, colour and style travel together — those
    /// three are what make a caption read like a broadcast graphic or a vlog
    /// title, and picking them one control at a time is why the editor felt
    /// like a form. Size and position are left alone: they are the two the
    /// user has usually already set by dragging.
    struct CaptionLook: Identifiable {
        let id: String
        let font: CaptionFont
        let color: CaptionColor
        let style: CaptionStyle
    }

    /// Ordered the way you would flip through them: the quiet ones first, then
    /// the structured, then the loud. Between them they use every font, every
    /// colour and every style at least once — a preset that duplicates another
    /// one's look with a different name is a chip the user has to rule out.
    static let looks: [CaptionLook] = [
        .init(id: "clean",     font: .rounded,   color: .white, style: .plain),
        .init(id: "bar",       font: .rounded,   color: .white, style: .bar),
        // Solid black pill, white letters — the caption people expect on a
        // vertical video. `ink` only works filled: as text it disappears.
        .init(id: "subtitle",  font: .system,    color: .ink,   style: .accent),
        .init(id: "broadcast", font: .condensed, color: .white, style: .bar),
        .init(id: "data",      font: .mono,      color: .white, style: .bar),
        .init(id: "cool",      font: .condensed, color: .sky,   style: .bar),
        .init(id: "poster",    font: .anton,     color: .white, style: .outline),
        .init(id: "chalk",     font: .serif,     color: .white, style: .outline),
        .init(id: "volt",      font: .bebas,     color: .volt,  style: .accent),
        .init(id: "neon",      font: .rounded,   color: .volt,  style: .bar),
        .init(id: "gold",      font: .bebas,     color: .sun,   style: .accent),
        .init(id: "score",     font: .mono,      color: .sun,   style: .outline),
        .init(id: "punch",     font: .anton,     color: .rose,  style: .accent),
        .init(id: "editorial", font: .serif,     color: .white, style: .plain),
    ]

    private var lookPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.s("caption_presets", lang)).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Self.looks) { look in
                        let picked = draft.font == look.font && draft.color == look.color
                                     && draft.style == look.style
                        Button {
                            draft.font = look.font
                            draft.color = look.color
                            draft.style = look.style
                        } label: {
                            Self.styled("Aa", font: look.font, color: look.color,
                                        style: look.style, size: 17)
                                .frame(width: 66, height: 48)
                                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(picked ? Theme.accent : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        // The chips are samples, not text to read: at accessibility sizes they
        // would each grow to the width of the screen.
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    /// Swatches, drawn as themselves — the name of a colour tells you nothing.
    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.s("color", lang)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(CaptionColor.allCases) { c in
                    Button { draft.color = c } label: {
                        Circle()
                            .fill(c.swiftUI)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(
                                draft.color == c ? accent : Color.white.opacity(0.25),
                                lineWidth: draft.color == c ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
    }

    // MARK: - Controls

    private var textField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L.s("show_caption", lang), isOn: $draft.enabled)
                .tint(accent)
            HStack {
                TextField(L.s("caption_placeholder", lang), text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                Button(L.s("use_date", lang)) {
                    draft.text = L.dateOnly(session.playedAt, lang)
                    draft.enabled = true
                }
                .font(.caption.bold())
                .rcSecondary()
            }
        }
    }

    /// Placeholders filled per clip at render time. A chip toggles its token
    /// in and out of the text; the preview above shows the filled-in result.
    private var autoText: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.s("auto_text", lang)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L.s("auto_example", lang)) {
                    draft.text = CaptionText.example
                    draft.enabled = true
                }
                .font(.caption.bold())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CaptionText.tokens, id: \.self) { token in
                        let on = draft.text.contains(token)
                        Button {
                            draft.text = on ? CaptionText.removing(token, from: draft.text)
                                            : CaptionText.adding(token, to: draft.text)
                            draft.enabled = true
                        } label: {
                            Text(L.s(CaptionText.labelKey(token), lang))
                                .lineLimit(1)
                                .chip(active: on)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            Text(L.s("auto_text_d", lang))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Chips rendered in their own typeface — you pick by look, not by name.
    private var fontPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.s("font", lang)).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CaptionFont.allCases) { f in
                        Button { draft.font = f } label: {
                            Text(L.s("font_" + f.rawValue, lang))
                                .font(f.font(size: 15))
                                .lineLimit(1)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(draft.font == f
                                            ? AnyShapeStyle(.tint)
                                            : AnyShapeStyle(Theme.surfaceHigh),
                                            in: Capsule())
                                .foregroundStyle(draft.font == f ? .black : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.s("style", lang)).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $draft.style) {
                Text(L.s("style_plain", lang)).tag(CaptionStyle.plain)
                Text(L.s("style_bar", lang)).tag(CaptionStyle.bar)
                Text(L.s("style_accent", lang)).tag(CaptionStyle.accent)
                Text(L.s("style_outline", lang)).tag(CaptionStyle.outline)
            }
            .pickerStyle(.segmented)
        }
    }

    private var sizeSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.s("size", lang)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", draft.size * 100))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $draft.size, in: 0.6...1.8, step: 0.05).tint(accent)
        }
    }

    /// Shortcuts for the corners people actually use.
    private var quickPositions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.s("position", lang)).font(.caption).foregroundStyle(.secondary)
            AdaptiveButtonRow {
                ForEach(Self.presets, id: \.key) { preset in
                    Button {
                        draft.x = preset.x
                        draft.y = preset.y
                        draft.enabled = true
                    } label: {
                        Text(L.s(preset.key, lang))
                            .font(.caption.bold())
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .rcSecondary()
                }
            }
        }
    }

    private static let presets: [(key: String, x: Double, y: Double)] = [
        ("pos_top", 0.5, 0.10),
        ("pos_center", 0.5, 0.5),
        ("pos_bottom", 0.5, 0.90),
    ]
}

extension CaptionFont {
    var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        case .system, .condensed, .anton, .bebas: return .default
        }
    }
    var width: Font.Width { self == .condensed ? .compressed : .standard }

    /// The face applied to both the preview and the burned caption.
    func font(size: CGFloat) -> Font {
        if let bundledName {
            _ = ClipExporter.bundledFontsRegistered
            // fixedSize: a display face at a size the preview computed from the
            // frame must not then be scaled again by Dynamic Type.
            return .custom(bundledName, fixedSize: size)
        }
        return .system(size: size, weight: .heavy, design: design).width(width)
    }
}
