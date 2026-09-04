import SwiftUI

/// Compose the caption burned into every clip of a session. The preview is the
/// editor: drag the caption to put it wherever you want it.
struct CaptionEditorView: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss

    let session: Session
    @State private var draft: CaptionSettings
    @State private var dragging = false

    private let accent = Theme.accent

    init(session: Session) {
        self.session = session
        _draft = State(initialValue: session.caption ?? CaptionSettings())
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
                        store.setCaption(session, draft)
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
        let frame = OutputFrame(session.effectiveOrientation)
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
        if let img = UIImage(contentsOfFile: store.posterURL(session).path) {
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
        let size = max(9, height * 0.045 * draft.size)
        let text = Text(previewText)
            .font(draft.font.font(size: size))
            .lineLimit(1)
        let tint = draft.color.swiftUI
        let onFill: Color = draft.color.isLight ? Color(red: 0.05, green: 0.06, blue: 0.08) : .white
        let edge: Color = draft.color.isLight ? .black : .white
        return Group {
            switch draft.style {
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
                            Text(L.s(CaptionText.labelKey(token), lang)).chip(active: on)
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
            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.key) { preset in
                    Button {
                        draft.x = preset.x
                        draft.y = preset.y
                        draft.enabled = true
                    } label: {
                        Text(L.s(preset.key, lang))
                            .font(.caption.bold())
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
