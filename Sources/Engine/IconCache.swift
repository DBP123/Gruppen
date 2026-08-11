import AppKit
import Foundation

/// Process-wide icon cache.
///
/// `NSWorkspace.icon(forFile:)` hits IconServices on every call *and* returns a
/// fresh `NSImage` each time, which also defeats SwiftUI's diffing — every
/// redraw looks like the image changed. Trading roughly 30–50 MB of resident
/// memory for that is a straight win.
///
/// `NSCache` is thread-safe and evicts itself under memory pressure, so the
/// ceiling is a target rather than a hard allocation.
final class IconCache {
    static let shared = IconCache()

    /// Icons are stored flattened. `NSWorkspace` hands back an image carrying
    /// every representation up to 512×512 — roughly a megabyte each — so
    /// caching 200 of them costs ~200 MB, not the ~40 MB a count limit
    /// suggests. One 64pt bitmap per icon is all the UI ever draws.
    private static let side: CGFloat = 40

    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 64
        // 40×40 @2x RGBA ≈ 25 KB; 64 of those is a ~1.6 MB ceiling. The old
        // 64pt/200-entry limits allowed 13 MB for icons the UI draws at 18–34pt.
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    private init() {}

    func icon(for url: URL) -> NSImage {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }

        let source = NSWorkspace.shared.icon(forFile: url.path)
        let flattened = Self.flatten(source)
        cache.setObject(flattened, forKey: key, cost: Self.estimatedCost)
        return flattened
    }

    /// Redraws into a single small bitmap, dropping the other representations.
    private static func flatten(_ image: NSImage) -> NSImage {
        let size = NSSize(width: side, height: side)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return image }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let flattened = NSImage(size: size)
        flattened.addRepresentation(rep)
        return flattened
    }

    private static var estimatedCost: Int { Int(side * 2 * side * 2 * 4) }

    func icon(forPath path: String) -> NSImage {
        icon(for: URL(fileURLWithPath: path))
    }

    /// Drops everything so moved or re-themed bundles are re-read.
    func clear() {
        cache.removeAllObjects()
    }
}
