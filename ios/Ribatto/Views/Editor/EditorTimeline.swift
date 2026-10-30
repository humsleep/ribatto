import SwiftUI
import UIKit

/// The clip on a time axis under a fixed centre playhead. Dragging the
/// background scrubs, pinching changes the scale; text bars, keyframe
/// diamonds and the trim handles take their own drags first.
struct EditorTimeline: View {
    @ObservedObject var m: EditorModel
    @AppStorage("rc_lang") private var lang = "en"
    @State private var scrubBase: Double?
    @State private var scaleBase: CGFloat?
    @State private var handleBase: Double?
    @State private var barBase: (Double, Double)?
    @State private var keyBase: Double?
    @State private var fitted = false

    private let rulerH: CGFloat = 22
    private let textH: CGFloat = 30
    private let keyH: CGFloat = 24
    private let videoH: CGFloat = 52
    private let handleW: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            VStack(alignment: .leading, spacing: 6) {
                ruler(w).frame(height: rulerH)
                textTrack(w).frame(height: textTrackHeight)
                keyTrack(w).frame(height: keyH)
                videoTrack(w).frame(height: videoH)
            }
            .frame(width: w, alignment: .leading)
            .clipped()
            .overlay(playhead)
            .contentShape(Rectangle())
            .gesture(scrub)
            .simultaneousGesture(pinch(w))
            .onAppear {
                guard !fitted, w > 0 else { return }
                fitted = true
                // The whole clip in about three quarters of the width.
                m.pxPerSec = min(max(w * 0.75 / max(m.draft.end - m.draft.start, 1), 20), 400)
            }
        }
        .frame(height: rulerH + textTrackHeight + keyH + videoH + 18)
        // One adjustable element: the parts below are reachable from the
        // panels (steppers, lists), which VoiceOver can operate.
        .accessibilityElement()
        .accessibilityLabel(L.s("ed_timeline", lang))
        .accessibilityValue(timecode(m.clock(m.time)))
        .accessibilityAdjustableAction { dir in
            m.scrub(to: m.time + (dir == .increment ? 0.5 : -0.5), exact: true)
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { w / 2 + CGFloat(t - m.time) * m.pxPerSec }

    // MARK: Gestures

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if scrubBase == nil { scrubBase = m.time; m.pause() }
                m.scrub(to: (scrubBase ?? m.time) - Double(v.translation.width / m.pxPerSec))
            }
            .onEnded { v in
                let base = scrubBase ?? m.time
                scrubBase = nil
                // A flick carries on a little, like a scroll view.
                let target = base - Double(v.predictedEndTranslation.width / m.pxPerSec)
                withAnimation(.easeOut(duration: 0.25)) { m.scrub(to: target, exact: true) }
            }
    }

    private func pinch(_ w: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let base = scaleBase ?? m.pxPerSec
                scaleBase = base
                let floor = max(12, w * 0.5 / CGFloat(max(m.upper - m.lower, 1)))
                m.pxPerSec = min(max(base * v.magnification, floor), 400)
            }
            .onEnded { _ in scaleBase = nil }
    }

    // MARK: Ruler

    private func ruler(_ w: CGFloat) -> some View {
        // Label spacing grows as the scale shrinks, so labels never collide.
        let step: Double = [0.5, 1, 2, 5, 10].first { CGFloat($0) * m.pxPerSec * CGFloat(1 / m.draft.speed) >= 56 } ?? 10
        let sourceStep = step * m.draft.speed
        let first = Int(((m.lower - m.draft.start) / sourceStep).rounded(.down))
        let last = Int(((m.upper - m.draft.start) / sourceStep).rounded(.up))
        return ZStack(alignment: .topLeading) {
            ForEach(first...max(first, last), id: \.self) { k in
                let t = m.draft.start + Double(k) * sourceStep
                let inside = t >= m.draft.start - 0.001 && t <= m.draft.end + 0.001
                VStack(spacing: 3) {
                    Text(k >= 0 ? timecode(Double(k) * step) : "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(inside ? Theme.secondaryText : Theme.tertiaryText.opacity(0.5))
                        .fixedSize()
                    Circle().fill(Theme.tertiaryText.opacity(0.6)).frame(width: 3, height: 3)
                }
                .position(x: x(t, w), y: rulerH / 2)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    // MARK: Text

    /// Overlapping lines stack, two rows at most.
    private var rows: [UUID: Int] {
        var ends: [Double] = []
        var out: [UUID: Int] = [:]
        for s in m.draft.subtitles.sorted(by: { $0.start < $1.start }) {
            if let r = ends.firstIndex(where: { $0 <= s.start }) { ends[r] = s.end; out[s.id] = r }
            else if ends.count < 2 { ends.append(s.end); out[s.id] = ends.count - 1 }
            else { out[s.id] = 1; ends[1] = max(ends[1], s.end) }
        }
        return out
    }
    private var textTrackHeight: CGFloat {
        (rows.values.max() ?? 0) >= 1 ? textH * 2 + 4 : textH
    }

    private func textTrack(_ w: CGFloat) -> some View {
        let rows = self.rows
        return ZStack(alignment: .topLeading) {
            ForEach(m.draft.subtitles) { sub in
                let selected = m.selection == .subtitle(sub.id)
                let x0 = x(sub.start, w), x1 = x(sub.end, w)
                let row = CGFloat(rows[sub.id] ?? 0)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Theme.accent : Theme.raised2)
                    Text(sub.caption.text.isEmpty ? " " : sub.caption.text)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(selected ? Theme.onAccent : Theme.primaryText)
                        .lineLimit(1)
                        .padding(.horizontal, selected ? handleW + 4 : 10)
                    if selected {
                        HStack {
                            edgeHandle { d in moveSubtitleEdge(sub.id, start: true, by: d) }
                            Spacer(minLength: 0)
                            edgeHandle { d in moveSubtitleEdge(sub.id, start: false, by: d) }
                        }
                    }
                }
                .frame(width: max(x1 - x0, 24), height: textH)
                .contentShape(Rectangle())
                .onTapGesture {
                    if selected { m.tool = .text } else { m.selection = .subtitle(sub.id); m.tool = .text }
                }
                .gesture(moveSubtitle(sub.id), including: selected ? .all : .subviews)
                .offset(x: x0, y: row * (textH + 4))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private func edgeHandle(_ moved: @escaping (Double?) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.white)
            .frame(width: handleW)
            .overlay(Capsule().fill(Theme.background).frame(width: 2, height: 12))
            .contentShape(Rectangle().inset(by: -8))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in moved(Double(v.translation.width / m.pxPerSec)) }
                .onEnded { _ in moved(nil) })
    }

    /// Nil delta ends the drag.
    private func moveSubtitleEdge(_ id: UUID, start: Bool, by delta: Double?) {
        guard let i = m.draft.subtitles.firstIndex(where: { $0.id == id }) else { return }
        guard let delta else { handleBase = nil; m.checkpoint(); return }
        m.pause()
        let s = m.draft.subtitles[i]
        let base = handleBase ?? (start ? s.start : s.end)
        handleBase = base
        if start {
            m.draft.subtitles[i].start = min(max(base + delta, m.lower), s.end - 0.5)
            m.peek(m.draft.subtitles[i].start)
        } else {
            m.draft.subtitles[i].end = max(min(base + delta, m.upper), s.start + 0.5)
            m.peek(m.draft.subtitles[i].end - 0.05)
        }
    }

    private func moveSubtitle(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                guard let i = m.draft.subtitles.firstIndex(where: { $0.id == id }) else { return }
                m.pause()
                let s = m.draft.subtitles[i]
                let base = barBase ?? (s.start, s.end)
                barBase = base
                let len = base.1 - base.0
                let start = min(max(base.0 + Double(v.translation.width / m.pxPerSec), m.lower), m.upper - len)
                m.draft.subtitles[i].start = start
                m.draft.subtitles[i].end = start + len
            }
            .onEnded { _ in barBase = nil; m.checkpoint() }
    }

    // MARK: Keyframes

    /// A labelled lane, so zoom is findable before it has a key: an empty
    /// 18pt strip with 10pt diamonds read as nothing at all.
    private func keyTrack(_ w: CGFloat) -> some View {
        let keys = m.draft.zoomKeys
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceHigh.opacity(0.6))
                .frame(width: max(0, x(m.draft.end, w) - x(m.draft.start, w)), height: keyH)
                .offset(x: x(m.draft.start, w))
                .allowsHitTesting(false)
            // The eased move between keys; bright where the framing changes.
            ForEach(Array(zip(keys, keys.dropFirst())), id: \.0.id) { a, b in
                let x0 = x(a.time, w), x1 = x(b.time, w)
                Rectangle()
                    .fill(Color.white.opacity(a.zoom != b.zoom || a.x != b.x || a.y != b.y ? 0.85 : 0.3))
                    .frame(width: max(0, x1 - x0), height: 2)
                    .offset(x: x0, y: keyH / 2 - 1)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 4) {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 11, weight: .semibold))
                Text(L.s("edit_zoom", lang)).font(.caption2.weight(.semibold))
                if keys.isEmpty {
                    Text("· " + L.s("ed_zoom_lane_hint", lang)).font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: keyH)
            .background(Theme.background.opacity(0.75), in: Capsule())
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .padding(.leading, 4)
            .allowsHitTesting(false)
            ForEach(keys) { k in
                let selected = m.selection == .key(k.id)
                Rectangle()
                    .fill(selected ? Theme.accent : Color.white)
                    .frame(width: 14, height: 14)
                    .overlay(Rectangle().strokeBorder(Theme.background, lineWidth: 1.5))
                    .rotationEffect(.degrees(45))
                    .frame(width: 44, height: keyH)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        m.selection = .key(k.id)
                        m.tool = .zoom
                        m.scrub(to: k.time, exact: true)
                    }
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            guard let i = m.draft.zoomKeys.firstIndex(where: { $0.id == k.id }) else { return }
                            m.pause()
                            let base = keyBase ?? k.time
                            keyBase = base
                            m.draft.zoomKeys[i].time = min(max(base + Double(v.translation.width / m.pxPerSec), m.lower), m.upper)
                            m.selection = .key(k.id)
                        }
                        .onEnded { _ in
                            keyBase = nil
                            m.draft.zoomKeys.sort { $0.time < $1.time }
                            m.checkpoint()
                        })
                    .offset(x: x(k.time, w) - 22)
            }
        }
    }

    // MARK: Video

    private func videoTrack(_ w: CGFloat) -> some View {
        let x0 = x(m.lower, w), x1 = x(m.upper, w)
        let s = x(m.draft.start, w), e = x(m.draft.end, w)
        // Frames at their own shape, each showing the nearest generated thumb.
        let cell = videoH * 16 / 9
        let n = max(Int(((x1 - x0) / cell).rounded(.up)), 1)
        let count = max(m.thumbs.count, 1)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<n, id: \.self) { k in
                    let i = min(Int((CGFloat(k) + 0.5) / CGFloat(n) * CGFloat(count)), count - 1)
                    Group {
                        if m.thumbs.indices.contains(i), let image = m.thumbs[i] {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        } else {
                            Theme.surfaceHigh
                        }
                    }
                    .frame(width: k == n - 1 ? max(x1 - x0 - cell * CGFloat(n - 1), 1) : cell, height: videoH)
                    .clipped()
                }
            }
            .offset(x: x0)
            // Outside the cut: still there to pull back in, but dimmed.
            Rectangle().fill(.black.opacity(0.6)).frame(width: max(s - x0, 0), height: videoH).offset(x: x0)
            Rectangle().fill(.black.opacity(0.6)).frame(width: max(x1 - e, 0), height: videoH).offset(x: e)
            // The strikes the detector heard.
            ForEach(Array(m.hits.enumerated()), id: \.offset) { _, t in
                Capsule().fill(Theme.court).frame(width: 2, height: 8)
                    .offset(x: x(t, w) - 1, y: videoH - 10)
            }
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: max(e - s, 2), height: videoH)
                .offset(x: s)
                .allowsHitTesting(false)
            trimHandle(start: true).offset(x: s - handleW)
            trimHandle(start: false).offset(x: e)
        }
        .clipShape(Rectangle())
    }

    private func trimHandle(start: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: start ? 6 : 0, bottomLeadingRadius: start ? 6 : 0,
                               bottomTrailingRadius: start ? 0 : 6, topTrailingRadius: start ? 0 : 6)
            .fill(.white)
            .frame(width: handleW, height: videoH)
            .overlay(Image(systemName: start ? "chevron.left" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.background))
            .contentShape(Rectangle().inset(by: -10))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    m.pause()
                    let base = handleBase ?? (start ? m.draft.start : m.draft.end)
                    handleBase = base
                    let t = base + Double(v.translation.width / m.pxPerSec)
                    if start {
                        m.draft.start = min(max(t, m.lower), m.draft.end - m.minClip)
                        m.peek(m.draft.start)
                    } else {
                        m.draft.end = max(min(t, m.upper), m.draft.start + m.minClip)
                        m.peek(m.draft.end - 0.05)
                    }
                }
                .onEnded { _ in
                    handleBase = nil
                    m.checkpoint()
                    m.scrub(to: start ? m.draft.start : m.draft.end - 0.05, exact: true)
                })
            .accessibilityHidden(true)
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Capsule().fill(.white).frame(width: 8, height: 4)
            Rectangle().fill(.white).frame(width: 2)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .allowsHitTesting(false)
    }
}

/// m:ss, the way editors show a clip clock.
func timecode(_ s: Double) -> String {
    let t = max(0, Int(s.rounded(.down)))
    return String(format: "%02d:%02d", t / 60, t % 60)
}
