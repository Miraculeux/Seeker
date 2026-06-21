import Foundation
import Observation

/// Computes and applies a sync plan between two directory trees. Files
/// are matched by relative subpath; "changed" is detected by comparing
/// size and modification time. Three directions:
///
/// - **Mirror (A → B)**: make B identical to A — copy new/changed files
///   from A, and move B-only files to the Trash.
/// - **Update (A → B)**: copy files that are new or newer in A to B.
///   Never deletes; B-only files are left untouched.
/// - **Two-way**: the newer copy of each file wins on both sides; A-only
///   files go to B and B-only files go to A. Never deletes.
@MainActor @Observable
final class FolderSyncer {
    enum Direction: String, CaseIterable, Identifiable {
        case mirror
        case update
        case twoWay
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mirror: return "Mirror A \u{2192} B"
            case .update: return "Update A \u{2192} B"
            case .twoWay: return "Two-way"
            }
        }
    }

    enum Status: Equatable {
        case idle
        case analyzing
        case ready
        case syncing(done: Int, total: Int)
        case finished(applied: Int, failed: Int)
        case failed(String)
        case cancelled
    }

    struct Action: Identifiable {
        enum Kind {
            case copyToB    // A → B
            case copyToA    // B → A
            case deleteB    // remove from B
            var symbol: String {
                switch self {
                case .copyToB: return "arrow.right"
                case .copyToA: return "arrow.left"
                case .deleteB: return "trash"
                }
            }
            var label: String {
                switch self {
                case .copyToB: return "Copy to B"
                case .copyToA: return "Copy to A"
                case .deleteB: return "Delete from B"
                }
            }
        }
        let id = UUID()
        let kind: Kind
        let relativePath: String
        /// The file being copied (nil for deletes).
        let source: URL?
        /// Where the copy lands, or the file to delete.
        let destination: URL
        let size: Int64
        var enabled: Bool = true
    }

    let rootA: URL
    let rootB: URL
    var direction: Direction = .update
    var includeHidden = false

    var status: Status = .idle
    var actions: [Action] = []
    /// When true, in-flight sync actions pause before the next file.
    var isPaused = false

    private var currentTask: Task<Void, Never>?
    /// Completed-action counter, mutated on the main actor as each volume
    /// group reports progress.
    private var completedCount = 0

    init(rootA: URL, rootB: URL) {
        self.rootA = rootA
        self.rootB = rootB
    }

    var enabledActions: [Action] { actions.filter(\.enabled) }

    var totalBytes: Int64 {
        enabledActions.reduce(0) { $0 + ($1.kind == .deleteB ? 0 : $1.size) }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        status = .cancelled
    }

    func togglePause() { isPaused.toggle() }

    /// Blocks while paused (with a cancellation escape). Called before
    /// each action inside a volume group.
    func waitWhilePaused() async {
        while isPaused {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func bumpProgress(total: Int) {
        completedCount += 1
        if case .syncing = status {
            status = .syncing(done: completedCount, total: total)
        }
    }

    // MARK: - Analyze

    func analyze() {
        currentTask?.cancel()
        status = .analyzing
        actions = []

        let a = rootA
        let b = rootB
        let dir = direction
        let hidden = includeHidden
        let task = Task { [weak self] in
            guard let self else { return }
            let plan = await Task.detached(priority: .userInitiated) { () -> [Action] in
                Self.buildPlan(a: a, b: b, direction: dir, includeHidden: hidden)
            }.value
            if Task.isCancelled { return }
            self.actions = plan
            self.status = .ready
        }
        currentTask = task
    }

    private struct FileMeta {
        let url: URL
        let size: Int64
        let mtime: Date
    }

    private nonisolated static func buildPlan(
        a: URL,
        b: URL,
        direction: Direction,
        includeHidden: Bool
    ) -> [Action] {
        let mapA = scan(a, includeHidden: includeHidden)
        let mapB = scan(b, includeHidden: includeHidden)
        var plan: [Action] = []

        // Files in A (and possibly B).
        for (rel, metaA) in mapA {
            if let metaB = mapB[rel] {
                // Present on both sides — compare.
                if sameFile(metaA, metaB) { continue }
                let aNewer = metaA.mtime > metaB.mtime
                switch direction {
                case .mirror, .update where aNewer:
                    plan.append(Action(kind: .copyToB, relativePath: rel, source: metaA.url,
                                       destination: b.appendingPathComponent(rel), size: metaA.size))
                case .update:
                    break // B is newer/equal; update never downgrades
                case .twoWay:
                    if aNewer {
                        plan.append(Action(kind: .copyToB, relativePath: rel, source: metaA.url,
                                           destination: b.appendingPathComponent(rel), size: metaA.size))
                    } else {
                        plan.append(Action(kind: .copyToA, relativePath: rel, source: metaB.url,
                                           destination: a.appendingPathComponent(rel), size: metaB.size))
                    }
                }
            } else {
                // Only in A → copy to B in every direction.
                plan.append(Action(kind: .copyToB, relativePath: rel, source: metaA.url,
                                   destination: b.appendingPathComponent(rel), size: metaA.size))
            }
        }

        // Files only in B.
        for (rel, metaB) in mapB where mapA[rel] == nil {
            switch direction {
            case .mirror:
                plan.append(Action(kind: .deleteB, relativePath: rel, source: nil,
                                   destination: metaB.url, size: metaB.size))
            case .update:
                break // leave B-only files alone
            case .twoWay:
                plan.append(Action(kind: .copyToA, relativePath: rel, source: metaB.url,
                                   destination: a.appendingPathComponent(rel), size: metaB.size))
            }
        }

        return plan.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }

    /// Two files are considered identical when size and modification time
    /// (to the second) match. Content is not hashed.
    private nonisolated static func sameFile(_ x: FileMeta, _ y: FileMeta) -> Bool {
        x.size == y.size && abs(x.mtime.timeIntervalSince(y.mtime)) < 1.0
    }

    private nonisolated static func scan(_ root: URL, includeHidden: Bool) -> [String: FileMeta] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let opts: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: opts,
            errorHandler: { _, _ in true }
        ) else { return [:] }

        let rootPath = root.standardizedFileURL.path
        let keySet = Set(keys)
        var map: [String: FileMeta] = [:]
        var counter = 0
        while let url = enumerator.nextObject() as? URL {
            counter &+= 1
            if counter & 0x3FF == 0, Task.isCancelled { return map }
            let rv = try? url.resourceValues(forKeys: keySet)
            guard rv?.isRegularFile == true else { continue }
            let p = url.standardizedFileURL.path
            var rel = p.hasPrefix(rootPath) ? String(p.dropFirst(rootPath.count)) : url.lastPathComponent
            if rel.hasPrefix("/") { rel.removeFirst() }
            map[rel] = FileMeta(
                url: url,
                size: Int64(rv?.fileSize ?? 0),
                mtime: rv?.contentModificationDate ?? .distantPast
            )
        }
        return map
    }

    // MARK: - Apply

    /// Executes the enabled actions. Actions are grouped by their
    /// destination volume: groups run **concurrently** (different disks
    /// progress in parallel) while each group runs **serially** (same
    /// disk avoids contention). Honors `isPaused`. Copies overwrite
    /// silently (sync semantics); deletes go to the Trash.
    func apply() {
        currentTask?.cancel()
        isPaused = false
        completedCount = 0
        let items = enabledActions
        guard !items.isEmpty else { status = .finished(applied: 0, failed: 0); return }
        let total = items.count
        status = .syncing(done: 0, total: total)

        // Partition by the volume the file lands on.
        let groups = Dictionary(grouping: items) { Self.volumeKey(for: $0.destination) }

        let task = Task { [weak self] in
            guard let self else { return }
            let tally = await withTaskGroup(of: (Int, Int).self) { group -> (Int, Int) in
                for (_, actions) in groups {
                    group.addTask {
                        var applied = 0
                        var failed = 0
                        for action in actions {
                            if Task.isCancelled { break }
                            await self.waitWhilePaused()
                            if Task.isCancelled { break }
                            let ok = Self.perform(action)
                            if ok { applied += 1 } else { failed += 1 }
                            await self.bumpProgress(total: total)
                        }
                        return (applied, failed)
                    }
                }
                var a = 0
                var f = 0
                for await (applied, failed) in group { a += applied; f += failed }
                return (a, f)
            }
            if Task.isCancelled { self.status = .cancelled; return }
            self.status = .finished(applied: tally.0, failed: tally.1)
            NotificationCenter.default.post(name: .filesDidChange, object: nil)
        }
        currentTask = task
    }

    /// Identifies the volume a URL lives on (its mount-point path) so the
    /// sync can run per-volume groups in parallel.
    private nonisolated static func volumeKey(for url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.volumeURLKey])
        return v?.volume?.path ?? "/"
    }

    private nonisolated static func perform(_ action: Action) -> Bool {
        let fm = FileManager.default
        do {
            switch action.kind {
            case .copyToB, .copyToA:
                guard let source = action.source else { return false }
                let dest = action.destination
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: source, to: dest)
                return true
            case .deleteB:
                try fm.trashItem(at: action.destination, resultingItemURL: nil)
                return true
            }
        } catch {
            print("[Seeker] Sync \(action.kind.label) failed for \(action.relativePath): \(error)")
            return false
        }
    }
}
