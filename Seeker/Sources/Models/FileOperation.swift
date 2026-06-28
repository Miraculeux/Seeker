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
    /// True while this operation is waiting its turn in the serial queue.
    var isQueued: Bool = true
    /// Completion handler invoked on the main actor when the operation
    /// finishes. Stored so the queue pump can call it.
    @ObservationIgnored var onComplete: (@MainActor (FileOperation) -> Void)?

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

    /// When true, in-flight transfers pause between files / chunks and the
    /// queue stops starting new operations until resumed.
    var isPaused = false

    /// Soft throughput cap for chunked copies, in bytes/second. `nil` is
    /// unlimited. Same-volume APFS clones and moves are not throttled.
    var throttleBytesPerSecond: Int64?

    /// Destination volumes with an operation currently transferring. The
    /// queue runs operations to the **same** volume serially (avoids disk
    /// contention) while letting **different** volumes run in parallel.
    private var busyVolumes: Set<String> = []

    /// Activity token that keeps the Mac awake while transfers are in
    /// flight. Held for the duration of any active operation and released
    /// once the queue drains, so a long copy isn't interrupted by idle
    /// sleep or sudden process termination.
    private var activityToken: NSObjectProtocol?

    var activeOperations: [FileOperation] {
        operations.filter { !$0.isFinished && !$0.isCancelled }
    }

    var hasActiveOperations: Bool {
        !activeOperations.isEmpty
    }

    /// The operation currently transferring (not just queued), if any.
    var runningOperation: FileOperation? {
        operations.first { !$0.isQueued && !$0.isFinished && !$0.isCancelled }
    }

    var queuedCount: Int {
        operations.filter { $0.isQueued && !$0.isCancelled && !$0.isFinished }.count
    }

    func startCopy(sources: [URL], to destination: URL, onComplete: @escaping @MainActor (FileOperation) -> Void) {
        guard let plan = resolveConflicts(sources: sources, destination: destination, kind: .copy),
              !plan.isEmpty else { return }
        let op = FileOperation(kind: .copy, sourceURLs: plan.map(\.source), destinationDir: destination)
        op.plan = plan
        op.onComplete = onComplete
        operations.append(op)
        pump()
    }

    func startMove(sources: [URL], to destination: URL, onComplete: @escaping @MainActor (FileOperation) -> Void) {
        guard let plan = resolveConflicts(sources: sources, destination: destination, kind: .move),
              !plan.isEmpty else { return }
        let op = FileOperation(kind: .move, sourceURLs: plan.map(\.source), destinationDir: destination)
        op.plan = plan
        op.onComplete = onComplete
        operations.append(op)
        pump()
    }

    /// Runs a pre-resolved batch of copies on behalf of folder sync. Unlike
    /// `startCopy`, the destinations are exact (relative-path preserving)
    /// targets and existing items are overwritten silently — sync semantics,
    /// no conflict prompts. Returns the operation so the caller can observe
    /// its byte-level progress, speed and ETA, and drive pause/cancel.
    @discardableResult
    func startPlannedCopy(_ plan: [FileOperation.PlannedItem],
                          onComplete: @escaping @MainActor (FileOperation) -> Void) -> FileOperation? {
        guard !plan.isEmpty else { return nil }
        let op = FileOperation(kind: .copy, sourceURLs: plan.map(\.source),
                               destinationDir: plan[0].destination.deletingLastPathComponent())
        op.plan = plan
        op.onComplete = onComplete
        operations.append(op)
        pump()
        return op
    }

    // MARK: - Queue pump

    /// Starts every queued operation whose destination volume is idle.
    /// Operations targeting the same volume run serially (less disk
    /// contention); operations on different volumes run concurrently.
    private func pump() {
        // Drop operations cancelled while still waiting in the queue.
        operations.removeAll { $0.isCancelled && $0.isQueued }
        for op in operations where op.isQueued && !op.isCancelled && !op.isFinished {
            let vol = Self.volumeKey(for: op.destinationDir)
            if busyVolumes.contains(vol) { continue }
            busyVolumes.insert(vol)
            op.isQueued = false
            Task {
                await performOperation(op)
                op.onComplete?(op)
                cleanupFinished()
                busyVolumes.remove(vol)
                updatePowerAssertion()
                pump()
            }
        }
        updatePowerAssertion()
    }

    /// Acquires or releases the no-sleep activity token to match whether any
    /// operation is currently active. Idempotent — safe to call repeatedly.
    private func updatePowerAssertion() {
        if hasActiveOperations {
            if activityToken == nil {
                activityToken = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                    reason: "Transferring files")
            }
        } else if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    /// Identifies the volume a URL lives on (its mount-point path) so the
    /// queue can serialise per-volume. Falls back to the root volume.
    private nonisolated static func volumeKey(for url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.volumeURLKey])
        return v?.volume?.path ?? "/"
    }

    func togglePause() { isPaused.toggle() }

    /// Blocks while the queue is globally paused (and the op isn't
    /// cancelled). Called between files and between copy chunks.
    func waitWhilePaused(_ op: FileOperation) async {
        while isPaused && !op.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
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

            let choice: ConflictChoice
            if let all = applyToAll {
                choice = all
            } else {
                choice = promptConflict(name: source.lastPathComponent, kind: kind, hasMore: source != sources.last)
                // Remember the choice for the rest of the batch *before* the
                // switch below — otherwise the `.skip`/`.cancel` early exits
                // would jump over this and keep re-prompting.
                if lastPromptApplyToAll { applyToAll = choice }
            }
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
            await waitWhilePaused(op)
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
            await FileOperationManager.shared.waitWhilePaused(operation)
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

                // Stream the contents with incremental progress. This call
                // preallocates contiguous space for dense files (less
                // fragmentation on big files) and preserves holes for sparse
                // files (so they never balloon to full allocation).
                do {
                    try await self.copyContents(srcFD: readHandle.fileDescriptor,
                                                dstFD: writeHandle.fileDescriptor,
                                                operation: operation)
                } catch is CancellationError {
                    try? readHandle.close()
                    try? writeHandle.close()
                    try? fm.removeItem(at: dst)
                    throw CancellationError()
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

    /// Transfer buffer size scaled to the file's logical length. Keeps small
    /// files from over-allocating while giving large files bigger chunks
    /// (fewer syscalls). Clamped so a file never gets a buffer larger than
    /// itself.
    private nonisolated static func transferChunkSize(for fileSize: Int64) -> Int {
        let mb = 1024 * 1024
        let base: Int
        switch fileSize {
        case ..<(1 * 1024 * 1024):       base = 128 * 1024   // < 1 MB
        case ..<(16 * 1024 * 1024):      base = 1 * mb       // < 16 MB
        case ..<(256 * 1024 * 1024):     base = 4 * mb       // < 256 MB
        case ..<(4 * 1024 * 1024 * 1024): base = 8 * mb      // < 4 GB
        default:                          base = 16 * mb      // >= 4 GB
        }
        if fileSize <= 0 { return base }
        return max(64 * 1024, min(base, Int(min(fileSize, Int64(base)))))
    }

    /// Streams a file's contents between two open descriptors with
    /// incremental progress, honoring pause / cancel / throttle.
    /// Two optimisations for big files:
    /// * **Dense files** get their full size reserved up front with
    ///   `F_PREALLOCATE` (contiguous when possible) so the kernel doesn't
    ///   grow + fragment the file block-by-block as we write.
    /// * **Sparse files** are detected via allocated-vs-logical size and
    ///   copied hole-aware using `SEEK_DATA` / `SEEK_HOLE`: only real data
    ///   extents are written and the gaps are left as holes, so a TB-scale
    ///   sparse file never balloons into TBs of actual blocks.
    private nonisolated func copyContents(srcFD: Int32, dstFD: Int32,
                                          operation: FileOperation) async throws {
        var st = stat()
        guard fstat(srcFD, &st) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let fileSize = Int64(st.st_size)
        // st_blocks counts 512-byte units actually allocated. A file using
        // noticeably fewer blocks than its logical length is sparse.
        let allocatedBytes = Int64(st.st_blocks) * 512
        let isSparse = fileSize > 0 && allocatedBytes < fileSize - fileSize / 10

        if isSparse {
            // Set the final logical size; unwritten regions stay holes.
            _ = ftruncate(dstFD, off_t(fileSize))
        } else if fileSize > 0 {
            // Reserve contiguous space; fall back to non-contiguous, then
            // give up silently (best-effort — writes still succeed).
            var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG),
                                 fst_posmode: F_PEOFPOSMODE,
                                 fst_offset: 0,
                                 fst_length: off_t(fileSize),
                                 fst_bytesalloc: 0)
            if fcntl(dstFD, F_PREALLOCATE, &store) == -1 {
                store.fst_flags = UInt32(F_ALLOCATEALL)
                _ = fcntl(dstFD, F_PREALLOCATE, &store)
            }
        }

        // Determine the byte ranges that actually hold data.
        var regions: [(start: Int64, end: Int64)] = []
        if isSparse {
            var pos: Int64 = 0
            while pos < fileSize {
                let dataStart = lseek(srcFD, off_t(pos), SEEK_DATA)
                if dataStart < 0 { break }           // ENXIO: rest is a hole
                let holeStart = lseek(srcFD, dataStart, SEEK_HOLE)
                let dataEnd = holeStart < 0 ? fileSize : Int64(holeStart)
                regions.append((Int64(dataStart), dataEnd))
                pos = dataEnd
            }
        } else if fileSize > 0 {
            regions.append((0, fileSize))
        }

        // Pick a transfer buffer scaled to the file size: tiny files don't
        // need (and shouldn't waste) a big allocation, while huge files
        // benefit from fewer read/write syscalls.
        let chunkSize = Self.transferChunkSize(for: fileSize)
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var lastUpdate = ContinuousClock.now
        var pendingBytes: Int64 = 0

        // Push buffered progress to the UI, at most every 50ms unless forced.
        func flush(_ now: ContinuousClock.Instant, force: Bool) async {
            guard pendingBytes > 0, force || now - lastUpdate > .milliseconds(50) else { return }
            let bytes = pendingBytes
            pendingBytes = 0
            lastUpdate = now
            await MainActor.run { operation.copiedBytes += bytes }
        }

        var lastEnd: Int64 = 0
        for region in regions {
            // Credit any skipped hole before this region as instantly copied
            // so the progress bar tracks the logical (not allocated) size.
            if region.start > lastEnd {
                pendingBytes += region.start - lastEnd
            }
            var offset = region.start
            _ = lseek(srcFD, off_t(offset), SEEK_SET)
            _ = lseek(dstFD, off_t(offset), SEEK_SET)

            while offset < region.end {
                if await operation.isCancelled { throw CancellationError() }
                await FileOperationManager.shared.waitWhilePaused(operation)

                let want = Int(min(Int64(chunkSize), region.end - offset))
                let chunkStart = ContinuousClock.now
                let n = buffer.withUnsafeMutableBytes { read(srcFD, $0.baseAddress, want) }
                if n < 0 { throw CocoaError(.fileReadUnknown) }
                if n == 0 { break }

                var written = 0
                while written < n {
                    let w = buffer.withUnsafeBytes {
                        write(dstFD, $0.baseAddress!.advanced(by: written), n - written)
                    }
                    if w < 0 { throw CocoaError(.fileWriteUnknown) }
                    written += w
                }

                offset += Int64(n)
                pendingBytes += Int64(n)
                await flush(ContinuousClock.now, force: false)

                // Throttle: sleep so this chunk takes ~bytes/limit time.
                if let limit = await MainActor.run(body: { FileOperationManager.shared.throttleBytesPerSecond }),
                   limit > 0 {
                    let target = Double(n) / Double(limit)
                    let span = ContinuousClock.now - chunkStart
                    let elapsed = Double(span.components.seconds)
                        + Double(span.components.attoseconds) / 1e18
                    let remaining = target - elapsed
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }
                }
            }
            lastEnd = region.end
        }

        // Credit a trailing hole, if any, then flush the last batch.
        if fileSize > lastEnd { pendingBytes += fileSize - lastEnd }
        await flush(ContinuousClock.now, force: true)
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
