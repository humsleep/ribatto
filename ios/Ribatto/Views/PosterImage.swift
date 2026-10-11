import SwiftUI
import UIKit

/// A poster loaded once and kept.
///
/// Every grid cell used `UIImage(contentsOfFile:)` directly, which — unlike
/// `UIImage(named:)` — has no shared cache, so scrolling a list re-decoded the
/// same JPEGs on the main thread every pass. Measured at 1.38 ms per poster, a
/// twelve-cell page spent about 17 ms decoding, over the frame budget before
/// any drawing happened.
///
/// The cache is keyed on path plus modification time, so a re-rendered clip
/// whose poster is rewritten in place still refreshes.
enum PosterCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 240
        return c
    }()

    static func key(for url: URL) -> NSString {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                     as? Date)??.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(stamp)" as NSString
    }

    static func cached(_ url: URL) -> UIImage? { cache.object(forKey: key(for: url)) }

    static func load(_ url: URL) -> UIImage? {
        let k = key(for: url)
        if let hit = cache.object(forKey: k) { return hit }
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(img, forKey: k)
        return img
    }
}

/// Drop-in poster view: shows the cached image at once, otherwise decodes off
/// the main actor and fades it in.
struct PosterImage: View {
    let url: URL
    /// Keyed on the cache key, not the path: a trim rewrites clip_NN.jpg in
    /// place, and a delete renames the next clip's poster onto this path.
    /// Read in init so it is one of the view's inputs — read only inside the
    /// body, SwiftUI saw the same URL, skipped the body, and the grid kept the
    /// deleted rally's poster in the slot (it looked as if Delete had removed
    /// the wrong clip).
    let key: String
    init(url: URL) {
        self.url = url
        self.key = PosterCache.key(for: url) as String
    }
    var body: some View {
        _PosterImage(url: url, key: key)
    }
}

private struct _PosterImage: View {
    let url: URL
    let key: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Theme.surfaceHigh
            }
        }
        .task(id: key) {
            if let hit = PosterCache.cached(url) { image = hit; return }
            let loaded = await Task.detached(priority: .userInitiated) {
                PosterCache.load(url)
            }.value
            image = loaded
        }
    }
}
