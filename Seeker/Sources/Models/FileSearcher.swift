import Foundation
import Observation

/// Recursive file search rooted at a directory. Two modes:
///
/// - **Name** — walks the tree with a `FileManager` enumerator and keeps
///   entries whose file name contains the query (case-insensitive). Works
///   on any folder without depending on Spotlight indexing.
/// - **Contents** — shells out to Spotlight's `mdfind` scoped to the root,
///   matching the query against indexed text content. Fast on indexed
///   volumes; returns nothing on folders Spotlight doesn't index.
@MainActor @Observable
final class FileSearcher {
    enum Mode: String, CaseIterable, Identifiable {
        case name
        case contents
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: return "Name"
            case .contents: return "Contents"
            }
        }
    }

    enum Status: Equatable {
        case idle
        case searching
        case done(count: Int)
        case failed(String)
    }

    struct Result: Identifiable, Hashable {
        let id: URL
        let url: URL
        let name: String
        let isDirectory: Bool
        let fileSize: Int64
        /// Path relative to the search root, for display.
        let relativePath: String

        var formattedSize: String {
            isDirectory ? "" : ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        }
    }

    let root: URL
    var query = ""
    var mode: Mode = .name
    var includeHidden = false

    var status: Status = .idle
    var results: [Result] = []

    /// Cap on results to keep the UI responsive on huge trees.
    private let resultLimit = 5000
    private var currentTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    func search() {
        currentTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            status = .idle
            return
        }
        status = .searching
        results = []

        let root = self.root
        let mode = self.mode
        let includeHidden = self.includeHidden
        let limit = self.resultLimit
        let task = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> [Result] in
                switch mode {
                case .name:
                    return Self.searchByName(root: root, query: trimmed, includeHidden: includeHidden, limit: limit)
                case .contents:
                    return Self.searchByContents(root: root, query: trimmed, limit: limit)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.results = found
            self.status = .done(count: found.count)
        }
        currentTask = task
    }

    // MARK: - Name search

    private nonisolated static func searchByName(
        root: URL,
        query: String,
        includeHidden: Bool,
        limit: Int
    ) -> [Result] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isRegularFileKey]
        let opts: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: opts,
            errorHandler: { _, _ in true }
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path
        var out: [Result] = []
        var counter = 0
        while let url = enumerator.nextObject() as? URL {
            counter &+= 1
            if counter & 0x3FF == 0, Task.isCancelled { return out }
            guard url.lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }
            let rv = try? url.resourceValues(forKeys: Set(keys))
            let isDir = rv?.isDirectory ?? false
            out.append(Result(
                id: url,
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDir,
                fileSize: Int64(rv?.fileSize ?? 0),
                relativePath: Self.relativePath(of: url, rootPath: rootPath)
            ))
            if out.count >= limit { break }
        }
        return out.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }

    // MARK: - Contents search (Spotlight)

    private nonisolated static func searchByContents(
        root: URL,
        query: String,
        limit: Int
    ) -> [Result] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        // Match indexed text content, scoped to the root. Escape quotes in
        // the query to keep the predicate well-formed.
        let escaped = query.replacingOccurrences(of: "\"", with: "\\\"")
        process.arguments = ["-onlyin", root.path, "kMDItemTextContent == \"*\(escaped)*\"cd"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if Task.isCancelled { return [] }

        let rootPath = root.standardizedFileURL.path
        let fm = FileManager.default
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .prefix(limit)
        var out: [Result] = []
        for line in lines {
            let path = String(line)
            guard !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            out.append(Result(
                id: url,
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDir.boolValue,
                fileSize: Int64(size),
                relativePath: Self.relativePath(of: url, rootPath: rootPath)
            ))
        }
        return out.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }

    private nonisolated static func relativePath(of url: URL, rootPath: String) -> String {
        let p = url.standardizedFileURL.path
        if p.hasPrefix(rootPath) {
            let rel = String(p.dropFirst(rootPath.count))
            return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        }
        return url.lastPathComponent
    }
}
