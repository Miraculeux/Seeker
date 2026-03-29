import Foundation
import Observation

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

    func startCopy(sources: [URL], to destination: URL, onComplete: @escaping @MainActor () -> Void) {
        let op = FileOperation(kind: .copy, sourceURLs: sources, destinationDir: destination)
        operations.append(op)
        Task {
            await performOperation(op)
            onComplete()
            cleanupFinished()
        }
    }

    func startMove(sources: [URL], to destination: URL, onComplete: @escaping @MainActor () -> Void) {
        let op = FileOperation(kind: .move, sourceURLs: sources, destinationDir: destination)
        operations.append(op)
        Task {
            await performOperation(op)
            onComplete()
            cleanupFinished()
        }
    }

    private func performOperation(_ op: FileOperation) async {
        // Calculate total size off main thread
        let urls = op.sourceURLs
        op.totalBytes = await Task.detached(priority: .userInitiated) {
            self.calculateTotalSize(urls: urls)
        }.value
        op.startTime = .now

        for sourceURL in op.sourceURLs {
            guard !op.isCancelled else { break }

            let destURL = uniqueDestination(for: sourceURL, in: op.destinationDir)
            op.currentFile = sourceURL.lastPathComponent

            do {
                if op.kind == .move {
                    let size = calculateTotalSize(urls: [sourceURL])
                    try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.moveItem(at: sourceURL, to: destURL)
                    }.value
                    op.copiedBytes += size
                } else {
                    try await copyWithProgress(from: sourceURL, to: destURL, operation: op)
                }
                op.filesCompleted += 1
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

        // Batch files to reduce MainActor hops — update UI at most every 50ms
        var pendingBytes: Int64 = 0
        var lastUpdate = ContinuousClock.now

        for (src, dst, size) in manifest {
            guard !operation.isCancelled else { throw CancellationError() }

            // Copy on background thread using OS-optimized copy (supports APFS clones)
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let parent = dst.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dst)
            }.value

            pendingBytes += size
            let now = ContinuousClock.now
            if now - lastUpdate > .milliseconds(50) || pendingBytes > 10_000_000 {
                operation.copiedBytes += pendingBytes
                operation.currentFile = src.lastPathComponent
                pendingBytes = 0
                lastUpdate = now
            }
        }

        // Flush remaining
        if pendingBytes > 0 {
            operation.copiedBytes += pendingBytes
        }
    }

    private nonisolated func calculateTotalSize(urls: [URL]) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                        for case let fileURL as URL in enumerator {
                            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                            total += Int64(size)
                        }
                    }
                } else {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    total += Int64(size)
                }
            }
        }
        return total
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

    private func cleanupFinished() {
        // Remove finished operations after a delay
        Task {
            try? await Task.sleep(for: .seconds(3))
            operations.removeAll { $0.isFinished && $0.error == nil }
        }
    }
}
