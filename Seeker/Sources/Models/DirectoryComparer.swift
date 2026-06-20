import Foundation
import Observation

/// Compares the contents of two directories and reports the entries
/// unique to each side. Two modes:
///
/// - **Top-level** (default): only the immediate children are compared,
///   by file name (case-insensitive). Files and sub-folders are reported.
/// - **Recursive**: both trees are walked and regular files are compared
///   by their *relative subpath* (e.g. `photos/2020/img.jpg`,
///   case-insensitive). A file is "only in A" when no file exists at the
///   same relative path under B. Comparison is by path, not content.
@MainActor @Observable
final class DirectoryComparer {
    enum Status: Equatable {
        case idle
        case comparing
        case done
        case failed(String)
    }

    /// One directory entry surfaced as "only on this side".
    struct Entry: Identifiable, Hashable {
        let id: String          // url.absoluteString — unique per entry
        let url: URL
        let name: String
        let isDirectory: Bool
        let fileSize: Int64
        /// Path relative to the compared root (equals `name` in top-level
        /// mode); shown in recursive mode to disambiguate sub-folders.
        let relativePath: String

        var formattedSize: String {
            isDirectory ? "" : ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        }
    }

    var status: Status = .idle
    var dirA: URL
    var dirB: URL
    /// Entries that exist in A but have no counterpart in B.
    var onlyInA: [Entry] = []
    /// Entries that exist in B but have no counterpart in A.
    var onlyInB: [Entry] = []
    /// When false, dotfiles are ignored on both sides.
    var includeHidden = false
    /// When true, compare whole trees by relative path instead of just
    /// the top-level children by name.
    var recursive = false

    private var currentTask: Task<Void, Never>?

    init(dirA: URL, dirB: URL) {
        self.dirA = dirA
        self.dirB = dirB
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    func compare() {
        currentTask?.cancel()
        status = .comparing
        onlyInA = []
        onlyInB = []

        let a = dirA
        let b = dirB
        let hidden = includeHidden
        let recursive = self.recursive
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (a: [Entry], b: [Entry]) in
                Self.diff(a: a, b: b, includeHidden: hidden, recursive: recursive)
            }.value
            if Task.isCancelled { return }
            self.onlyInA = result.a
            self.onlyInB = result.b
            self.status = .done
        }
        currentTask = task
    }

    /// Drops an entry from whichever side list contains it. Used after
    /// the user trashes the underlying file so the lists stay in sync
    /// without a full re-scan.
    func remove(_ url: URL) {
        let std = url.standardizedFileURL
        onlyInA.removeAll { $0.url.standardizedFileURL == std }
        onlyInB.removeAll { $0.url.standardizedFileURL == std }
    }

    // MARK: - Diff

    private nonisolated static func diff(
        a: URL,
        b: URL,
        includeHidden: Bool,
        recursive: Bool
    ) -> (a: [Entry], b: [Entry]) {
        if recursive {
            return diffRecursive(a: a, b: b, includeHidden: includeHidden)
        }
        let entriesA = list(a, includeHidden: includeHidden)
        let entriesB = list(b, includeHidden: includeHidden)
        let namesA = Set(entriesA.map { $0.name.lowercased() })
        let namesB = Set(entriesB.map { $0.name.lowercased() })

        let onlyA = entriesA
            .filter { !namesB.contains($0.name.lowercased()) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let onlyB = entriesB
            .filter { !namesA.contains($0.name.lowercased()) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (onlyA, onlyB)
    }

    /// Recursive diff: regular files keyed by case-insensitive relative
    /// subpath. Directories are walked but not reported as entries.
    private nonisolated static func diffRecursive(
        a: URL,
        b: URL,
        includeHidden: Bool
    ) -> (a: [Entry], b: [Entry]) {
        let filesA = listRecursive(a, includeHidden: includeHidden)
        let filesB = listRecursive(b, includeHidden: includeHidden)
        let keysA = Set(filesA.map { $0.relativePath.lowercased() })
        let keysB = Set(filesB.map { $0.relativePath.lowercased() })

        let onlyA = filesA
            .filter { !keysB.contains($0.relativePath.lowercased()) }
            .sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
        let onlyB = filesB
            .filter { !keysA.contains($0.relativePath.lowercased()) }
            .sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
        return (onlyA, onlyB)
    }

    private nonisolated static func list(_ dir: URL, includeHidden: Bool) -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let opts: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: opts
        ) else { return [] }

        let keySet = Set(keys)
        return urls.map { url in
            let rv = try? url.resourceValues(forKeys: keySet)
            let isDir = rv?.isDirectory ?? false
            let size = Int64(rv?.fileSize ?? 0)
            let name = url.lastPathComponent
            return Entry(
                id: url.absoluteString,
                url: url,
                name: name,
                isDirectory: isDir,
                fileSize: size,
                relativePath: name
            )
        }
    }

    /// Walks `root` recursively, returning regular files with their path
    /// relative to `root`.
    private nonisolated static func listRecursive(_ root: URL, includeHidden: Bool) -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let opts: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: opts,
            errorHandler: { _, _ in true }
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path
        let keySet = Set(keys)
        var out: [Entry] = []
        var counter = 0
        while let url = enumerator.nextObject() as? URL {
            counter &+= 1
            if counter & 0x3FF == 0, Task.isCancelled { return out }
            let rv = try? url.resourceValues(forKeys: keySet)
            guard rv?.isRegularFile == true else { continue }
            let p = url.standardizedFileURL.path
            var rel = p.hasPrefix(rootPath) ? String(p.dropFirst(rootPath.count)) : url.lastPathComponent
            if rel.hasPrefix("/") { rel.removeFirst() }
            out.append(Entry(
                id: url.absoluteString,
                url: url,
                name: url.lastPathComponent,
                isDirectory: false,
                fileSize: Int64(rv?.fileSize ?? 0),
                relativePath: rel
            ))
        }
        return out
    }
}
