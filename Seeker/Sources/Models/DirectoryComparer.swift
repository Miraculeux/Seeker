import Foundation
import Observation

/// Compares the top-level contents of two directories purely by file
/// name, case-insensitively. Produces two disjoint lists: entries that
/// exist only in A and entries that exist only in B. Entries present in
/// both (same lowercased name) are considered matched and omitted.
///
/// Only the immediate children of each directory are compared — the
/// walk is non-recursive. Both files and sub-folders are reported.
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

        var formattedSize: String {
            isDirectory ? "" : ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        }
    }

    var status: Status = .idle
    var dirA: URL
    var dirB: URL
    /// Entries that exist in A but have no same-named counterpart in B.
    var onlyInA: [Entry] = []
    /// Entries that exist in B but have no same-named counterpart in A.
    var onlyInB: [Entry] = []
    /// When false, dotfiles are ignored on both sides.
    var includeHidden = false

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
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (a: [Entry], b: [Entry]) in
                Self.diff(a: a, b: b, includeHidden: hidden)
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
        includeHidden: Bool
    ) -> (a: [Entry], b: [Entry]) {
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
            return Entry(
                id: url.absoluteString,
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDir,
                fileSize: size
            )
        }
    }
}
