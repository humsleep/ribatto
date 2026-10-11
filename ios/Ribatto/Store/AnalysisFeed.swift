import Foundation

/// What the session screen draws while a match is read and searched: how far
/// along, the loudness of what has been decoded so far, and the rallies once
/// they are found.
///
/// Its own object, not more `@Published` state on the store: it changes about
/// a hundred times per stage, and every view observing the store — the whole
/// library — would redraw with it. Only the progress card watches this.
/// Transient by design; nothing here is saved, and a relaunch simply shows
/// the plain progress bar.
@MainActor
final class AnalysisFeed: ObservableObject {
    enum Phase { case audio, detect, found }

    /// Share of the one bar that reading the audio takes; detection is the
    /// rest. Two bars that each ran to 100% read as "done" and then "starting
    /// over".
    static let audioShare = 0.85

    struct Item: Equatable {
        /// Length of the match, to place rallies on the strip.
        var duration: Double
        /// One RMS value per bucket, filling left to right as decoding runs.
        var envelope: [Float] = []
        var phase: Phase = .audio
        /// The whole analysis, 0…1, across both phases.
        var overall: Double = 0
        /// How far reading the audio is, for the playhead.
        var audioFraction: Double = 0
        /// When the first audio arrived. Not when the run began: fetching an
        /// iCloud original first counted as decoding time and the estimate
        /// opened at an hour.
        var clockStart: Date?
        /// Seconds left, smoothed. nil until 5% is done — before that the
        /// rate is mostly startup cost.
        var eta: Double?
        var rallies: [RallySegment]?
        /// A re-detect over existing clips: the new rallies are not the
        /// session's until the whole render lands, so their markers cannot
        /// open anything yet.
        var staged = false
        /// Markers already revealed. Kept here, not in the view, so reopening
        /// the screen mid-render does not replay the reveal and its haptics.
        var revealed = 0
    }

    @Published private(set) var items: [UUID: Item] = [:]

    func begin(_ id: UUID, duration: Double) {
        items[id] = Item(duration: max(duration, 1))
    }

    func audio(_ id: UUID, fraction: Double, envelope: [Float]) {
        // Late hops from the reading thread can land after detection began.
        guard var item = items[id], item.phase == .audio else { return }
        if item.clockStart == nil { item.clockStart = Date() }
        item.envelope = envelope
        item.audioFraction = min(max(fraction, 0), 1)
        advance(&item, to: Self.audioShare * item.audioFraction)
        items[id] = item
    }

    func startDetect(_ id: UUID) {
        guard var item = items[id] else { return }
        item.phase = .detect
        item.audioFraction = 1
        advance(&item, to: Self.audioShare)
        items[id] = item
    }

    func detect(_ id: UUID, fraction: Double) {
        guard var item = items[id], item.phase == .detect else { return }
        let overall = Self.audioShare + (1 - Self.audioShare) * min(max(fraction, 0), 1)
        guard overall > item.overall else { return }
        advance(&item, to: overall)
        items[id] = item
    }

    func found(_ id: UUID, rallies: [RallySegment], staged: Bool) {
        guard var item = items[id] else { return }
        item.phase = .found
        item.overall = 1
        item.eta = nil
        item.rallies = rallies
        item.staged = staged
        items[id] = item
    }

    func reveal(_ id: UUID, count: Int) {
        guard var item = items[id], count > item.revealed else { return }
        item.revealed = count
        items[id] = item
    }

    func end(_ id: UUID) { items[id] = nil }

    /// Elapsed over done, blended with the last estimate so the minutes do
    /// not jump around with every uneven chunk the decoder hands over.
    private func advance(_ item: inout Item, to overall: Double) {
        item.overall = min(max(overall, item.overall), 1)
        guard let start = item.clockStart, item.overall >= 0.05, item.overall < 1 else { return }
        let elapsed = Date().timeIntervalSince(start)
        let raw = elapsed * (1 - item.overall) / item.overall
        item.eta = item.eta.map { $0 * 0.7 + raw * 0.3 } ?? raw
    }
}
