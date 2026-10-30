import AVFoundation
import SwiftUI

/// The clip editor: the clip as it will come out, a timeline under a fixed
/// playhead, and one tool at a time. Nothing is written until Done, which
/// re-encodes only this clip through `SessionStore.trimClip`.
///
/// Built after Instagram's Edits: preview, transport, timeline, tool bar.
/// The model is `EditorModel`; the parts are in Views/Editor/.
struct TrimSheet: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    let clip: ClipInfo
    /// The tool the editor opens on.
    var focus: Focus? = nil

    enum Focus: Hashable { case speed, trim, split, look, text, zoom }

    @StateObject private var m: EditorModel
    @State private var working = false
    @State private var message: String?
    @State private var confirmDiscard = false
    @State private var confirmSplit = false

    init(clip: ClipInfo, focus: Focus? = nil, minClip: Double = 1.5, session: Session? = nil) {
        self.clip = clip
        self.focus = focus
        _m = StateObject(wrappedValue: EditorModel(clip: clip, session: session, minClip: minClip))
    }

    private var session: Session? { store.sessions.first { $0.id == clip.sessionID } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            EditorPreview(m: m)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .frame(minHeight: 170, maxHeight: .infinity)
                .overlay { if working { renderingOverlay } }
                .overlay { if m.sourceMissing { missing } }
            transport
            EditorTimeline(m: m)
                .padding(.top, 4)
            Group {
                if let tool = m.tool, tool != .split {
                    EditorPanel(m: m, tool: tool, session: session,
                                onError: { message = $0 }, onDone: { dismiss() })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    toolBar
                }
            }
            .animation(.snappy(duration: 0.25), value: m.tool)
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .disabled(working)
        .task {
            guard let session else { m.sourceMissing = true; return }
            await m.load(store, session)
            open(focus)
        }
        .onDisappear { m.stop() }
        .alert(message ?? "", isPresented: Binding(get: { message != nil },
                                                   set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        }
        .alert(L.s("ed_discard_title", lang), isPresented: $confirmDiscard) {
            Button(L.s("ed_discard_ok", lang), role: .destructive) { dismiss() }
            Button(L.s("cancel", lang), role: .cancel) {}
        }
        .alert(String(format: L.s("ed_split_confirm_fmt", lang), fmtPos(m.time)),
               isPresented: $confirmSplit) {
            Button(L.s("split_rally", lang)) { split() }
            Button(L.s("cancel", lang), role: .cancel) {}
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                if m.changed { confirmDiscard = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L.s("cancel", lang))
            Text("#\(clip.number)").font(.headline).foregroundStyle(Theme.primaryText)
            Spacer()
            Text(quality).font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondaryText)
            Button(action: done) {
                Text(L.s("done", lang))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 18).frame(height: 36)
                    .background(Theme.primaryFill, in: Capsule())
            }
            .disabled(m.sourceMissing)
            .opacity(m.sourceMissing ? 0.4 : 1)
        }
        .padding(.horizontal, 8).padding(.trailing, 8)
        .frame(height: 52)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// The tier the clip is made at, as the encoder will make it.
    private var quality: String {
        guard session?.renderedPro == true else { return "720p" }
        return m.frame.isPortrait ? "1080p" : "4K"
    }

    private var transport: some View {
        HStack {
            Button { m.togglePlay() } label: {
                Image(systemName: m.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 22)).foregroundStyle(Theme.primaryText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L.s("play", lang))
            Spacer()
            VStack(spacing: 0) {
                Text(timecode(m.clock(m.time)))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                Text(timecode(m.duration))
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            Spacer()
            HStack(spacing: 8) {
                Button { m.undo() } label: { transportIcon("arrow.uturn.backward") }
                    .disabled(m.undoStack.isEmpty && !pendingStep)
                    .accessibilityLabel(L.s("undo", lang))
                Button { m.redo() } label: { transportIcon("arrow.uturn.forward") }
                    .disabled(m.redoStack.isEmpty)
                    .accessibilityLabel(L.s("ed_redo", lang))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    /// A text field still being typed in has not checkpointed yet.
    private var pendingStep: Bool { m.changed && m.undoStack.isEmpty }

    private func transportIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 19)).foregroundStyle(Theme.secondaryText)
            .frame(width: 40, height: 44)
    }

    private var tools: [EditorTool] {
        EditorTool.allCases.filter { $0 != .background || m.blurFill }
    }

    private var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tools) { t in
                    Button { pick(t) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: t.icon)
                                .font(.system(size: 22))
                                .foregroundStyle(active(t) ? Theme.accent : Theme.primaryText)
                                .frame(height: 28)
                            Text(L.s(t.label, lang))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(active(t) ? Theme.primaryText : Theme.tertiaryText)
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .frame(width: 68, height: 64)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(m.sourceMissing || (t == .split && !m.canSplit))
                    .opacity(t == .split && !m.canSplit ? 0.35 : 1)
                    .accessibilityValue(edited(t) ? L.s("edit_on", lang) : "")
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 76)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func active(_ t: EditorTool) -> Bool { m.tool == t || edited(t) }

    /// The tool's icon stays lit while the draft carries its edit.
    private func edited(_ t: EditorTool) -> Bool {
        let d = m.draft
        switch t {
        case .text: return !d.subtitles.isEmpty
        case .zoom: return !d.zoomKeys.isEmpty
        case .speed: return d.speed != 1
        case .look: return d.look.filter != .original
        case .sound: return d.look.volume != 1
        case .background: return d.look.backdrop != .blur
        case .trim: return abs(d.start - clip.segment.start) > 0.05 || abs(d.end - clip.segment.end) > 0.05
        case .split: return false
        }
    }

    private func pick(_ t: EditorTool) {
        m.checkpoint()
        switch t {
        case .split:
            m.pause()
            confirmSplit = true
        case .text:
            m.pause()
            if let s = m.subtitleAtPlayhead { m.selection = .subtitle(s.id) }
            else { m.addSubtitle(placeholder: L.s("ed_type_here", lang)) }
            m.tool = .text
        default:
            if t != .zoom, case .key = m.selection { m.selection = nil }
            m.tool = t
        }
    }

    private func open(_ focus: Focus?) {
        switch focus {
        case .speed: m.tool = .speed
        case .trim: m.tool = .trim
        case .look: m.tool = .look
        case .zoom: m.tool = .zoom
        case .text: pick(.text)
        case .split: confirmSplit = m.canSplit
        case nil: break
        }
    }

    // MARK: - Overlays

    private var renderingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text(L.s("trim_rendering", lang)).font(.subheadline).foregroundStyle(Theme.primaryText)
        }
        .padding(20)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
    }

    private var missing: some View {
        Label(L.s("source_missing", lang), systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline).foregroundStyle(Theme.warning)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(24)
    }

    // MARK: - Commit

    private func done() {
        m.checkpoint()
        guard m.changed else { dismiss(); return }
        // A busy session (usually the previous clip's own re-render) used to
        // swallow the edit while the editor closed as if it had applied.
        if store.isBusy(clip.sessionID) { message = L.s("busy_wait", lang); return }
        m.pause()
        working = true
        Task {
            let ok = await m.commit(store)
            working = false
            if ok { dismiss() } else { message = L.s("render_failed", lang) }
        }
    }

    /// Pending edits go in first: `splitRally` reads the stored segment, so a
    /// split taken over an uncommitted trim cut a range the user could not see.
    private func split() {
        if store.isBusy(clip.sessionID) { message = L.s("busy_wait", lang); return }
        let at = m.time
        working = true
        Task {
            if m.changed, !(await m.commit(store)) {
                working = false
                message = L.s("render_failed", lang)
                return
            }
            let ok = await store.splitRally(clip, at: at)
            working = false
            if ok { dismiss() } else { message = L.s("split_failed", lang) }
        }
    }
}
