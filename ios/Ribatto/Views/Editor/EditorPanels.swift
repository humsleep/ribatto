import SwiftUI

/// The tool's controls, in place of the tool bar. The timeline stays visible
/// above, so every change is seen against the clip.
struct EditorPanel: View {
    @ObservedObject var m: EditorModel
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    let tool: EditorTool
    let session: Session?
    var onError: (String) -> Void
    var onDone: () -> Void
    @FocusState private var typing: Bool
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.s(tool.label, lang)).font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button {
                    typing = false
                    m.checkpoint()
                    m.tool = nil
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 32, height: 32)
                        .background(Theme.surfaceHigh, in: Circle())
                }
                .accessibilityLabel(L.s("done", lang))
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            // As tall as the controls, scrolling once they outgrow the cap
            // (large text): a fixed height left a two-option panel half empty,
            // and no cap ran the text panel off the bottom of the screen.
            ScrollView {
                padded.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 44), 230))
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.surface, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
    }

    private var padded: some View {
        content
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch tool {
        case .text: textPanel
        case .trim: trimPanel
        case .speed: speedPanel
        case .look: lookPanel
        case .zoom: zoomPanel
        case .sound:
            EditorSegmented(selection: binding(\.look.volume),
                            options: [(1.0, L.s("sound_full", lang)), (0.4, L.s("sound_low", lang)),
                                      (0.0, L.s("sound_off", lang))])
        case .background:
            EditorSegmented(selection: binding(\.look.backdrop),
                            options: [(Backdrop.blur, L.s("backdrop_blur", lang)),
                                      (Backdrop.black, L.s("backdrop_black", lang))])
        case .split: EmptyView()
        }
    }

    /// Writes the draft and makes the tap one undo step.
    private func binding<T>(_ key: WritableKeyPath<EditDraft, T>) -> Binding<T> {
        Binding(get: { m.draft[keyPath: key] },
                set: { m.draft[keyPath: key] = $0; m.checkpoint() })
    }

    // MARK: Text

    @ViewBuilder private var textPanel: some View {
        if let i = m.selectedSubtitle {
            let sub = Binding(get: { m.draft.subtitles[min(i, m.draft.subtitles.count - 1)] },
                              set: { if m.draft.subtitles.indices.contains(i) { m.draft.subtitles[i] = $0 } })
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField(L.s("ed_type_here", lang), text: sub.caption.text)
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit { m.checkpoint() }
                        .padding(.horizontal, 12).frame(height: 40)
                        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 10))
                    Button(role: .destructive) { m.deleteSelection() } label: {
                        Image(systemName: "trash").frame(width: 40, height: 40)
                            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .foregroundStyle(Theme.danger)
                    .accessibilityLabel(L.s("delete", lang))
                }
                row(L.s("font", lang)) {
                    ForEach(CaptionFont.allCases) { f in
                        Button { sub.wrappedValue.caption.font = f; m.checkpoint() } label: {
                            Text(L.s("font_" + f.rawValue, lang))
                                .font(f.font(size: 15))
                                .chip(active: sub.wrappedValue.caption.font == f)
                        }
                        .buttonStyle(.plain)
                    }
                }
                row(L.s("color", lang)) {
                    ForEach(CaptionColor.allCases) { c in
                        let on = sub.wrappedValue.caption.color == c
                        Button { sub.wrappedValue.caption.color = c; m.checkpoint() } label: {
                            Circle().fill(c.swiftUI).frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.rawValue)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                EditorSegmented(selection: sub.caption.style.onSet { m.checkpoint() },
                                options: [(CaptionStyle.plain, L.s("style_plain", lang)),
                                          (.bar, L.s("style_bar", lang)),
                                          (.accent, L.s("style_accent", lang)),
                                          (.outline, L.s("style_outline", lang))])
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(Theme.secondaryText)
                    Slider(value: sub.caption.size, in: 0.6...1.8) { editing in
                        if !editing { m.checkpoint() }
                    }
                    .tint(.white)
                    .accessibilityLabel(L.s("size", lang))
                    Image(systemName: "textformat.size.larger").foregroundStyle(Theme.secondaryText)
                }
                Text(L.s("drag_hint", lang)).font(.caption).foregroundStyle(Theme.tertiaryText)
            }
            .onAppear {
                if sub.wrappedValue.caption.text == L.s("ed_type_here", lang) {
                    sub.wrappedValue.caption.text = ""
                    typing = true
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                addButton(L.s("subs_add", lang), "plus") { m.addSubtitle(placeholder: L.s("ed_type_here", lang)) }
                // The way in for VoiceOver, where the bars cannot be tapped.
                ForEach(m.draft.subtitles) { s in
                    Button {
                        m.selection = .subtitle(s.id)
                        m.scrub(to: s.start, exact: true)
                    } label: {
                        HStack {
                            Text(s.caption.text.isEmpty ? L.s("subs_new", lang) : s.caption.text)
                                .foregroundStyle(Theme.primaryText).lineLimit(1)
                            Spacer()
                            Text(timecode(m.clock(s.start))).monospacedDigit()
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 40)
                        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ items: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Theme.tertiaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { items() }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }

    private func addButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .rcSecondary()
    }

    // MARK: Trim

    private var trimPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepper(L.s("trim_start", lang), value: \.start,
                    range: m.lower...max(m.lower, m.draft.end - m.minClip))
            stepper(L.s("trim_end", lang), value: \.end,
                    range: min(m.upper, m.draft.start + m.minClip)...m.upper)
            HStack {
                Text(L.s("length", lang)).font(.caption).foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(fmtDur(m.duration)).font(.subheadline.monospacedDigit().weight(.semibold))
            }
            if !m.hits.isEmpty {
                addButton(L.s("trim_fit_hits", lang), "arrow.right.and.line.vertical.and.arrow.left") {
                    m.fitToHits()
                }
            }
            Text(L.s("trim_ticks_hint", lang)).font(.caption).foregroundStyle(Theme.tertiaryText)
        }
    }

    private func stepper(_ title: String, value: WritableKeyPath<EditDraft, Double>,
                         range: ClosedRange<Double>) -> some View {
        Stepper {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(fmtPos(m.draft[keyPath: value])).font(.subheadline.monospacedDigit())
            }
        } onIncrement: {
            nudge(value, by: 0.25, in: range)
        } onDecrement: {
            nudge(value, by: -0.25, in: range)
        }
    }

    private func nudge(_ key: WritableKeyPath<EditDraft, Double>, by d: Double, in range: ClosedRange<Double>) {
        m.draft[keyPath: key] = min(max(m.draft[keyPath: key] + d, range.lowerBound), range.upperBound)
        m.checkpoint()
        m.scrub(to: key == \EditDraft.end ? m.draft.end - 0.05 : m.draft.start, exact: true)
    }

    // MARK: Speed

    private var speedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach([0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { v in
                    Button { binding(\.speed).wrappedValue = v } label: {
                        Text(v == 0.75 ? "0.75×" : String(format: "%g×", v))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .chip(active: m.draft.speed == v)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(m.draft.speed == v ? .isSelected : [])
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            HStack {
                Text(L.s("length", lang)).font(.caption).foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(fmtDur(m.duration)).font(.subheadline.monospacedDigit().weight(.semibold))
            }
            if m.draft.speed < 1 {
                Text(L.s("speed_hint", lang)).font(.caption).foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Look

    private var lookPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ClipFilter.allCases) { f in
                        let on = m.draft.look.filter == f
                        Button { binding(\.look.filter).wrappedValue = f } label: {
                            VStack(spacing: 6) {
                                Group {
                                    if let cg = m.lookThumbs[f] {
                                        Image(decorative: cg, scale: 1).resizable().scaledToFill()
                                    } else {
                                        Theme.surfaceHigh
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .padding(2)
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
                                Text(L.s("filter_" + f.rawValue, lang))
                                    .font(.caption.weight(on ? .semibold : .regular))
                                    .foregroundStyle(on ? Theme.primaryText : Theme.tertiaryText)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            Button {
                guard let session else { return }
                if store.isBusy(session.id) { onError(L.s("busy_wait", lang)); return }
                Task {
                    if await store.useLookForAll(session, m.draft.look) { onDone() }
                    else { onError(L.s("render_failed", lang)) }
                }
            } label: {
                Label(L.s("look_apply_all", lang), systemImage: "square.stack.3d.down.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Zoom

    private var zoomPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.s("ed_zoom_hint", lang)).font(.caption).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.secondaryText)
                // The slider sets the key at the playhead, making one if needed:
                // the same thing a pinch on the preview does, for VoiceOver.
                Slider(value: Binding(get: { m.zoomNow },
                                      set: { v in let i = m.keyAtPlayhead(); m.draft.zoomKeys[i].zoom = v }),
                       in: 1...3) { editing in if !editing { m.checkpoint() } }
                    .tint(.white)
                    .accessibilityLabel(L.s("edit_zoom", lang))
                    .accessibilityValue(String(format: "%.1f×", m.zoomNow))
                Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 10) {
                addButton(L.s("zoom_add", lang), "plus") {
                    m.pause()
                    _ = m.keyAtPlayhead()
                    m.checkpoint()
                }
                if m.selectedKey != nil {
                    Button(role: .destructive) { m.deleteSelection() } label: {
                        Image(systemName: "trash").frame(width: 50, height: 50)
                            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .foregroundStyle(Theme.danger)
                    .accessibilityLabel(L.s("delete", lang))
                }
            }
            if m.approximateFraming {
                Text(L.s("ed_approx", lang)).font(.caption).foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}

/// A choice between a few values. Grey, not volt: a segment is a choice, not
/// an action.
struct EditorSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.primaryText : Theme.secondaryText)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(on ? Color(white: 0.235) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 10))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

extension Binding {
    /// The same binding, calling `action` after each write.
    func onSet(_ action: @escaping () -> Void) -> Binding {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action() })
    }
}
