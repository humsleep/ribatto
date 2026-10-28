import AVFoundation
import SwiftUI
import UIKit
import Vision

/// Lets the user point at the player they want kept in frame. Shows a still
/// from the first rally with Vision's detected people as tap targets; when
/// Vision finds nobody — common when players are tiny in a wide frame — the
/// user drags a box instead. The choice is stored on the session as a
/// normalized display-space rect for `PlayerTracker` to seed from.
struct TargetPlayerSheet: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage("rc_lang") private var lang = "en"
    @Environment(\.dismiss) private var dismiss
    let session: Session
    /// When set, the pick applies to this clip alone and the scrubber is
    /// confined to it. nil means the session-wide choice.
    var clip: ClipInfo? = nil

    @State private var image: UIImage?
    @State private var frameTime: Double = 0
    @State private var detected: [CGRect] = []        // normalized, top-left origin
    @State private var chosen: CGRect?
    @State private var dragStart: CGPoint?
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    picker(image)
                } else {
                    VStack(spacing: 12) {
                        if loading { ProgressView() }
                        Text(L.s(loading ? "target_loading"
                                 : store.sourceMissing(session) ? store.sourceProblemKey(session)
                                 : "target_frame_failed", lang))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(clip == nil
                             ? L.s("target_title", lang)
                             : "#" + String(clip!.number) + " · "
                               + L.s("target_clip_title", lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L.s("done", lang))
                        .tint(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.s("target_save", lang)) { save() }
                        .font(.subheadline.bold())
                        .disabled(chosen == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert(message ?? "", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        }
        .task { await load() }
    }

    // MARK: - Picker

    private func picker(_ image: UIImage) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                // The instruction first. "No people found" only once a
                // detection on this frame has actually come back empty and
                // the user has not drawn a box of their own — it used to sit
                // there while a new frame was still being read, and after the
                // user had already drawn.
                Text(L.s(!loading && detected.isEmpty && chosen == nil
                         ? "target_none" : "target_hint", lang))
                    .font(.footnote).foregroundStyle(.secondary)
                // Said at the moment of choosing, where the expectation is set:
                // tracking a person in court-side footage is not a guarantee.
                Text(L.s("target_lose_note", lang))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            // Capped: these are two explanatory paragraphs above the canvas the
            // player is picked in. Uncapped at AX5 they took the whole sheet and
            // the boxes had no height left to be tapped in.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .padding(.horizontal, 20).padding(.top, 12)

            GeometryReader { geo in
                let fit = fittedRect(imageSize: image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)

                    ForEach(Array(detected.enumerated()), id: \.offset) { _, box in
                        boxView(box, in: fit, active: box == chosen)
                            .onTapGesture { chosen = box }
                    }
                    if let chosen, !detected.contains(chosen) {
                        boxView(chosen, in: fit, active: true)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { v in
                            let start = dragStart ?? v.startLocation
                            dragStart = start
                            chosen = normalizedRect(from: start, to: v.location, in: fit)
                        }
                        .onEnded { _ in dragStart = nil }
                )
            }
            // The canvas keeps a usable height whatever the text above does.
            .frame(minHeight: 220)

            // A single still can easily be the moment the player is behind the
            // opponent, out of frame, or not yet on court, so the frame is
            // pickable. Reloading on release rather than on every value keeps
            // one decode per drag instead of dozens.
            HStack(spacing: 12) {
                Text(L.s("target_frame", lang))
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: $frameTime, in: range) { editing in
                    if !editing { Task { await loadFrame() } }
                }
                .tint(Theme.accent)
                .accessibilityLabel(L.s("target_frame", lang))
                .accessibilityValue(fmtPos(frameTime))
                .disabled(loading)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    /// The stretch of video the pick is made from: the clip's own rally when
    /// picking for one clip, otherwise the first rally of the session.
    private var range: ClosedRange<Double> {
        let span: (Double, Double)
        if let clip {
            span = (clip.segment.start, clip.segment.end)
        } else if let seg = session.segments?.first {
            span = (seg.start, seg.end)
        } else {
            span = (0, session.duration)
        }
        return span.0...max(span.0 + 0.1, span.1)
    }

    private func boxView(_ box: CGRect, in fit: CGRect, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(active ? Theme.accent : Color.white.opacity(0.85),
                          lineWidth: active ? 3 : 1.5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(active ? Theme.accent.opacity(0.15) : Color.white.opacity(0.001)))
            .contentShape(Rectangle())
            .frame(width: max(box.width * fit.width, 12),
                   height: max(box.height * fit.height, 12))
            .position(x: fit.minX + box.midX * fit.width,
                      y: fit.minY + box.midY * fit.height)
    }

    // MARK: - Geometry

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width,
                        container.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2,
                      width: w, height: h)
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint, in fit: CGRect) -> CGRect {
        guard fit.width > 0, fit.height > 0 else { return .zero }
        func clamp(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }
        let nx = clamp((min(a.x, b.x) - fit.minX) / fit.width)
        let ny = clamp((min(a.y, b.y) - fit.minY) / fit.height)
        let nw = clamp((max(a.x, b.x) - fit.minX) / fit.width) - nx
        let nh = clamp((max(a.y, b.y) - fit.minY) / fit.height) - ny
        // The minimum size is applied first, then the origin is pulled back so
        // the box still ends inside the frame. Bumping the size afterwards let
        // a drag on the right edge store x = 1.0 with width 0.02 — a rect whose
        // maxX is outside the space PlayerTracker seeds from.
        let w = max(nw, 0.02), h = max(nh, 0.02)
        return CGRect(x: min(nx, 1 - w), y: min(ny, 1 - h), width: w, height: h)
    }

    // MARK: - Load + detect

    private func load() async {
        // flatMap, not map: a clip with no override of its own should still
        // open on the session's pick rather than on nothing.
        let existing = clip.flatMap { session.clipTargets?[String($0.index)] }
            ?? session.targetPlayer
        // Reopening lands on the frame the current pick was made from, so a
        // small adjustment starts from what is already there.
        if let existing, range.contains(existing.pickedAt) {
            frameTime = existing.pickedAt
            chosen = existing.rect
            // This is the frame the pick was made on, so the pick stays. The
            // default `loadFrame` cleared it, which made every reopen look
            // like nothing had been saved.
            await loadFrame(keepPick: true)
        } else {
            frameTime = min(range.lowerBound + 1.0, range.upperBound)
            await loadFrame()
        }
    }

    /// - Parameter keepPick: only for reopening on the frame the current pick
    ///   was made on. A scrub must pass the default.
    private func loadFrame(keepPick: Bool = false) async {
        loading = true
        let t = frameTime
        // The pick belongs to the frame it was made on. Keeping it across a
        // scrub saved a box from the old frame with the new frame's timestamp,
        // so the tracker seeded on whatever was at those coordinates later —
        // often empty court.
        if !keepPick { chosen = nil }
        guard let asset = await store.loadAsset(session) else { loading = false; return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        // Off the main actor: a synchronous 4K (or iCloud) frame grab plus
        // Vision froze the sheet on every scrub.
        let found = await Task.detached(priority: .userInitiated) { () -> (CGImage, [CGRect])? in
            guard let cg = try? gen.copyCGImage(
                at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { return nil }
            return (cg, Self.detectPeople(cg))
        }.value
        // A slower earlier request must not overwrite a newer frame.
        guard t == frameTime else { return }
        guard let (cg, people) = found else {
            loading = false
            return
        }
        image = UIImage(cgImage: cg)
        detected = people
        loading = false
    }

    /// People as normalized rects with a TOP-left origin (Vision reports
    /// bottom-left), matching the space `TargetPlayer`/`PlayerTracker` use.
    private static func detectPeople(_ cg: CGImage) -> [CGRect] {
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = false
        try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req])
        let people = req.results ?? []
        return people
            .filter { $0.confidence > 0.2 }
            .map { obs in
                let b = obs.boundingBox
                return CGRect(x: b.origin.x, y: 1 - b.origin.y - b.height,
                              width: b.width, height: b.height)
            }
    }

    private func save() {
        guard let chosen else { return }
        let target = TargetPlayer(rect: chosen, pickedAt: frameTime)
        if let clip {
            // The store refuses a per-clip re-target while the session is
            // busy; closing anyway made it look saved.
            if store.isBusy(clip.sessionID) {
                message = L.s("busy_wait", lang)
                return
            }
            Task { await store.setClipTarget(clip, target) }
        } else {
            store.setTargetPlayer(session, target)
        }
        dismiss()
    }
}
