import Foundation

/// A directory's remembered view settings: sort order, sort direction,
/// view mode and hidden-file visibility. Encoded per directory into a
/// standalone plist so it can be inspected / deleted independently of the
/// app's `UserDefaults` preferences.
struct DirectoryViewState: Codable, Equatable {
    var sortOrder: String
    var sortAscending: Bool
    var viewMode: String
    var showHiddenFiles: Bool

    /// Settings applied to folders the user hasn't customised, so browsing a
    /// customised folder doesn't leak its sort order into the next one.
    @MainActor
    static var appDefault: DirectoryViewState {
        let s = SettingsManager.shared
        return DirectoryViewState(
            sortOrder: s.defaultSortOrder,
            sortAscending: s.defaultSortAscending,
            viewMode: s.defaultViewMode,
            showHiddenFiles: s.defaultShowHiddenFiles
        )
    }
}

/// Persists per-directory view settings to
/// `~/Library/Application Support/<bundle id>/DirectoryViewState.plist`.
///
/// All reads/writes go through an in-memory dictionary keyed by the
/// directory's `standardizedFileURL.path`, so the navigation hot path never
/// touches disk. Mutations schedule a debounced background write; the whole
/// map is a single plist the user can find in Finder and delete, and the
/// settings UI exposes a one-tap "reset" that removes the file outright.
@MainActor
final class DirectoryViewStateStore {
    static let shared = DirectoryViewStateStore()

    private var states: [String: DirectoryViewState]
    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.seeker.dirviewstate.io", qos: .utility)
    private var flushWorkItem: DispatchWorkItem?

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.seeker.app"
        let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("DirectoryViewState.plist")
        states = Self.load(from: fileURL)
    }

    private static func load(from url: URL) -> [String: DirectoryViewState] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListDecoder()
            .decode([String: DirectoryViewState].self, from: data)) ?? [:]
    }

    private func key(for url: URL) -> String { url.standardizedFileURL.path }

    /// Number of directories currently recorded (for the settings UI).
    var count: Int { states.count }

    func state(for url: URL) -> DirectoryViewState? { states[key(for: url)] }

    func setState(_ state: DirectoryViewState, for url: URL) {
        let k = key(for: url)
        if states[k] == state { return }
        states[k] = state
        scheduleFlush()
    }

    func removeState(for url: URL) {
        if states.removeValue(forKey: key(for: url)) != nil { scheduleFlush() }
    }

    /// Clears every recorded entry and deletes the backing file immediately.
    func removeAll() {
        states.removeAll()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let url = fileURL
        let work: @Sendable () -> Void = { try? FileManager.default.removeItem(at: url) }
        ioQueue.async(execute: work)
    }

    /// Drops entries whose directory no longer exists on disk. Cheap to run
    /// occasionally to keep the file from accumulating stale paths.
    func pruneMissing() {
        let fm = FileManager.default
        var changed = false
        for path in states.keys where !fm.fileExists(atPath: path) {
            states.removeValue(forKey: path)
            changed = true
        }
        if changed { scheduleFlush() }
    }

    /// Encodes and atomically writes the snapshot. `nonisolated` + invoked
    /// only from explicitly `@Sendable` closures so it never inherits the
    /// type's `@MainActor` isolation and can run on `ioQueue`.
    private nonisolated static func persist(
        _ snapshot: [String: DirectoryViewState], to url: URL
    ) {
        if let data = try? PropertyListEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let snapshot = states
        let url = fileURL
        let work: @Sendable () -> Void = { Self.persist(snapshot, to: url) }
        let item = DispatchWorkItem(block: work)
        flushWorkItem = item
        ioQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Writes any pending changes synchronously. Called on app termination so
    /// the last edits within the debounce window aren't lost.
    func flushNow() {
        guard let work = flushWorkItem else { return }
        work.cancel()
        flushWorkItem = nil
        let snapshot = states
        let url = fileURL
        let write: @Sendable () -> Void = { Self.persist(snapshot, to: url) }
        ioQueue.sync(execute: write)
    }
}
