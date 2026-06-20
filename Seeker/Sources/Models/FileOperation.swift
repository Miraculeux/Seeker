import Foundation
import Observation
import AppKit

@MainActor @Observable
class FileOperation: Identifiable {
    let id = UUID()
    let kind: Kind
    let sourceURLs: [URL]
    let destinationDir: URL
    var totalBytes: Int64 = 0
    var copiedBytes: Int64 = 0
    var currentFile: String = ""
    var filesCompleted: Int = 0
    var filesTotal: Int = 0
    var startTime: Date = .now
    var isFinished: Bool = false
    var isCancelled: Bool = false
    var error: String?
    var completedDestinations: [URL] = []
    /// Resolved per-source destination + whether the existing item there
    /// should be replaced. Populated by the conflict-resolution step;
    /// when empty, the manager falls back to auto-renaming.
    var plan: [PlannedItem] = []
    /// Whether `cleanupFinished` has already scheduled an auto-dismiss task
    /// for this operation's error. Prevents stacking sleeps if cleanup runs
    /// multiple times.
    var dismissalScheduled: Bool = false

    struct PlannedItem {
        let source: URL
        let destination: URL
        let replace: Bool
    }

    enum Kind: String {
        case copy = "Copying"
        case move = "Moving"
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(copiedBytes) / Double(totalBytes)
    }

    var speed: Int64 {
        let elapsed = Date.now.timeIntervalSince(startTime)
        guard elapsed > 0.5 else { return 0 }
        return Int64(Double(copiedBytes) / elapsed)
    }

    var estimatedTimeRemaining: TimeInterval? {
        let spd = speed
        guard spd > 0 else { return nil }
        let remaining = totalBytes - copiedBytes
        return TimeInterval(remaining) / TimeInterval(spd)
    }

    var formattedSpeed: String {
        ByteCountFormatter.string(fromByteCount: speed, countStyle: .file) + "/s"
    }

    var formattedTimeRemaining: String {
        guard let remaining = estimatedTimeRemaining else { return "Calculating..." }
        if remaining < 1 { return "Almost done" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = remaining > 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: remaining) ?? "Calculating..."
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var formattedCopiedSize: String {
        ByteCountFormatter.string(fromByteCount: copiedBytes, countStyle: .file)
    }

    init(kind: Kind, sourceURLs: [URL], destinationDir: URL) {
        self.kind = kind
        self.sourceURLs = sourceURLs
        self.destinationDir = destinationDir
        self.filesTotal = sourceURLs.count
    }

    func cancel() {
        isCancelled = true
    }
}

@MainActor @Observable
class FileOperationManager {
    static let shared = FileOperationManager()
    var operations: [FileOperation] = []

    var activeOperations: [FileOperation] {
        operations.filter { !$0.isFinished && !$0.isCancelled }
    }

    var hasActiveOperations: Bool {
        !activeOperations.isEmpty
    }

    func startCopy(sources: [URL], to destination: URL, onComplete: @escaping @MainActor (FileOperation) -> Void) {
        guard let plan = resolveConflicts(sources: sources, destination: destination, kind: .copy),
              !plan.isEmpty else { return }
        let op = FileOperation(kind: .copy, sourceURLs: plan.map(\.source), destinationDir: destination)
        op.plan = plan
        operations.append(op)
        Task {
            await performOperation(op)
            onComplete(op)
            cleanupFinished()
        }
    }

    func startMove(sources: [URL], to destination: URL, onComplete: @escaping @MainActor (FileOperation) -> Void) {
        guard let plan = resolveConflicts(sources: sources, destination: destination, kind: .move),
              !plan.isEmpty else { return }
        let op = FileOperation(kind: .move, sourceURLs: plan.map(\.source), destinationDir: destination)
        op.plan = plan
        operations.append(op)
        Task {
            await performOperation(op)
            onComplete(op)
            cleanupFinished()
        }
    }

    // MARK: - Conflict resolution

    private enum ConflictChoice { case replace, keepBoth, skip, cancel }

    /// Builds the per-source execution plan, prompting the user for any
    /// destination name collisions. Returns `nil` if the user cancels the
    /// whole operation. Finder-style rule: pasting/copying an item into
    /// its own parent directory auto-keeps-both without a prompt; moving an
    /// item into the folder it already lives in is silently skipped.
    private func resolveConflicts(sources: [URL], destination: URL, kind: FileOperation.Kind) -> [FileOperation.PlannedItem]? {
        let fm = FileManager.default
        let destStd = destination.standardizedFileURL.path
        var plan: [FileOperation.PlannedItem] = []
        var applyToAll: ConflictChoice?

        for source in sources {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            let sameDir = source.deletingLastPathComponent().standardizedFileURL.path == destStd

            guard fm.fileExists(atPath: target.path) else {
                plan.append(FileOperation.PlannedItem(source: source, destination: target, replace: false))
                continue
            }

            // Item already in the destination folder.
            if sameDir {
                if kind == .move {
                    continue // already where it'd go — nothing to do
                }
                // Copy in place → duplicate with a unique name (Finder).
                plan.append(FileOperation.PlannedItem(source: source, destination: uniqueDestination(for: source, in: destination), replace: false))
                continue
            }

            let choice = applyToAll ?? promptConflict(name: source.lastPathComponent, kind: kind, hasMore: source != sources.last)
            switch choice {
            case .cancel:
                return nil
            case .skip:
                continue
            case .replace:
                plan.append(FileOperation.PlannedItem(source: source, destination: target, replace: true))
            case .keepBoth:
                plan.append(FileOperation.PlannedItem(source: source, destination: uniqueDestination(for: source, in: destination), replace: false))
            }
            // The prompt sets applyToAll via the suppression button.
            if applyToAll == nil, lastPromptApplyToAll {
                applyToAll = choice
            }
        }
        return plan
    }

    /// Set by `promptConflict` to communicate the "Apply to all" checkbox.
    private var lastPromptApplyToAll = false

    private func promptConflict(name: String, kind: FileOperation.Kind, hasMore: Bool) -> ConflictChoice {
        let alert = NSAlert()
        alert.messageText = "An item named \u{201C}\(name)\u{201D} already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you're \(kind == .move ? "moving" : "copying")?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")     // .alertFirstButtonReturn
        alert.addButton(withTitle: "Keep Both")   // .alertSecondButtonReturn
        alert.addButton(withTitle: "Skip")        // .alertThirdButtonReturn
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"     // Esc
        if hasMore {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to all"
        }
        let response = alert.runModal()
        lastPromptApplyToAll = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        case .alertThirdButtonReturn: return .skip
        default: return .cancel
        }
    }

    private func performOperation(_ op: FileOperation) async {
        // Calculate per-source sizes once, off the main thread, and reuse
        // them when crediting progress for moves. The previous implementation
        // walked each source tree twice (once for the up-front total and
        // once per `moveItem` for progress) — for forests with many small
        // files this dominated wall time.
        let urls = op.sourceURLs
        let sizeMap: [URL: Int64] = await Task.detached(priority: .userInitiated) {
            self.calculateSizeMap(urls: urls)
        }.value
        op.totalBytes = sizeMap.values.reduce(0, +)
        op.startTime = .now

        for item in op.plan {
            guard !op.isCancelled else { break }

            let sourceURL = item.source
            let destURL = item.destination
            op.currentFile = sourceURL.lastPathComponent

            // For an explicit "Replace", remove the existing destination
            // first so move/copy land on a clean path.
            if item.replace {
                try? await Task.detached(priority: .userInitiated) {
                    try FileManager.default.removeItem(at: destURL)
                }.value
            }

            do {
                if op.kind == .move {
                    let size = sizeMap[sourceURL] ?? 0
                    try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.moveItem(at: sourceURL, to: destURL)
                    }.value
                    op.copiedBytes += size
                } else {
                    try await copyWithProgress(from: sourceURL, to: destURL, operation: op)
                }
                op.completedDestinations.append(destURL)
                op.filesCompleted += 1
            } catch is CancellationError {
                // Remove the partially copied top-level item (file or folder)
                try? FileManager.default.removeItem(at: destURL)
                break
            } catch {
                if !op.isCancelled {
                    op.error = "\(op.kind.rawValue) failed: \(error.localizedDescription)"
                }
                break
            }
        }

        op.isFinished = true
    }

    /// Build a flat list of (source, destination, size) for all files under a tree.
    private nonisolated func buildCopyManifest(source: URL, destination: URL) -> [(src: URL, dst: URL, size: Int64)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return [] }

        if isDir.boolValue {
            var pairs: [(URL, URL, Int64)] = []
            if let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                               options: [], errorHandler: nil) {
                for case let fileURL as URL in enumerator {
                    let rv = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if rv?.isDirectory == true { continue }
                    let relativePath = fileURL.path.dropFirst(source.path.count)
                    let destFile = destination.appendingPathComponent(String(relativePath))
                    let size = Int64(rv?.fileSize ?? 0)
                    pairs.append((fileURL, destFile, size))
                }
            }
            return pairs
        } else {
            let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return [(source, destination, size)]
        }
    }

    private func copyWithProgress(from source: URL, to destination: URL, operation: FileOperation) async throws {
        let manifest = buildCopyManifest(source: source, destination: destination)

        for (src, dst, size) in manifest {
            guard !operation.isCancelled else { throw CancellationError() }
            operation.currentFile = src.lastPathComponent

            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let parent = dst.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)

                // APFS fast-path: try a clone first. On the same APFS
                // volume this is effectively instant (copy-on-write) and
                // skips reading/writing entirely. Falls through to the
                // chunked copy if cloning isn't supported (cross-volume,
                // non-APFS, etc.).
                if Self.tryClone(from: src, to: dst) {
                    if size > 0 {
                        await MainActor.run { operation.copiedBytes += size }
                    }
                    return
                }

                // Use chunked copy for incremental progress; modern
                // throwing APIs surface I/O errors instead of silently
                // returning empty data / discarding writes.
                guard let readHandle = try? FileHandle(forReadingFrom: src) else {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: src.path])
                }
                defer { try? readHandle.close() }

                fm.createFile(atPath: dst.path, contents: nil)
                guard let writeHandle = try? FileHandle(forWritingTo: dst) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: dst.path])
                }
                defer { try? writeHandle.close() }

                let chunkSize = 1024 * 1024  // 1 MB chunks
                var lastUpdate = ContinuousClock.now
                var pendingBytes: Int64 = 0

                var cancelled = false
                while true {
                    if await operation.isCancelled {
                        cancelled = true
                        break
                    }

                    guard let data = try readHandle.read(upToCount: chunkSize),
                          !data.isEmpty else { break }
                    try writeHandle.write(contentsOf: data)
                    pendingBytes += Int64(data.count)

                    // Update UI at most every 50ms
                    let now = ContinuousClock.now
                    if now - lastUpdate > .milliseconds(50) {
                        let bytes = pendingBytes
                        pendingBytes = 0
                        lastUpdate = now
                        await MainActor.run { operation.copiedBytes += bytes }
                    }
                }

                // On cancellation, close handles and delete the partial file
                if cancelled {
                    try? readHandle.close()
                    try? writeHandle.close()
                    try? fm.removeItem(at: dst)
                    throw CancellationError()
                }

                // Flush remaining bytes
                if pendingBytes > 0 {
                    let bytes = pendingBytes
                    await MainActor.run { operation.copiedBytes += bytes }
                }

                // Copy file attributes (permissions, dates, etc.)
                if let attrs = try? fm.attributesOfItem(atPath: src.path) {
                    var modAttrs: [FileAttributeKey: Any] = [:]
                    if let perms = attrs[.posixPermissions] { modAttrs[.posixPermissions] = perms }
                    if let modDate = attrs[.modificationDate] { modAttrs[.modificationDate] = modDate }
                    if let creationDate = attrs[.creationDate] { modAttrs[.creationDate] = creationDate }
                    try? fm.setAttributes(modAttrs, ofItemAtPath: dst.path)
                }
            }.value
        }
    }

    /// APFS clonefile fast-path. Returns true on success, false if cloning
    /// is unsupported for this src/dst pair (e.g. cross-volume) so the
    /// caller can fall back to chunked copy.
    private nonisolated static func tryClone(from src: URL, to dst: URL) -> Bool {
        // `clonefile` requires the destination not to exist.
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { return false }
        return src.withUnsafeFileSystemRepresentation { srcPath in
            guard let srcPath else { return false }
            return dst.withUnsafeFileSystemRepresentation { dstPath in
                guard let dstPath else { return false }
                return clonefile(srcPath, dstPath, 0) == 0
            }
        }
    }

    private nonisolated func calculateTotalSize(urls: [URL]) -> Int64 {
        return calculateSizeMap(urls: urls).values.reduce(0, +)
    }

    /// Compute byte sizes for each top-level source URL in a single pass per
    /// source, recursing into directories. Returned map keys are exactly the
    /// input URLs so callers can credit progress without re-walking.
    private nonisolated func calculateSizeMap(urls: [URL]) -> [URL: Int64] {
        var map: [URL: Int64] = [:]
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                map[url] = 0
                continue
            }
            if isDir.boolValue {
                var total: Int64 = 0
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let fileURL as URL in enumerator {
                        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        total += Int64(size)
                    }
                }
                map[url] = total
            } else {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                map[url] = Int64(size)
            }
        }
        return map
    }

    private func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let fm = FileManager.default
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destURL = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while fm.fileExists(atPath: destURL.path) {
            let newName = ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)"
            destURL = directory.appendingPathComponent(newName)
            counter += 1
        }
        return destURL
    }

    /// Single in-flight cleanup task. Coalesces successive cleanup
    /// requests so we don't fan out N sleeping Tasks for N completed ops.
    private var pendingCleanupTask: Task<Void, Never>?

    private func cleanupFinished() {
        // Schedule a single delayed sweep that removes all finished
        // success-ops (errored ops are removed by their own per-op
        // dismissal task below, since they get a longer visible delay).
        if pendingCleanupTask == nil {
            pendingCleanupTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                self.operations.removeAll { $0.isFinished && $0.error == nil }
                self.pendingCleanupTask = nil
            }
        }
        for op in operations where op.error != nil && !op.dismissalScheduled {
            op.dismissalScheduled = true
            let id = op.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.operations.removeAll { $0.id == id }
            }
        }
    }
}
