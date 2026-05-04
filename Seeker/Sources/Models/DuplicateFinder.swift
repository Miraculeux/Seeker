import Foundation
import Observation

/// Finds groups of duplicate files under a root directory using a
/// three-stage filter that minimises both syscalls and bytes read.
///
/// **Stage 1 \u2014 size grouping.** `lstat` is cheap; reading a single
/// `URLResourceValue` per file is cheaper still. Files with unique
/// sizes cannot be duplicates and are discarded with zero data reads.
///
/// **Stage 2 \u2014 head hash (first 4 KB).** Files of identical size
/// often differ in their first kilobyte (different format magic, header
/// fields, embedded timestamps). A 4 KB read + xxHash3 is a single
/// syscall per candidate and eliminates almost all remaining false
/// positives at a fraction of the cost of a full-file hash.
///
/// **Stage 3 \u2014 full-file hash.** Surviving candidates are streamed
/// through XXH3 in 1 MiB chunks. Files within the same final hash
/// group are reported as duplicates.
///
/// Concurrency: the directory walk runs sequentially (single
/// `enumerator` is intrinsically serial), but the hash stages fan out
/// across `activeProcessorCount` worker tasks via `withTaskGroup`.
/// Hashing is I/O-bound on SSDs and CPU-bound on slower media; the
/// task group adapts naturally to whichever is the bottleneck.
@MainActor @Observable
final class DuplicateFinder {
    enum Status: Equatable {
        case idle
        case scanning(scanned: Int)
        case hashingHeads(done: Int, total: Int)
        case hashingFull(done: Int, total: Int, bytes: Int64, totalBytes: Int64)
        case done
        case cancelled
        case failed(String)
    }

    /// One reported group of duplicate files. All members are byte-
    /// equivalent under xxHash3-128 confidence (effectively certain
    /// for non-adversarial input).
    struct Group: Identifiable {
        let id = UUID()
        let fileSize: Int64
        let urls: [URL]

        /// Bytes that could be reclaimed by deleting all but one file
        /// in the group.
        var reclaimableBytes: Int64 {
            fileSize * Int64(max(urls.count - 1, 0))
        }
    }

    var status: Status = .idle
    var groups: [Group] = []
    /// Files smaller than this are skipped entirely. Tiny files are
    /// usually noise (caches, lockfiles) where "duplicate" carries no
    /// useful semantics; raising the floor speeds up scans dramatically.
    var minimumFileSize: Int64 = 4 * 1024

    private var currentTask: Task<Void, Never>?

    /// Total bytes that could be reclaimed across all groups.
    var totalReclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        status = .cancelled
    }

    func scan(root: URL, includeHidden: Bool = false) {
        currentTask?.cancel()
        groups = []
        status = .scanning(scanned: 0)

        let floor = minimumFileSize
        let task = Task { [weak self] in
            guard let self else { return }

            // Stage 1: enumerate + group by size, off-main.
            let bySizeResult = await Task.detached(priority: .userInitiated) { () -> [Int64: [URL]] in
                Self.enumerateBySize(root: root, includeHidden: includeHidden, minSize: floor)
            }.value

            if Task.isCancelled { self.markCancelled(); return }

            // Filter to size-classes with potential duplicates.
            let candidatesBySize = bySizeResult.filter { $0.value.count > 1 }
            let headStageURLs = candidatesBySize.values.flatMap { $0 }
            let headTotal = headStageURLs.count
            self.status = .hashingHeads(done: 0, total: headTotal)

            if headTotal == 0 { self.status = .done; return }

            // Stage 2: head hash, parallel over workers.
            let headHashes = await Self.hashHeads(urls: headStageURLs) { done in
                Task { @MainActor in
                    self.status = .hashingHeads(done: done, total: headTotal)
                }
            }

            if Task.isCancelled { self.markCancelled(); return }

            // Re-group by (size, headHash). Anything that doesn't have
            // \u2265 2 members at this point can't be a duplicate.
            var bySizeAndHead: [SizeHeadKey: [URL]] = [:]
            for (size, urls) in candidatesBySize {
                for url in urls {
                    guard let head = headHashes[url] else { continue }
                    bySizeAndHead[SizeHeadKey(size: size, head: head), default: []].append(url)
                }
            }
            let fullStageGroups = bySizeAndHead.filter { $0.value.count > 1 }
            let fullStageURLs = fullStageGroups.values.flatMap { $0 }
            let fullTotal = fullStageURLs.count
            let fullTotalBytes = fullStageGroups.reduce(0) { acc, kv in
                acc + Int64(kv.value.count) * kv.key.size
            }

            if fullTotal == 0 { self.status = .done; return }

            self.status = .hashingFull(done: 0, total: fullTotal, bytes: 0, totalBytes: fullTotalBytes)

            // Stage 3: full hash, parallel.
            let fullHashes = await Self.hashFullFiles(urls: fullStageURLs) { done, bytesAdded in
                Task { @MainActor in
                    if case let .hashingFull(_, total, bytes, totalBytes) = self.status {
                        self.status = .hashingFull(
                            done: done,
                            total: total,
                            bytes: bytes + bytesAdded,
                            totalBytes: totalBytes
                        )
                    }
                }
            }

            if Task.isCancelled { self.markCancelled(); return }

            // Final regrouping by (size, fullHash).
            var byFullHash: [SizeFullKey: [URL]] = [:]
            for (key, urls) in fullStageGroups {
                for url in urls {
                    guard let h = fullHashes[url] else { continue }
                    byFullHash[SizeFullKey(size: key.size, full: h), default: []].append(url)
                }
            }
            let finalGroups = byFullHash
                .filter { $0.value.count > 1 }
                .map { Group(fileSize: $0.key.size, urls: $0.value.sorted { $0.path < $1.path }) }
                .sorted { $0.reclaimableBytes > $1.reclaimableBytes }

            self.groups = finalGroups
            self.status = .done
        }
        currentTask = task
    }

    private func markCancelled() {
        status = .cancelled
    }

    // MARK: - Stage 1: enumerate by size

    private struct SizeHeadKey: Hashable { let size: Int64; let head: UInt64 }
    private struct SizeFullKey: Hashable { let size: Int64; let full: UInt64 }

    private nonisolated static func enumerateBySize(
        root: URL,
        includeHidden: Bool,
        minSize: Int64
    ) -> [Int64: [URL]] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        let opts: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: opts,
            errorHandler: { _, _ in true }
        ) else { return [:] }

        let keySet = Set(keys)
        var bySize: [Int64: [URL]] = [:]
        var counter = 0
        while let url = enumerator.nextObject() as? URL {
            counter &+= 1
            if counter & 0xFF == 0, Task.isCancelled { return [:] }
            guard let rv = try? url.resourceValues(forKeys: keySet),
                  rv.isRegularFile == true,
                  rv.isSymbolicLink != true,
                  let size = rv.fileSize, Int64(size) >= minSize else { continue }
            bySize[Int64(size), default: []].append(url)
        }
        return bySize
    }

    // MARK: - Stage 2/3: parallel hashing

    /// Fan out head-hash work across the processor count, returning a
    /// URL\u2192hash map. Progress is reported via `progress(done)`.
    private nonisolated static func hashHeads(
        urls: [URL],
        progress: @escaping @Sendable (_ done: Int) -> Void
    ) async -> [URL: UInt64] {
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
        return await withTaskGroup(of: (URL, UInt64?).self) { group in
            // Bound parallelism so we don't spawn O(n) tasks.
            var iterator = urls.makeIterator()
            var inFlight = 0
            var results: [URL: UInt64] = [:]
            results.reserveCapacity(urls.count)
            var completed = 0

            // Prime the pump.
            for _ in 0..<workers {
                guard let next = iterator.next() else { break }
                group.addTask { (next, XXHash3.hashFileHead(at: next)) }
                inFlight += 1
            }

            while inFlight > 0 {
                guard let result = await group.next() else { break }
                inFlight -= 1
                if let h = result.1 { results[result.0] = h }
                completed += 1
                if completed & 0x3F == 0 || iterator.underestimatedCount == 0 {
                    progress(completed)
                }
                if Task.isCancelled { continue }
                if let next = iterator.next() {
                    group.addTask { (next, XXHash3.hashFileHead(at: next)) }
                    inFlight += 1
                }
            }
            progress(completed)
            return results
        }
    }

    private nonisolated static func hashFullFiles(
        urls: [URL],
        progress: @escaping @Sendable (_ done: Int, _ bytesAdded: Int64) -> Void
    ) async -> [URL: UInt64] {
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
        return await withTaskGroup(of: (URL, UInt64?, Int64).self) { group in
            var iterator = urls.makeIterator()
            var inFlight = 0
            var results: [URL: UInt64] = [:]
            results.reserveCapacity(urls.count)
            var completed = 0

            for _ in 0..<workers {
                guard let next = iterator.next() else { break }
                group.addTask {
                    let h = XXHash3.hashFile(at: next)
                    let size = Int64((try? next.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    return (next, h, size)
                }
                inFlight += 1
            }

            while inFlight > 0 {
                guard let result = await group.next() else { break }
                inFlight -= 1
                if let h = result.1 { results[result.0] = h }
                completed += 1
                progress(completed, result.2)
                if Task.isCancelled { continue }
                if let next = iterator.next() {
                    group.addTask {
                        let h = XXHash3.hashFile(at: next)
                        let size = Int64((try? next.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                        return (next, h, size)
                    }
                    inFlight += 1
                }
            }
            return results
        }
    }
}
