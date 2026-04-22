import Foundation
import UniformTypeIdentifiers
import AppKit

/// Process-wide caches for values that are expensive to compute but stable
/// across many `FileItem` instances. These are read from SwiftUI `body`
/// closures so they must be cheap.
///
/// All caches are immutable references after init (their internals are
/// thread-safe: `NSCache` is documented as thread-safe; `DateFormatter`
/// and `ByteCountFormatter` are safe to *read from* concurrently as long
/// as no one mutates their configuration). Marked `nonisolated(unsafe)`
/// so they are reachable from non-isolated `FileItem` computed properties.
enum FileItemCache {
    nonisolated(unsafe) static let iconByExtension: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()
    nonisolated(unsafe) static let iconByPath: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 512
        return c
    }()

    nonisolated(unsafe) static let typeDescByExtension: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 512
        return c
    }()

    /// Cache of `containsNCMFiles` results per directory path. Entries are
    /// short-lived (countLimit 256) and intentionally not invalidated on
    /// disk changes — the worst case is a slightly stale context menu.
    nonisolated(unsafe) static let containsNCMByPath: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 256
        return c
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    nonisolated(unsafe) static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// Cached `showFileExtensions` user default. Reading `UserDefaults` per
    /// row per render shows up under lock contention; cache the value and
    /// invalidate on `UserDefaults.didChangeNotification`.
    /// `nonisolated(unsafe)`: the underlying value is a `Bool` (atomic read/
    /// write on aligned storage); the observer block runs on the main queue
    /// and SwiftUI body reads happen on the main actor.
    nonisolated(unsafe) private static var _showFileExtensions: Bool =
        UserDefaults.standard.object(forKey: "showFileExtensions") as? Bool ?? false
    nonisolated(unsafe) private static var _observerInstalled: Bool = false
    static var showFileExtensions: Bool {
        if !_observerInstalled {
            _observerInstalled = true
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil, queue: .main
            ) { _ in
                _showFileExtensions =
                    UserDefaults.standard.object(forKey: "showFileExtensions") as? Bool ?? false
            }
        }
        return _showFileExtensions
    }
}

struct FileItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let isHidden: Bool
    let isPackage: Bool

    /// Directories under ~ that trigger TCC prompts when accessed
    private static let tccProtectedNames: Set<String> = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]

    private static let homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path

    init(url: URL) {
        self.id = url.absoluteString
        self.url = url
        self.name = url.lastPathComponent

        // Check if this is a TCC-protected directory under ~ to avoid prompts
        let parentPath = url.deletingLastPathComponent().path
        if parentPath == FileItem.homeDirectory && FileItem.tccProtectedNames.contains(url.lastPathComponent) {
            self.isDirectory = true
            self.fileSize = 0
            self.modificationDate = nil
            self.creationDate = nil
            self.isHidden = false
            self.isPackage = false
            return
        }

        // Use lstat to check directory status without triggering TCC prompts
        var statInfo = stat()
        let isDir: Bool
        let size: Int64
        let mDate: Date?
        let cDate: Date?
        let hidden: Bool

        if lstat(url.path, &statInfo) == 0 {
            isDir = (statInfo.st_mode & S_IFMT) == S_IFDIR
            size = isDir ? 0 : Int64(statInfo.st_size)
            mDate = Date(timeIntervalSince1970: Double(statInfo.st_mtimespec.tv_sec))
            cDate = Date(timeIntervalSince1970: Double(statInfo.st_birthtimespec.tv_sec))
            hidden = url.lastPathComponent.hasPrefix(".")
        } else {
            isDir = false
            size = 0
            mDate = nil
            cDate = nil
            hidden = url.lastPathComponent.hasPrefix(".")
        }

        self.isDirectory = isDir
        self.fileSize = size
        self.modificationDate = mDate
        self.creationDate = cDate
        self.isHidden = hidden
        self.isPackage = isDir && NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    /// Resource keys to request from `contentsOfDirectory(at:includingPropertiesForKeys:)`
    /// for the bulk-fetch fast path. Foundation can satisfy these with a
    /// single `getattrlistbulk` sweep — much cheaper than per-file `lstat`
    /// + `NSWorkspace.isFilePackage` calls used by `init(url:)`.
    static let prefetchKeys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey,
        .isHiddenKey, .isPackageKey
    ]

    /// Build a `FileItem` from prefetched URL resource values. Avoids the
    /// per-file `lstat` + `NSWorkspace.isFilePackage` round-trips that
    /// dominate `loadFiles()` on directories with thousands of entries.
    init(url: URL, resourceValues rv: URLResourceValues) {
        self.id = url.absoluteString
        self.url = url
        self.name = url.lastPathComponent

        // TCC-protected names: still avoid touching them even on the fast path.
        let parentPath = url.deletingLastPathComponent().path
        if parentPath == FileItem.homeDirectory && FileItem.tccProtectedNames.contains(url.lastPathComponent) {
            self.isDirectory = true
            self.fileSize = 0
            self.modificationDate = nil
            self.creationDate = nil
            self.isHidden = false
            self.isPackage = false
            return
        }

        let isDir = rv.isDirectory ?? false
        self.isDirectory = isDir
        self.fileSize = isDir ? 0 : Int64(rv.fileSize ?? 0)
        self.modificationDate = rv.contentModificationDate
        self.creationDate = rv.creationDate
        self.isHidden = rv.isHidden ?? url.lastPathComponent.hasPrefix(".")
        // `isPackage` from resource values is satisfied without a Launch
        // Services round-trip when the kind is unambiguous from the file
        // type / extension. Falsey default is correct for plain directories.
        self.isPackage = isDir && (rv.isPackage ?? false)
    }

    /// Native macOS file icon, matching Finder's display.
    /// Cached: regular files share an icon per extension; directories and
    /// bundles fall back to per-path caching since their icon may be custom.
    var nsIcon: NSImage {
        if isDirectory || isPackage {
            let key = url.path as NSString
            if let img = FileItemCache.iconByPath.object(forKey: key) { return img }
            let img = NSWorkspace.shared.icon(forFile: url.path)
            FileItemCache.iconByPath.setObject(img, forKey: key)
            return img
        }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty {
            let key = ext as NSString
            if let img = FileItemCache.iconByExtension.object(forKey: key) { return img }
            let img = NSWorkspace.shared.icon(forFile: url.path)
            FileItemCache.iconByExtension.setObject(img, forKey: key)
            return img
        }
        // Extension-less file: fall back to per-path (rare).
        let key = url.path as NSString
        if let img = FileItemCache.iconByPath.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        FileItemCache.iconByPath.setObject(img, forKey: key)
        return img
    }

    var formattedSize: String {
        if isDirectory { return "--" }
        return FileItemCache.byteFormatter.string(fromByteCount: fileSize)
    }

    var formattedDate: String {
        guard let date = modificationDate else { return "--" }
        return FileItemCache.dateFormatter.string(from: date)
    }

    var typeDescription: String {
        if isDirectory { return "Folder" }
        let ext = url.pathExtension.lowercased()
        let key = ext as NSString
        if let cached = FileItemCache.typeDescByExtension.object(forKey: key) {
            return cached as String
        }
        let desc = UTType(filenameExtension: ext)?.localizedDescription
            ?? ext.uppercased()
        FileItemCache.typeDescByExtension.setObject(desc as NSString, forKey: key)
        return desc
    }

    var displayName: String {
        let showExtensions = FileItemCache.showFileExtensions
        if showExtensions || url.pathExtension.isEmpty {
            return name
        }
        if !showExtensions && isDirectory && !isPackage {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    var isNCMFile: Bool {
        url.pathExtension.lowercased() == "ncm"
    }

    /// Shallow check: does this folder contain any .ncm files?
    /// Cached per directory URL because this is read from inside SwiftUI
    /// context-menu builders — without caching, right-clicking a folder
    /// blocks on a synchronous directory read on every redraw (and on
    /// network volumes can stall for seconds).
    var containsNCMFiles: Bool {
        guard isDirectory else { return false }
        let key = url.path as NSString
        if let cached = FileItemCache.containsNCMByPath.object(forKey: key) {
            return cached.boolValue
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let result = contents.contains { $0.pathExtension.lowercased() == "ncm" }
        FileItemCache.containsNCMByPath.setObject(NSNumber(value: result), forKey: key)
        return result
    }
}
