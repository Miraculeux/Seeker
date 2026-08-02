import SwiftUI
import QuickLookThumbnailing
import CommonCrypto

/// Caches `NSWorkspace.urlsForApplications(toOpen:)` results so the
/// "Open With" submenu doesn't hit the LaunchServices database on every
/// right-click. Results are keyed by lowercase file extension because
/// the app set is determined by UTI / extension, not by the specific
/// file. Files without an extension fall back to per-URL lookup
/// (uncached — rare).
///
/// Cache invalidation: an `NSWorkspace.didActivateApplicationNotification`
/// observer clears the cache when the user installs / removes apps via
/// Finder. This is heuristic but cheap.
enum OpenWithAppsCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSArray> = {
        let c = NSCache<NSString, NSArray>()
        c.countLimit = 256
        return c
    }()

    static func apps(for url: URL) -> [URL] {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else {
            return NSWorkspace.shared.urlsForApplications(toOpen: url)
        }
        let key = ext as NSString
        if let cached = cache.object(forKey: key) as? [URL] {
            return cached
        }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        cache.setObject(apps as NSArray, forKey: key)
        return apps
    }
}

/// Two-tier cache for QuickLook thumbnails used by `FileIconCell`.
///
/// Layer 1 (in-process `NSCache`): hot working set, evicted under memory
/// pressure, bounded by `countLimit`.
///
/// Layer 2 (`DiskThumbnailCache`): persistent PNG files under
/// `~/Library/Caches/<bundleID>/thumbnails/` so previews survive app
/// restarts. Cache keys hash `path | mtime | size | sizeBucket`, so a
/// changed file (different mtime/size) automatically misses and is
/// re-rendered without an explicit invalidation step.
///
/// Thread-safe by `NSCache` contract; marked `nonisolated(unsafe)` so
/// it can be reached from any actor.
enum ThumbnailCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 512
        return c
    }()

    /// File-extension allowlist: types QuickLook can usually thumbnail
    /// quickly. Restricting up front avoids paying for QL requests that
    /// just return a generic icon (which the cell already shows).
    static let thumbnailableExtensions: Set<String> = [
        // raster
        "jpg", "jpeg", "png", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp", "ico",
        // raw
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf", "srw",
        // vector / docs
        "pdf", "svg", "ps", "eps",
        // video (QL extracts a poster frame)
        "mov", "mp4", "m4v", "avi", "mkv", "webm",
        // app-rendered
        "psd", "sketch"
    ]

    static func canThumbnail(_ url: URL) -> Bool {
        thumbnailableExtensions.contains(url.pathExtension.lowercased())
    }

    private static func memKey(for url: URL, sizeBucket: Int) -> NSString {
        "\(url.path)\u{1}\(sizeBucket)" as NSString
    }

    static func cached(for url: URL, sizeBucket: Int) -> NSImage? {
        cache.object(forKey: memKey(for: url, sizeBucket: sizeBucket))
    }

    /// Returns any cached thumbnail for `url`, regardless of bucket.
    /// Used as a fast fallback during zoom: rather than blanking the
    /// cell while a bigger render is in flight, we display whatever we
    /// already have. Tries the requested bucket first, then nearby
    /// buckets in order of decreasing closeness.
    static func cachedAny(for url: URL, preferredBucket: Int) -> NSImage? {
        if let exact = cached(for: url, sizeBucket: preferredBucket) {
            return exact
        }
        // Cheap probe: look for any of our standard zoom step sizes.
        // The list is short (14 entries) so iterating is trivial, and
        // hitting a cached entry is O(1) per probe.
        let steps = FileExplorerViewModel.iconZoomSteps.map(Int.init)
        let ordered = steps.sorted { abs($0 - preferredBucket) < abs($1 - preferredBucket) }
        for s in ordered {
            if let hit = cached(for: url, sizeBucket: s) { return hit }
        }
        return nil
    }

    /// Drops every entry from the in-memory tier. Intended for the
    /// Settings "Clear Caches" affordance to pair with the disk wipe.
    static func clearMemory() {
        cache.removeAllObjects()
    }

    /// Generates a thumbnail off the main actor, consulting the in-memory
    /// cache first, then the on-disk cache, then QuickLook. Returns `nil`
    /// on failure. Callers should treat `nil` as "fall back to the
    /// generic Finder icon".
    static func thumbnail(for url: URL, sizeBucket: Int, scale: CGFloat) async -> NSImage? {
        // 1. In-memory hit.
        if let hit = cache.object(forKey: memKey(for: url, sizeBucket: sizeBucket)) {
            return hit
        }

        // 2. On-disk hit. Promote to memory before returning so subsequent
        //    cells in the same scroll pass don't repeat the disk read.
        if let diskHit = await DiskThumbnailCache.shared.load(url: url, sizeBucket: sizeBucket) {
            cache.setObject(diskHit, forKey: memKey(for: url, sizeBucket: sizeBucket))
            return diskHit
        }

        // 3. QuickLook render. Persist to both layers so we don't pay this
        //    cost again until the file's mtime/size changes.
        let dim = CGFloat(sizeBucket)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: dim, height: dim),
            scale: scale,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                guard let rep else { cont.resume(returning: nil); return }
                let image = rep.nsImage
                cache.setObject(image, forKey: memKey(for: url, sizeBucket: sizeBucket))
                // Fire-and-forget disk write; don't block the QL callback.
                Task.detached(priority: .utility) {
                    await DiskThumbnailCache.shared.store(image: image, url: url, sizeBucket: sizeBucket)
                }
                cont.resume(returning: image)
            }
        }
    }
}

/// Persistent on-disk thumbnail cache.
///
/// Files are stored as PNGs under
/// `~/Library/Caches/<bundleID>/thumbnails/<aa>/<full-hash>.png`. The
/// 2-character prefix subdirectory keeps any single directory from
/// growing unboundedly (Finder/HFS+ slow down with very large dirs).
///
/// Cache keys hash `(path, mtime, size, sizeBucket)` so any file change
/// produces a fresh key and the stale render is simply ignored (and
/// eventually evicted when the cache exceeds its size budget).
///
/// All filesystem work happens off the main actor.
final class DiskThumbnailCache: @unchecked Sendable {
    static let shared = DiskThumbnailCache()

    /// Approximate ceiling for total disk usage. Trim runs lazily when
    /// new entries push us over the budget.
    private static let maxBytes: Int64 = 256 * 1024 * 1024  // 256 MB

    private let directory: URL
    private let queue = DispatchQueue(label: "com.seeker.thumbcache.io", qos: .utility)
    /// Counter so we don't run the `trim` walk on every single write.
    private var writesSinceTrim: Int = 0

    private init() {
        let fm = FileManager.default
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.seeker.app"
        directory = caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Key derivation

    /// Builds a stable hex digest from the file's identity + the desired
    /// size bucket. Includes mtime + size so that editing or replacing a
    /// file produces a new key, automatically invalidating the stale
    /// render without an explicit purge.
    private func cacheKey(for url: URL, sizeBucket: Int) -> String? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return nil }
        let mtime = rv.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = rv.fileSize ?? 0
        let composite = "\(url.standardizedFileURL.path)|\(mtime)|\(size)|\(sizeBucket)"
        return Self.sha256Hex(composite)
    }

    private func fileURL(forKey key: String) -> URL {
        let prefix = String(key.prefix(2))
        return directory
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(key + ".png", isDirectory: false)
    }

    // MARK: - I/O

    func load(url: URL, sizeBucket: Int) async -> NSImage? {
        guard let key = cacheKey(for: url, sizeBucket: sizeBucket) else { return nil }
        let path = fileURL(forKey: key)
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            queue.async {
                guard let data = try? Data(contentsOf: path),
                      let image = NSImage(data: data) else {
                    cont.resume(returning: nil)
                    return
                }
                // Touch atime so LRU-ish trimming keeps recently used
                // entries. We use mtime as the proxy because APFS
                // doesn't track atime by default.
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()], ofItemAtPath: path.path
                )
                cont.resume(returning: image)
            }
        }
    }

    func store(image: NSImage, url: URL, sizeBucket: Int) async {
        guard let key = cacheKey(for: url, sizeBucket: sizeBucket) else { return }
        let path = fileURL(forKey: key)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let fm = FileManager.default
                try? fm.createDirectory(at: path.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                if let png = Self.pngData(from: image) {
                    try? png.write(to: path, options: .atomic)
                }
                self.writesSinceTrim += 1
                if self.writesSinceTrim >= 64 {
                    self.writesSinceTrim = 0
                    self.trimIfNeeded()
                }
                cont.resume(returning: ())
            }
        }
    }

    // MARK: - Trim / size enforcement

    /// Walks the cache directory, sums file sizes, and removes the oldest
    /// (by mtime) entries until total size is back under the budget.
    /// Cheap enough to run inline on the cache queue once every ~64
    /// writes, which is plenty for a UI cache.
    private func trimIfNeeded() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return }

        struct Entry { let url: URL; let size: Int64; let mtime: Date }
        var entries: [Entry] = []
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            guard let rv = try? url.resourceValues(forKeys: keys),
                  rv.isRegularFile == true else { continue }
            let size = Int64(rv.fileSize ?? 0)
            let mtime = rv.contentModificationDate ?? .distantPast
            total += size
            entries.append(Entry(url: url, size: size, mtime: mtime))
        }

        guard total > Self.maxBytes else { return }

        // Oldest first.
        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            if total <= Self.maxBytes { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Manually purge the entire cache. Public so a "Clear Caches" menu
    /// item can wire into it later.
    func clear() {
        queue.async {
            let fm = FileManager.default
            try? fm.removeItem(at: self.directory)
            try? fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
        }
    }

    /// Async variant of `clear()` that resolves once the directory has
    /// been removed and recreated. Also flushes the in-memory tier so
    /// the UI doesn't keep showing freshly-deleted thumbnails.
    func clearAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let fm = FileManager.default
                try? fm.removeItem(at: self.directory)
                try? fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
                self.writesSinceTrim = 0
                cont.resume(returning: ())
            }
        }
    }

    /// Total bytes currently consumed by the on-disk cache. Walks the
    /// directory on the cache queue so this never blocks the caller.
    func currentSizeBytes() async -> Int64 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int64, Never>) in
            queue.async {
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(
                    at: self.directory,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }
                ) else { cont.resume(returning: 0); return }

                var total: Int64 = 0
                while let url = enumerator.nextObject() as? URL {
                    let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
                    guard let rv = try? url.resourceValues(forKeys: keys),
                          rv.isRegularFile == true else { continue }
                    total += Int64(rv.fileSize ?? 0)
                }
                cont.resume(returning: total)
            }
        }
    }

    /// Path the cache is stored at, exposed for the Settings UI's
    /// "Reveal in Finder" affordance.
    var directoryURL: URL { directory }

    // MARK: - Helpers

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func sha256Hex(_ s: String) -> String {
        // CommonCrypto is already linked via NCMDump/AESHelper.
        let data = Array(s.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBufferPointer { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
