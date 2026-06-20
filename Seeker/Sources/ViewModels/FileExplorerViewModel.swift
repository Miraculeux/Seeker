import Foundation
import Observation
import AppKit

extension Notification.Name {
    static let explorerDidNavigate = Notification.Name("explorerDidNavigate")
    static let columnSettingsChanged = Notification.Name("columnSettingsChanged")
    static let filesDidChange = Notification.Name("filesDidChange")
    static let iconSizeDidChange = Notification.Name("iconSizeDidChange")
    /// Posted when the global "Move to Trash" menu shortcut (⌘⌫) fires
    /// while a standalone helper window (duplicate finder / folder
    /// compare) is key. The key window's triage panel handles it so the
    /// shortcut acts on that window's selection, not the main window's.
    static let triageMoveToTrashRequested = Notification.Name("triageMoveToTrashRequested")
    /// Posted when ⌘A fires while a helper window is key. The key
    /// window's triage panel selects all of its files.
    static let triageSelectAllRequested = Notification.Name("triageSelectAllRequested")
}

@MainActor @Observable
class FileExplorerViewModel: Identifiable {
    let id = UUID()
    var currentURL: URL {
        didSet {
            _cachedPathComponents = nil
            _standardizedCurrentURL = currentURL.standardizedFileURL
        }
    }
    /// Cache of `currentURL.standardizedFileURL`. The cross-tab change
    /// notifier compares this against the affected directory once per
    /// fan-out; recomputing the standardisation each time was visible
    /// when many tabs were open.
    @ObservationIgnored private var _standardizedCurrentURL: URL
    /// Sorted, unfiltered listing as loaded from disk. Source of truth for
    /// the visible `files` list — filter changes do not touch the disk.
    private var allFiles: [FileItem] = []
    /// Sorted, unfiltered children of each expanded directory, keyed by
    /// the parent's `FileItem.ID`. Built lazily on the first expansion of
    /// each directory; refreshed when `loadFiles()` reloads the tab.
    @ObservationIgnored private var childrenByParentID: [FileItem.ID: [FileItem]] = [:]
    /// Set of directory ids whose children should be flattened into the
    /// visible `files` list under their parent row. Persisted across
    /// reloads of the current tab; cleared on `navigateTo(_:)`.
    var expandedDirectoryIDs: Set<FileItem.ID> = []
    /// Directories that have an in-flight child enumeration. Used by the
    /// row UI to show a spinner instead of the disclosure chevron.
    var loadingDirectoryIDs: Set<FileItem.ID> = []
    /// Tree depth (number of ancestors) per displayed row. Top-level rows
    /// are depth 0. Rebuilt by `rebuildVisibleFiles()` whenever the
    /// expansion / filter / sort state changes.
    @ObservationIgnored private var rowDepthByID: [FileItem.ID: Int] = [:]
    /// Currently displayed (filtered) files. Maintained alongside an O(1)
    /// id→index lookup so `selectedFile`/`selectedFiles` don't rebuild a
    /// dictionary on every access.
    var files: [FileItem] = [] {
        didSet {
            var idx: [FileItem.ID: Int] = [:]
            idx.reserveCapacity(files.count)
            for (i, f) in files.enumerated() { idx[f.id] = i }
            fileIndex = idx
            _cachedSelectedFiles = nil
            _cachedSelectedFilesToken = nil
        }
    }
    private var fileIndex: [FileItem.ID: Int] = [:]
    var selectionAnchor: FileItem?
    var selectedFileIDs: Set<FileItem.ID> = [] {
        didSet {
            if selectedFileIDs != oldValue {
                _cachedSelectedFiles = nil
                _cachedSelectedFilesToken = nil
            }
        }
    }
    /// Memoized result of `selectedFiles`. Many callers (info pane,
    /// effectiveSelection, toolbar predicates) read this several times per
    /// render; rebuilding the Set every time was O(n) on the selection.
    @ObservationIgnored private var _cachedSelectedFiles: Set<FileItem>?
    @ObservationIgnored private var _cachedSelectedFilesToken: Int?
    var iconGridColumnCount: Int = 1

    /// Icon-grid icon edge length, mirrored into `SettingsManager` so the
    /// value persists across launches and propagates to the other pane via
    /// `.iconSizeDidChange`.
    ///
    /// During continuous gestures (pinch, slider drag) callers should use
    /// `setIconSizeLive(_:)` so we don't hit `UserDefaults` and broadcast
    /// to other panes on every tick — then call `commitIconSize(_:)`
    /// once the value stabilises.
    var iconSize: CGFloat = SettingsManager.shared.iconSize {
        didSet {
            // Clamp without re-entering didSet: compute the clamped value
            // and bail if it differs from the assigned value (the recursive
            // re-assign below will fire didSet again with the clean value).
            let clamped = min(max(iconSize, SettingsManager.iconSizeMin), SettingsManager.iconSizeMax)
            if clamped != iconSize {
                iconSize = clamped
                return
            }
            // Suppress the persist + cross-pane broadcast when nothing
            // actually changed (e.g. commit at the same value the slider
            // already settled at).
            guard clamped != oldValue else { return }
            guard !_iconSizeSuppressBroadcast else { return }
            SettingsManager.shared.iconSize = clamped
            NotificationCenter.default.post(
                name: .iconSizeDidChange, object: self,
                userInfo: ["size": clamped]
            )
        }
    }
    /// When true, a continuous icon-zoom gesture (pinch / slider drag) is
    /// in progress. Cells consult this in their `.task(id:)` to avoid
    /// firing QL/disk thumbnail lookups for every intermediate bucket
    /// the gesture passes through; the final commit re-fires loads at
    /// the resting bucket only.
    var isLiveZooming: Bool = false

    /// When true, the `iconSize` setter skips persistence + broadcast.
    /// Used during continuous gestures so we don't churn UserDefaults
    /// and re-render other panes on every micro-update.
    private var _iconSizeSuppressBroadcast: Bool = false

    var selectedFile: FileItem? {
        if let anchor = selectionAnchor, selectedFileIDs.contains(anchor.id) {
            return anchor
        }
        guard let firstID = selectedFileIDs.first,
              let i = fileIndex[firstID] else { return nil }
        return files[i]
    }

    var selectedFiles: Set<FileItem> {
        // Combine selection-id set hash with the files-array identity
        // (count is sufficient because `files`'s didSet already clears the
        // cache on any reassignment) so we rebuild only when something
        // actually changed.
        let token = selectedFileIDs.hashValue &+ files.count
        if let cached = _cachedSelectedFiles, _cachedSelectedFilesToken == token {
            return cached
        }
        var result = Set<FileItem>()
        result.reserveCapacity(selectedFileIDs.count)
        for id in selectedFileIDs {
            if let i = fileIndex[id] { result.insert(files[i]) }
        }
        _cachedSelectedFiles = result
        _cachedSelectedFilesToken = token
        return result
    }
    var pathHistory: [URL] = []
    var historyIndex: Int = -1
    var sortOrder: SortOrder = .name
    var sortAscending: Bool = true
    var showHiddenFiles: Bool = false
    var searchText: String = ""
    var isSearching: Bool = false
    var renamingFile: FileItem?
    var renameText: String = ""
    var errorMessage: String?
    var showError: Bool = false
    var viewMode: ViewMode = .list {
        didSet {
            // Switching between list (tree-capable) and icon / column
            // (flat) views must rebuild `files`: in non-list modes the
            // flattened-tree representation would surface child rows
            // without any indentation cue, which is confusing.
            if oldValue != viewMode { rebuildVisibleFiles() }
        }
    }
    var undoStack: [UndoableAction] = []

    enum UndoableAction {
        case trash(originalURLs: [URL], trashURLs: [URL])
        case create(url: URL)
        case rename(oldURL: URL, newURL: URL)
        case copy(destinationURLs: [URL])
        case move(originalURLs: [URL], destinationURLs: [URL])
    }

    var canUndo: Bool { !undoStack.isEmpty }

    // Clipboard for copy/cut operations
    static nonisolated(unsafe) var clipboard: [URL] = []
    static nonisolated(unsafe) var clipboardIsCut: Bool = false

    enum ViewMode: String, CaseIterable {
        case list = "List"
        case icons = "Icons"
        case columns = "Columns"
    }

    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case date = "Date Modified"
        case size = "Size"
        case kind = "Kind"
    }

    private let _observer = UncheckedSendableBox<Any?>(nil)
    private let _zoomObserver = UncheckedSendableBox<Any?>(nil)

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = url
        self._standardizedCurrentURL = url.standardizedFileURL
        navigateTo(url)
        _observer.value = NotificationCenter.default.addObserver(
            forName: .filesDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, notification.object as AnyObject? !== self else { return }
            // Extract the affected dir on the notification's queue (.main),
            // before hopping into the MainActor isolation context.
            let affectedDir = notification.userInfo?[Self.affectedDirKey] as? URL
            MainActor.assumeIsolated {
                // Skip the reload if we know which directory changed and
                // it's not the one this tab is viewing. Cuts cross-tab
                // fan-out from O(tabs) to O(tabs viewing same dir).
                if let dir = affectedDir {
                    let here = self._standardizedCurrentURL
                    let changed = dir.standardizedFileURL
                    if here != changed { return }
                }
                self.loadFiles()
            }
        }
        // Mirror icon-zoom changes from the other pane so both pane
        // grids stay in lockstep.
        _zoomObserver.value = NotificationCenter.default.addObserver(
            forName: .iconSizeDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, notification.object as AnyObject? !== self else { return }
            let size = notification.userInfo?["size"] as? CGFloat
            MainActor.assumeIsolated {
                if let s = size, s != self.iconSize {
                    // Assign without re-broadcasting (didSet skips equal values).
                    self.iconSize = s
                }
            }
        }
    }

    deinit {
        if let observer = _observer.value {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = _zoomObserver.value {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Icon Zoom

    /// Discrete zoom levels (in points). Step-based so ⌘+/⌘− land on the
    /// same values regardless of which key the user pressed first, and so
    /// pinch gestures snap to predictable sizes. Top end matches Finder.
    nonisolated static let iconZoomSteps: [CGFloat] = [16, 24, 32, 48, 64, 96, 128, 160, 192, 256, 320, 384, 448, 512]

    func zoomIconsIn() {
        let next = Self.iconZoomSteps.first(where: { $0 > iconSize }) ?? Self.iconZoomSteps.last!
        commitIconSize(next)
    }

    func zoomIconsOut() {
        let prev = Self.iconZoomSteps.last(where: { $0 < iconSize }) ?? Self.iconZoomSteps.first!
        commitIconSize(prev)
    }

    func resetIconZoom() {
        commitIconSize(SettingsManager.iconSizeDefault)
    }

    /// Sets the icon size from a continuous source (pinch, slider drag)
    /// without persisting or broadcasting. Cheap enough to call on every
    /// gesture tick. Caller must invoke `commitIconSize(_:)` when the
    /// value stabilises (typically gesture end) so the change is saved
    /// and mirrored to the other pane.
    func setIconSizeLive(_ size: CGFloat) {
        if !isLiveZooming { isLiveZooming = true }
        _iconSizeSuppressBroadcast = true
        iconSize = size
        _iconSizeSuppressBroadcast = false
    }

    /// Persists `size` and broadcasts to other panes. Use after a
    /// continuous gesture finishes, or for any one-shot change
    /// (keyboard shortcut, menu item).
    func commitIconSize(_ size: CGFloat) {
        // Force the didSet broadcast even if the live setter already
        // moved iconSize to this value during the gesture.
        let clamped = min(max(size, SettingsManager.iconSizeMin), SettingsManager.iconSizeMax)
        if iconSize == clamped {
            // Re-emit so the other pane and UserDefaults pick it up
            // even though our local property didn't change value.
            SettingsManager.shared.iconSize = clamped
            NotificationCenter.default.post(
                name: .iconSizeDidChange, object: self,
                userInfo: ["size": clamped]
            )
        } else {
            iconSize = clamped
        }
        // Releasing the live-zoom flag triggers cells' .task(id:) to
        // fire one final exact-bucket render at the resting size.
        if isLiveZooming { isLiveZooming = false }
    }

    /// Back-compat alias that now persists. Existing call sites that
    /// just want a one-shot change keep working.
    func setIconSize(_ size: CGFloat) {
        commitIconSize(size)
    }

    // MARK: - Navigation

    func navigateTo(_ url: URL) {
        let isSameURL = (currentURL == url)
        currentURL = url
        searchText = ""
        isSearching = false
        selectionAnchor = nil
        selectedFileIDs = []
        // Leaving the current directory invalidates the tree expansion
        // state — child caches are keyed by URL but it's confusing for
        // the user if previously-expanded folders stay expanded after a
        // navigation. Collapse everything.
        expandedDirectoryIDs.removeAll()
        loadingDirectoryIDs.removeAll()
        childrenByParentID.removeAll()
        rowDepthByID.removeAll()

        // Manage history (skip duplicate if navigating to same URL)
        if !isSameURL {
            if historyIndex < pathHistory.count - 1 {
                pathHistory = Array(pathHistory.prefix(historyIndex + 1))
            }
            pathHistory.append(url)
            historyIndex = pathHistory.count - 1
        }

        loadFiles()

        // Notify so AppState can persist location
        NotificationCenter.default.post(name: .explorerDidNavigate, object: nil)
    }

    func loadFiles() {
        // Snapshot all main-actor state needed for the off-main enumeration,
        // then hop back to assign results. Bulk `URLResourceValues` keys are
        // batched by Foundation in a single getattrlistbulk sweep — far
        // cheaper than per-file lstat + NSWorkspace.isFilePackage in init.
        let url = currentURL.standardizedFileURL
        let options: FileManager.DirectoryEnumerationOptions =
            showHiddenFiles ? [] : [.skipsHiddenFiles]
        let trashURL = FileManager.default
            .homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let isTrash = url.standardizedFileURL == trashURL.standardizedFileURL
            || url.resolvingSymlinksInPath() == trashURL.resolvingSymlinksInPath()
        let token = nextLoadToken()

        Task.detached(priority: .userInitiated) {
            var items: [FileItem]
            if isTrash {
                items = Self.loadTrashViaFinder()
                if items.isEmpty {
                    // If AppleScript returned nothing, still try the
                    // direct enumeration as a fall-through.
                    items = Self.enumerate(url: url, options: options) ?? []
                }
            } else {
                items = Self.enumerate(url: url, options: options) ?? []
            }

            await MainActor.run { [weak self] in
                guard let self, self.currentLoadToken == token else { return }
                let sorted = self.sortItems(items)
                self.allFiles = sorted
                self.rebuildVisibleFiles()
                self.applyPendingSelection()
                self.refreshExpandedChildren()
            }
        }
    }

    /// URL that should be selected once the next `loadFiles()` completes.
    /// Used by `revealAndSelect(_:)` so callers from outside the explorer
    /// (e.g. the duplicate-finder sheet) can highlight a specific file
    /// after navigating to its parent directory.
    @ObservationIgnored private var pendingSelectionURL: URL?
    /// When set, the next successful `applyPendingSelection()` also opens
    /// the inline rename editor on the resolved item. Used by
    /// `createNewFolder` / `createNewFile` so the rename TextField focuses
    /// on the row only after `loadFiles()` has reloaded the listing.
    @ObservationIgnored private var pendingRenameOnSelect: Bool = false

    private func applyPendingSelection() {
        guard let target = pendingSelectionURL else { return }
        let standardizedPath = target.standardizedFileURL.path
        if let match = files.first(where: {
            // Compare on `path` rather than the full URL: directory URLs
            // returned by `contentsOfDirectory` carry a trailing slash
            // while ones built via `appendingPathComponent(name)` do not,
            // and `standardizedFileURL` preserves that distinction.
            $0.url.standardizedFileURL.path == standardizedPath
        }) {
            pendingSelectionURL = nil
            selectedFileIDs = [match.id]
            selectionAnchor = match
            if pendingRenameOnSelect {
                pendingRenameOnSelect = false
                // Defer the rename one runloop so SwiftUI mounts the
                // newly-appeared row (with selection) before we flip it
                // into editing mode. Setting renamingFile in the same
                // tick as `files` left the TextField unfocused because
                // its `.onAppear` ran before the focus binding was wired
                // into the responder chain.
                let item = match
                DispatchQueue.main.async { [weak self] in
                    self?.beginRename(item)
                }
            }
        }
        // If no match yet (listing not loaded, or hidden by filter),
        // leave the pending URL set so a later loadFiles() can catch it.
    }

    /// Navigate to `url`'s parent directory and select `url` once the
    /// listing has loaded. If already in the parent, selects immediately.
    func revealAndSelect(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        pendingSelectionURL = url
        if currentURL.standardizedFileURL == parent.standardizedFileURL {
            // Already there \u2014 either files are loaded (apply now) or a
            // load is in flight (handler will apply on completion).
            applyPendingSelection()
        } else {
            navigateTo(parent)
        }
    }

    /// Off-actor directory enumeration. Returns `nil` on error so the
    /// caller can decide whether to fall back to a special-cased path
    /// (e.g. Trash via Finder AppleScript).
    private nonisolated static func enumerate(
        url: URL,
        options: FileManager.DirectoryEnumerationOptions
    ) -> [FileItem]? {
        let fm = FileManager.default
        let keys = FileItem.prefetchKeys
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: options
            )
        } catch {
            // Try resolving symlinks as a one-shot retry.
            let resolved = url.resolvingSymlinksInPath()
            guard let alt = try? fm.contentsOfDirectory(
                at: resolved, includingPropertiesForKeys: keys, options: options
            ) else { return nil }
            return Self.buildItems(from: alt, keys: keys)
        }
        return Self.buildItems(from: contents, keys: keys)
    }

    private nonisolated static func buildItems(from urls: [URL], keys: [URLResourceKey]) -> [FileItem] {
        let keySet = Set(keys)
        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for u in urls {
            let rv = (try? u.resourceValues(forKeys: keySet)) ?? URLResourceValues()
            items.append(FileItem(url: u, resourceValues: rv))
        }
        return items
    }

    /// Monotonically increasing token used to drop stale `loadFiles()`
    /// results when navigation happens faster than enumeration completes.
    private var _loadToken: UInt64 = 0
    private var currentLoadToken: UInt64 { _loadToken }
    private func nextLoadToken() -> UInt64 {
        _loadToken &+= 1
        return _loadToken
    }

    /// Apply the in-memory filter to a sorted listing. Cheap (O(n) string
    /// compare) and does not touch the disk — safe to call on every keystroke.
    private func applyFilter(to items: [FileItem]) -> [FileItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Re-apply the search filter to the current listing without re-reading
    /// from disk. Bind this to `searchText` changes instead of `loadFiles()`.
    func refilter() {
        rebuildVisibleFiles()
    }

    // MARK: - Tree Expansion (Finder-style list view)

    /// Whether `file` is a directory whose children can be expanded inline.
    /// Packages (`.app`, `.bundle`, …) are treated as opaque files.
    func isExpandable(_ file: FileItem) -> Bool {
        file.isDirectory && !file.isPackage
    }

    /// `true` when `file`'s children are currently inlined into `files`.
    func isExpanded(_ file: FileItem) -> Bool {
        expandedDirectoryIDs.contains(file.id)
    }

    /// `true` while an off-actor child enumeration is in flight for `file`.
    func isLoadingChildren(_ file: FileItem) -> Bool {
        loadingDirectoryIDs.contains(file.id)
    }

    /// Tree depth of `file` in the visible `files` list. Top-level rows
    /// are depth 0; each expanded ancestor adds one level of indent.
    func depth(of file: FileItem) -> Int {
        rowDepthByID[file.id] ?? 0
    }

    /// Position of `file` in the visible rows, or 0 if it's not present.
    /// Used by the list view to drive alternating row backgrounds without
    /// pulling the whole `files` index into the view.
    func fileRowIndex(_ file: FileItem) -> Int {
        fileIndex[file.id] ?? 0
    }

    /// Toggle inline expansion of `file`. No-op on non-directories or
    /// packages.
    func toggleExpanded(_ file: FileItem) {
        guard isExpandable(file) else { return }
        if expandedDirectoryIDs.contains(file.id) {
            collapseDirectory(file)
        } else {
            expandDirectory(file)
        }
    }

    /// Insert `file.id` into the expansion set and rebuild the visible
    /// rows. If the children have not been enumerated yet (or were
    /// dropped after a reload) an off-actor enumeration is dispatched.
    func expandDirectory(_ file: FileItem) {
        guard isExpandable(file) else { return }
        expandedDirectoryIDs.insert(file.id)
        if childrenByParentID[file.id] != nil {
            rebuildVisibleFiles()
            return
        }
        loadChildren(of: file)
    }

    /// Drop `file.id` from the expansion set and any descendant rows that
    /// are no longer visible. Selection / anchor pointing at hidden rows
    /// is cleared so subsequent arrow-key navigation has a valid anchor.
    func collapseDirectory(_ file: FileItem) {
        guard expandedDirectoryIDs.remove(file.id) != nil else { return }
        // Compute the set of ids that were visible *under* `file` before
        // the rebuild so we can prune selection.
        let removed = Self.collectDescendantIDs(
            of: file.id,
            childrenByParentID: childrenByParentID,
            expanded: expandedDirectoryIDs.union([file.id])
        )
        if !removed.isEmpty {
            selectedFileIDs.subtract(removed)
            if let anchor = selectionAnchor, removed.contains(anchor.id) {
                selectionAnchor = file
            }
        }
        rebuildVisibleFiles()
    }

    /// Off-actor enumeration of `file`'s direct children. Updates the
    /// children cache and rebuilds the visible rows when complete.
    private func loadChildren(of file: FileItem) {
        guard !loadingDirectoryIDs.contains(file.id) else { return }
        loadingDirectoryIDs.insert(file.id)
        let parentID = file.id
        let dirURL = file.url.standardizedFileURL
        let options: FileManager.DirectoryEnumerationOptions =
            showHiddenFiles ? [] : [.skipsHiddenFiles]
        Task.detached(priority: .userInitiated) {
            let items = Self.enumerate(url: dirURL, options: options) ?? []
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loadingDirectoryIDs.remove(parentID)
                self.childrenByParentID[parentID] = self.sortItems(items)
                self.rebuildVisibleFiles()
            }
        }
    }

    /// Refresh cached children for every directory the user has expanded
    /// (including nested ones). Called from `loadFiles()` so newly-created
    /// or deleted files surface without requiring a manual collapse.
    private func refreshExpandedChildren() {
        for id in expandedDirectoryIDs {
            // `FileItem.ID` is `url.absoluteString` — recover the URL.
            guard let url = URL(string: id) else { continue }
            let parentID = id
            let dirURL = url.standardizedFileURL
            let options: FileManager.DirectoryEnumerationOptions =
                showHiddenFiles ? [] : [.skipsHiddenFiles]
            Task.detached(priority: .userInitiated) {
                let items = Self.enumerate(url: dirURL, options: options) ?? []
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Only update if the directory is still expanded —
                    // user may have collapsed mid-flight.
                    guard self.expandedDirectoryIDs.contains(parentID) else { return }
                    self.childrenByParentID[parentID] = self.sortItems(items)
                    self.rebuildVisibleFiles()
                }
            }
        }
    }

    /// Walk the cached tree under `parentID` and return every descendant
    /// id that is currently flattened into the visible rows.
    private static func collectDescendantIDs(
        of parentID: FileItem.ID,
        childrenByParentID: [FileItem.ID: [FileItem]],
        expanded: Set<FileItem.ID>
    ) -> Set<FileItem.ID> {
        var out: Set<FileItem.ID> = []
        var stack: [FileItem.ID] = [parentID]
        while let id = stack.popLast() {
            guard let children = childrenByParentID[id] else { continue }
            for child in children {
                out.insert(child.id)
                if expanded.contains(child.id) {
                    stack.append(child.id)
                }
            }
        }
        return out
    }

    /// Recompute `files` (and `rowDepthByID`) from `allFiles`, the
    /// expansion set, and any cached children. In list view the rows
    /// are flattened depth-first; in icon / column view only the
    /// top-level filtered listing is exposed so tree state is
    /// transparent when the user is not in the list view.
    private func rebuildVisibleFiles() {
        var out: [FileItem] = []
        var depths: [FileItem.ID: Int] = [:]
        var seen: Set<FileItem.ID> = []
        let treeMode = (viewMode == .list)

        func walk(_ items: [FileItem], _ depth: Int) {
            let visible = applyFilter(to: items)
            out.reserveCapacity(out.count + visible.count)
            for item in visible {
                // Guard against the same id appearing twice in the flattened
                // listing — duplicates cause SwiftUI's diffable containers
                // (List / LazyVStack) to render only the first occurrence
                // while still reserving a layout slot for the second, which
                // shows up as a phantom empty row and breaks arrow-key
                // navigation through that position.
                guard seen.insert(item.id).inserted else {
                    if let l = lastDuplicateLog, l == item.id { continue }
                    lastDuplicateLog = item.id
                    print("[Seeker] dropped duplicate row id=\(item.id)")
                    continue
                }
                out.append(item)
                if depth > 0 { depths[item.id] = depth }
                if treeMode,
                   expandedDirectoryIDs.contains(item.id),
                   let children = childrenByParentID[item.id] {
                    walk(children, depth + 1)
                }
            }
        }
        walk(allFiles, 0)
        rowDepthByID = depths
        files = out
    }

    @ObservationIgnored private var lastDuplicateLog: FileItem.ID?

    /// Off-actor Trash enumeration via Finder AppleScript. Validates each
    /// returned path is a real file URL pointing at a still-existing item
    /// before constructing a `FileItem`. Returns an empty array on failure.
    ///
    /// Caches the last result keyed by `~/.Trash`'s `contentModificationDate`.
    /// `loadFiles()` is invoked on every cross-tab `.filesDidChange`
    /// notification, including ops on directories that have nothing to do
    /// with Trash; without this cache each one would spawn a Finder
    /// AppleScript round-trip (50\u2013500ms typical, can be seconds).
    private nonisolated static func loadTrashViaFinder() -> [FileItem] {
        let trashURL = FileManager.default
            .homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let mtime = (try? trashURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = TrashCache.shared.get(mtime: mtime) {
            return cached
        }

        let script = """
            tell application "Finder"
                set trashItems to items of trash
                set pathList to {}
                repeat with anItem in trashItems
                    set end of pathList to POSIX path of (anItem as alias)
                end repeat
                return pathList
            end tell
            """
        guard let appleScript = NSAppleScript(source: script) else { return [] }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil else {
            print("[Seeker] Failed to list trash via Finder: \(error!)")
            return []
        }

        let fm = FileManager.default
        let count = result.numberOfItems
        guard count > 0 else {
            TrashCache.shared.set([], mtime: mtime)
            return []
        }

        let keys = FileItem.prefetchKeys
        let keySet = Set(keys)
        var items: [FileItem] = []
        items.reserveCapacity(count)
        for i in 1...count {
            guard let pathDesc = result.atIndex(i),
                  let path = pathDesc.stringValue else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.isFileURL,
                  fm.fileExists(atPath: url.path) else { continue }
            let rv = (try? url.resourceValues(forKeys: keySet)) ?? URLResourceValues()
            items.append(FileItem(url: url, resourceValues: rv))
        }
        TrashCache.shared.set(items, mtime: mtime)
        return items
    }

    /// Re-sort the in-memory listing using the current `sortOrder` /
    /// `sortAscending` without re-enumerating the directory. Cheap O(n log n)
    /// in-memory work — safe to call on every sort-header click, unlike
    /// `loadFiles()` which would re-run `contentsOfDirectory` + per-file
    /// resource fetches.
    func resort() {
        allFiles = sortItems(allFiles)
        for (parentID, children) in childrenByParentID {
            childrenByParentID[parentID] = sortItems(children)
        }
        rebuildVisibleFiles()
    }

    func sortItems(_ items: [FileItem]) -> [FileItem] {
        let asc = sortAscending
        let order = sortOrder
        return items.sorted { a, b in
            // Directories first
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch order {
            case .name:
                let r = a.name.localizedStandardCompare(b.name)
                return asc ? r == .orderedAscending : r == .orderedDescending
            case .date:
                let dateA = a.modificationDate ?? Date.distantPast
                let dateB = b.modificationDate ?? Date.distantPast
                return asc ? dateA < dateB : dateA > dateB
            case .size:
                return asc ? a.fileSize < b.fileSize : a.fileSize > b.fileSize
            case .kind:
                let r = a.typeDescription.localizedStandardCompare(b.typeDescription)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        }
    }

    /// Enumerate `folder` synchronously using the same hidden-file and
    /// resource-key conventions as the main listing, then apply this view
    /// model's current sort. Used by context-menu actions (e.g. Auto
    /// Preview) so out-of-listing folders are ordered consistently with
    /// the visible pane.
    func sortedChildren(of folder: URL) -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions =
            showHiddenFiles ? [] : [.skipsHiddenFiles]
        let items = Self.enumerate(url: folder.standardizedFileURL, options: options) ?? []
        return sortItems(items)
    }

    func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        currentURL = pathHistory[historyIndex]
        loadFiles()
    }

    func goForward() {
        guard historyIndex < pathHistory.count - 1 else { return }
        historyIndex += 1
        currentURL = pathHistory[historyIndex]
        loadFiles()
    }

    func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        navigateTo(parent)
    }

    func openItem(_ item: FileItem) {
        // Packages (.app, .bundle, etc.) should be opened by the system, not navigated into
        if item.isPackage {
            NSWorkspace.shared.open(item.url)
            return
        }
        // Resolve symlinks to get the real path for directory check
        let resolvedURL = item.url.resolvingSymlinksInPath()
        let isDir = item.isDirectory || {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }()
        if isDir {
            navigateTo(item.url)
        } else if canDecompress(item) {
            decompressAndOpen(item)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < pathHistory.count - 1 }
    var canGoUp: Bool { currentURL.path != "/" }

    var tabTitle: String {
        currentURL.lastPathComponent.isEmpty ? "/" : currentURL.lastPathComponent
    }

    var pathComponents: [(String, URL)] {
        if let cached = _cachedPathComponents { return cached }
        var components: [(String, URL)] = []
        var url = currentURL
        while url.path != "/" {
            components.append((url.lastPathComponent, url))
            url = url.deletingLastPathComponent()
        }
        components.append(("/", URL(fileURLWithPath: "/")))
        components.reverse()
        _cachedPathComponents = components
        return components
    }
    private var _cachedPathComponents: [(String, URL)]?

    // MARK: - File Operations

    func createNewFolder() {
        let baseName = "untitled folder"
        var name = baseName
        var counter = 1
        let fm = FileManager.default

        while fm.fileExists(atPath: currentURL.appendingPathComponent(name).path) {
            counter += 1
            name = "\(baseName) \(counter)"
        }

        let newURL = currentURL.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: newURL, withIntermediateDirectories: false)
            undoStack.append(.create(url: newURL))
            // Select and open the rename editor once the async loadFiles()
            // returns and the new folder is actually in `files`. Setting
            // selection/renamingFile synchronously here races the reload
            // and leaves the row without focus.
            pendingSelectionURL = newURL
            pendingRenameOnSelect = true
            loadFiles()
            notifyFilesChanged()
        } catch {
            showFileError("Could not create folder: \(error.localizedDescription)")
        }
    }

    func createNewFile() {
        let baseName = "untitled"
        let ext = "txt"
        var name = "\(baseName).\(ext)"
        var counter = 1
        let fm = FileManager.default

        while fm.fileExists(atPath: currentURL.appendingPathComponent(name).path) {
            counter += 1
            name = "\(baseName) \(counter).\(ext)"
        }

        let newURL = currentURL.appendingPathComponent(name)
        do {
            try Data().write(to: newURL)
            undoStack.append(.create(url: newURL))
            pendingSelectionURL = newURL
            pendingRenameOnSelect = true
            loadFiles()
            notifyFilesChanged()
        } catch {
            showFileError("Could not create file: \(error.localizedDescription)")
        }
    }

    func beginRename(_ item: FileItem) {
        renamingFile = item
        renameText = item.name
    }

    func commitRename() {
        guard let item = renamingFile, !renameText.isEmpty, renameText != item.name else {
            renamingFile = nil
            return
        }

        // Reject names that would escape the current directory or contain
        // path separators / NUL. Prevents accidental path traversal via rename.
        if renameText == "." || renameText == ".."
            || renameText.contains("/")
            || renameText.contains("\0") {
            showFileError("Invalid file name.")
            renamingFile = nil
            return
        }

        let parent = item.url.deletingLastPathComponent()
        let newURL = parent.appendingPathComponent(renameText)

        // Ensure the resolved path stays inside the parent directory.
        let parentPath = parent.standardizedFileURL.path
        let newParentPath = newURL.standardizedFileURL.deletingLastPathComponent().path
        guard newParentPath == parentPath else {
            showFileError("Invalid file name.")
            renamingFile = nil
            return
        }

        // Refuse to silently overwrite an existing file.
        if FileManager.default.fileExists(atPath: newURL.path) {
            showFileError("A file named '\(renameText)' already exists.")
            renamingFile = nil
            return
        }

        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
            undoStack.append(.rename(oldURL: item.url, newURL: newURL))
            renamingFile = nil
            loadFiles()
            notifyFilesChanged()
            let renamed = FileItem(url: newURL)
            selectionAnchor = renamed
            selectedFileIDs = [renamed.id]
        } catch {
            showFileError("Could not rename: \(error.localizedDescription)")
            renamingFile = nil
        }
    }

    func cancelRename() {
        renamingFile = nil
        renameText = ""
    }

    func copySelected() {
        let urls = effectiveSelection.map(\.url)
        guard !urls.isEmpty else { return }
        Self.clipboard = urls
        Self.clipboardIsCut = false

        // Also put on system pasteboard
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    func cutSelected() {
        let urls = effectiveSelection.map(\.url)
        guard !urls.isEmpty else { return }
        Self.clipboard = urls
        Self.clipboardIsCut = true

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    func paste() {
        pasteFiles(forceMove: false)
    }

    /// Paste as move (Cmd+Option+V Finder-style)
    func pasteMoving() {
        pasteFiles(forceMove: true)
    }

    private func pasteFiles(forceMove: Bool) {
        let urls: [URL]
        if !Self.clipboard.isEmpty {
            urls = Self.clipboard
        } else {
            // Try system pasteboard
            guard let pbURLs = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL],
                  !pbURLs.isEmpty else { return }
            urls = pbURLs
        }

        let shouldMove = forceMove || Self.clipboardIsCut
        let dest = currentURL

        if shouldMove {
            Self.clipboard = []
            Self.clipboardIsCut = false
            FileOperationManager.shared.startMove(sources: urls, to: dest) { [weak self] op in
                self?.loadFiles()
                self?.notifyDirectoriesChanged(sourceURLs: urls)
                if !op.completedDestinations.isEmpty {
                    let originals = Array(op.sourceURLs.prefix(op.completedDestinations.count))
                    self?.undoStack.append(.move(originalURLs: originals, destinationURLs: op.completedDestinations))
                }
            }
        } else {
            FileOperationManager.shared.startCopy(sources: urls, to: dest) { [weak self] op in
                self?.loadFiles()
                self?.notifyFilesChanged()
                if !op.completedDestinations.isEmpty {
                    self?.undoStack.append(.copy(destinationURLs: op.completedDestinations))
                }
            }
        }
    }

    func trashSelected() {
        let items = effectiveSelection
        guard !items.isEmpty else { return }

        // Determine which file should be selected after deletion: prefer the
        // next surviving sibling (after the last trashed item), otherwise the
        // previous surviving sibling (before the first trashed item).
        let trashedIDs = Set(items.map(\.id))
        let nextNeighborURL: URL? = {
            guard let lastIdx = files.lastIndex(where: { trashedIDs.contains($0.id) }) else {
                return nil
            }
            if let next = files[(lastIdx + 1)...].first(where: { !trashedIDs.contains($0.id) }) {
                return next.url
            }
            guard let firstIdx = files.firstIndex(where: { trashedIDs.contains($0.id) }) else {
                return nil
            }
            if let prev = files[..<firstIdx].last(where: { !trashedIDs.contains($0.id) }) {
                return prev.url
            }
            return nil
        }()

        var originalURLs: [URL] = []
        var trashURLs: [URL] = []
        for item in items {
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingURL)
                originalURLs.append(item.url)
                if let trashURL = resultingURL as URL? {
                    trashURLs.append(trashURL)
                }
            } catch {
                showFileError("Could not move to Trash: \(error.localizedDescription)")
                return
            }
        }
        if !originalURLs.isEmpty && originalURLs.count == trashURLs.count {
            undoStack.append(.trash(originalURLs: originalURLs, trashURLs: trashURLs))
        }
        selectionAnchor = nil
        selectedFileIDs = []
        if let neighbor = nextNeighborURL {
            pendingSelectionURL = neighbor
        }
        loadFiles()
        notifyFilesChanged()
    }

    /// Permanently deletes the effective selection, bypassing the Trash.
    /// This cannot be undone, so it always asks for confirmation first.
    func deleteSelectedPermanently() {
        let items = effectiveSelection
        guard !items.isEmpty else { return }

        let alert = NSAlert()
        if items.count == 1 {
            alert.messageText = "Permanently delete \u{201C}\(items[0].name)\u{201D}?"
        } else {
            alert.messageText = "Permanently delete \(items.count) items?"
        }
        alert.informativeText = "\(items.count == 1 ? "This item" : "These items") will be deleted immediately. You can't undo this action."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Pick the file to select afterwards (same logic as trashSelected).
        let deletedIDs = Set(items.map(\.id))
        let nextNeighborURL: URL? = {
            guard let lastIdx = files.lastIndex(where: { deletedIDs.contains($0.id) }) else { return nil }
            if let next = files[(lastIdx + 1)...].first(where: { !deletedIDs.contains($0.id) }) {
                return next.url
            }
            guard let firstIdx = files.firstIndex(where: { deletedIDs.contains($0.id) }) else { return nil }
            if let prev = files[..<firstIdx].last(where: { !deletedIDs.contains($0.id) }) {
                return prev.url
            }
            return nil
        }()

        let fm = FileManager.default
        for item in items {
            do {
                try fm.removeItem(at: item.url)
            } catch {
                showFileError("Could not delete: \(error.localizedDescription)")
                break
            }
        }
        selectionAnchor = nil
        selectedFileIDs = []
        if let neighbor = nextNeighborURL {
            pendingSelectionURL = neighbor
        }
        loadFiles()
        notifyFilesChanged()
    }

    func moveSelectedTo(destination: URL) {
        let items = effectiveSelection
        guard !items.isEmpty else { return }
        let sources = items.map(\.url)
        FileOperationManager.shared.startMove(sources: sources, to: destination) { [weak self] op in
            self?.loadFiles()
            self?.notifyDirectoriesChanged(sourceURLs: sources)
            if !op.completedDestinations.isEmpty {
                let originals = Array(op.sourceURLs.prefix(op.completedDestinations.count))
                self?.undoStack.append(.move(originalURLs: originals, destinationURLs: op.completedDestinations))
            }
        }
    }

    // MARK: - Undo

    func undo() {
        guard let action = undoStack.popLast() else { return }
        let fm = FileManager.default
        switch action {
        case .trash(let originalURLs, let trashURLs):
            for (original, trashURL) in zip(originalURLs, trashURLs) {
                do {
                    try fm.moveItem(at: trashURL, to: original)
                } catch {
                    showFileError("Undo failed: \(error.localizedDescription)")
                }
            }
        case .create(let url):
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } catch {
                showFileError("Undo failed: \(error.localizedDescription)")
            }
        case .rename(let oldURL, let newURL):
            do {
                try fm.moveItem(at: newURL, to: oldURL)
            } catch {
                showFileError("Undo failed: \(error.localizedDescription)")
            }
        case .copy(let destinationURLs):
            for dest in destinationURLs {
                do {
                    try fm.trashItem(at: dest, resultingItemURL: nil)
                } catch {
                    showFileError("Undo failed: \(error.localizedDescription)")
                }
            }
        case .move(let originalURLs, let destinationURLs):
            for (original, dest) in zip(originalURLs, destinationURLs) {
                do {
                    try fm.moveItem(at: dest, to: original)
                } catch {
                    showFileError("Undo failed: \(error.localizedDescription)")
                }
            }
        }
        loadFiles()
        notifyFilesChanged()
    }

    // MARK: - Multi-Selection

    func selectAll() {
        guard !files.isEmpty else { return }
        selectedFileIDs = Set(files.map(\.id))
        selectionAnchor = files.first
    }

    func handleFileClick(_ file: FileItem, command: Bool, shift: Bool) {
        if shift, let anchor = selectionAnchor ?? selectedFile {
            // Shift-click: range select from anchor to clicked file.
            // O(1) via the maintained `fileIndex` map; the previous
            // `firstIndex(of:)` calls were O(n) and combined with
            // FileItem's old synthesized hashing this dominated
            // shift-click latency on large directories.
            guard let anchorIndex = fileIndex[anchor.id],
                  let clickIndex = fileIndex[file.id] else {
                selectionAnchor = file
                selectedFileIDs = [file.id]
                return
            }
            let range = min(anchorIndex, clickIndex)...max(anchorIndex, clickIndex)
            selectedFileIDs = Set(files[range].map(\.id))
            // Keep anchor for next shift-click
        } else if command {
            // Cmd-click: toggle individual file in selection
            if selectedFileIDs.isEmpty, let current = selectedFile {
                selectedFileIDs = [current.id]
            }
            if selectedFileIDs.contains(file.id) {
                selectedFileIDs.remove(file.id)
                // Pick any remaining selected item as the new anchor.
                // Walk the selection set (typically small) instead of
                // scanning `files` (potentially huge).
                if let nextID = selectedFileIDs.first,
                   let i = fileIndex[nextID] {
                    selectionAnchor = files[i]
                } else {
                    selectionAnchor = nil
                }
            } else {
                selectedFileIDs.insert(file.id)
                selectionAnchor = file
            }
        } else {
            // Plain click: single select
            selectionAnchor = file
            selectedFileIDs = [file.id]
        }
    }

    // MARK: - Helpers

    var effectiveSelection: [FileItem] {
        if !selectedFileIDs.isEmpty {
            return Array(selectedFiles)
        } else if let single = selectedFile {
            return [single]
        }
        return []
    }

    /// True when at least one file is selected (multi-selection set is
    /// non-empty, or there's a single focused selection). Toolbar
    /// predicates read this every body invocation, so it avoids the
    /// `effectiveSelection` array allocation.
    var hasSelection: Bool {
        !selectedFileIDs.isEmpty || selectedFile != nil
    }

    /// O(1) for the selection-empty case, otherwise scans the cached
    /// `selectedFiles` set. Toolbar predicates read this every body
    /// invocation so it intentionally avoids the `Array(selectedFiles)`
    /// allocation that `effectiveSelection` does.
    var hasEditableImageSelection: Bool {
        if !selectedFileIDs.isEmpty {
            return selectedFiles.contains(where: \.isEditableImage)
        }
        return selectedFile?.isEditableImage ?? false
    }

    /// True if any item in the effective selection is either an editable
    /// image or an audio/video file with a writable tag format.
    var hasEditableMetadataSelection: Bool {
        if !selectedFileIDs.isEmpty {
            return selectedFiles.contains(where: \.isEditableMetadata)
        }
        return selectedFile?.isEditableMetadata ?? false
    }

    var canPaste: Bool {
        !Self.clipboard.isEmpty ||
        NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] != nil
    }

    private func uniqueDestination(for source: URL, in directory: URL, suffix: String = "") -> URL {
        let fm = FileManager.default
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension

        var candidate: URL
        if ext.isEmpty {
            candidate = directory.appendingPathComponent(name + suffix)
        } else {
            candidate = directory.appendingPathComponent(name + suffix + "." + ext)
        }

        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            counter += 1
            let numberedName = ext.isEmpty
                ? "\(name)\(suffix) \(counter)"
                : "\(name)\(suffix) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numberedName)
        }
        return candidate
    }

    // MARK: - Compress / Decompress

    private nonisolated static func runDitto(arguments: [String]) -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        process.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, errMsg)
    }

    func dumpNCMFiles(_ files: [FileItem]) {
        let ncmFiles = files.filter(\.isNCMFile)
        guard !ncmFiles.isEmpty else { return }
        let urls = ncmFiles.map(\.url)
        Task.detached(priority: .userInitiated) {
            let errors = await Self.runNCMDumps(urls: urls)
            await MainActor.run { [weak self] in
                self?.loadFiles()
                self?.notifyFilesChanged()
                if !errors.isEmpty {
                    self?.showFileError("NCM dump failed:\n\(errors.joined(separator: "\n"))")
                }
            }
        }
    }

    func dumpNCMFilesInFolder(_ folder: FileItem) {
        guard folder.isDirectory else { return }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: folder.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            var urls: [URL] = []
            while let next = enumerator.nextObject() {
                if let fileURL = next as? URL,
                   fileURL.pathExtension.lowercased() == "ncm" {
                    urls.append(fileURL)
                }
            }
            let total = urls.count
            let errors = await Self.runNCMDumps(urls: urls)
            let okCount = total - errors.count
            await MainActor.run { [weak self] in
                self?.loadFiles()
                self?.notifyFilesChanged()
                if !errors.isEmpty {
                    self?.showFileError("NCM dump failed (\(okCount) ok, \(errors.count) failed):\n\(errors.joined(separator: "\n"))")
                }
            }
        }
    }

    /// Run NCM dumps in parallel, bounded by the active CPU count. Each dump
    /// is CPU-bound (RC4-like keystream + AES key unwrap) and trivially
    /// parallelizable across files.
    private nonisolated static func runNCMDumps(urls: [URL]) async -> [String] {
        guard !urls.isEmpty else { return [] }
        let concurrency = max(2, min(urls.count, ProcessInfo.processInfo.activeProcessorCount))
        return await withTaskGroup(of: String?.self) { group in
            var iter = urls.makeIterator()
            // Prime the pool.
            for _ in 0..<concurrency {
                guard let url = iter.next() else { break }
                group.addTask { Self.dumpOne(url) }
            }
            var errors: [String] = []
            // As each task completes, enqueue the next.
            for await result in group {
                if let err = result { errors.append(err) }
                if let url = iter.next() {
                    group.addTask { Self.dumpOne(url) }
                }
            }
            return errors
        }
    }

    private nonisolated static func dumpOne(_ url: URL) -> String? {
        do {
            var crypt = try NCMCrypt(path: url.path)
            try crypt.dump(outputDir: url.deletingLastPathComponent().path)
            crypt.fixMetadata()
            return nil
        } catch {
            return "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func compressSelected() {
        let items = effectiveSelection
        guard !items.isEmpty else { return }
        let urls = items.map(\.url)
        let dir = currentURL

        let archiveName: String
        if urls.count == 1 {
            archiveName = urls[0].deletingPathExtension().lastPathComponent + ".zip"
        } else {
            archiveName = "Archive.zip"
        }

        let dest = uniqueDestination(for: dir.appendingPathComponent(archiveName), in: dir)

        var tmpDir: URL?
        let args: [String]
        do {
            if urls.count > 1 {
                let fm = FileManager.default
                let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                tmpDir = tmp
                for url in urls {
                    try fm.copyItem(at: url, to: tmp.appendingPathComponent(url.lastPathComponent))
                }
                args = ["-c", "-k", "--sequesterRsrc", tmp.path, dest.path]
            } else {
                args = ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, dest.path]
            }
        } catch {
            showFileError("Compression failed: \(error.localizedDescription)")
            return
        }

        let cleanupDir = tmpDir
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runDitto(arguments: args)
            if let cleanupDir { try? FileManager.default.removeItem(at: cleanupDir) }
            DispatchQueue.main.async { [weak self] in
                if result.status != 0 {
                    self?.showFileError("Compression failed: \(result.error)")
                }
                self?.loadFiles()
                self?.notifyFilesChanged()
            }
        }
    }

    func decompressFile(_ file: FileItem) {
        let sourcePath = file.url.path
        let folderName = file.url.deletingPathExtension().lastPathComponent
        let extractDir = uniqueDestination(
            for: currentURL.appendingPathComponent(folderName),
            in: currentURL
        )

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showFileError("Decompression failed: \(error.localizedDescription)")
                }
                return
            }
            let result = Self.runDitto(arguments: ["-x", "-k", sourcePath, extractDir.path])
            DispatchQueue.main.async { [weak self] in
                if result.status != 0 {
                    self?.showFileError("Decompression failed: \(result.error)")
                }
                self?.loadFiles()
                self?.notifyFilesChanged()
            }
        }
    }

    private func decompressAndOpen(_ file: FileItem) {
        let sourcePath = file.url.path
        let folderName = file.url.deletingPathExtension().lastPathComponent
        let extractDir = uniqueDestination(
            for: currentURL.appendingPathComponent(folderName),
            in: currentURL
        )

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showFileError("Decompression failed: \(error.localizedDescription)")
                }
                return
            }
            let result = Self.runDitto(arguments: ["-x", "-k", sourcePath, extractDir.path])
            DispatchQueue.main.async { [weak self] in
                if result.status != 0 {
                    self?.showFileError("Decompression failed: \(result.error)")
                } else {
                    self?.navigateTo(extractDir)
                }
                self?.loadFiles()
                self?.notifyFilesChanged()
            }
        }
    }

    private static let decompressableExtensions: Set<String> = ["zip", "cpgz", "cpio"]

    func canDecompress(_ file: FileItem) -> Bool {
        !file.isDirectory && Self.decompressableExtensions.contains(file.url.pathExtension.lowercased())
    }

    private func showFileError(_ message: String) {
        errorMessage = message
        showError = true
    }

    private func notifyFilesChanged() {
        // The affected directory's contents just changed; drop any cached
        // shallow scans so context-menu predicates (e.g. containsNCMFiles)
        // re-fetch on next access. Bounded by `NSCache` either way.
        FileItemCache.containsNCMByPath.removeObject(forKey: currentURL.path as NSString)
        NotificationCenter.default.post(
            name: .filesDidChange,
            object: self,
            userInfo: [Self.affectedDirKey: currentURL]
        )
    }

    /// Broadcast a `.filesDidChange` for each unique parent directory of
    /// `urls` plus `currentURL`. Used by operations whose source and
    /// destination directories differ (e.g. cross-pane Move / Cut+Paste)
    /// so the *source* pane refreshes too — `.filesDidChange` listeners
    /// are scoped per affected dir and would otherwise ignore a
    /// notification posted only against the destination.
    private func notifyDirectoriesChanged(sourceURLs: [URL]) {
        var dirs: Set<URL> = [currentURL.standardizedFileURL]
        for url in sourceURLs {
            dirs.insert(url.deletingLastPathComponent().standardizedFileURL)
        }
        for dir in dirs {
            FileItemCache.containsNCMByPath.removeObject(forKey: dir.path as NSString)
            NotificationCenter.default.post(
                name: .filesDidChange,
                object: self,
                userInfo: [Self.affectedDirKey: dir]
            )
        }
    }

    /// Key used in `.filesDidChange` userInfo to scope reloads to tabs that
    /// are actually viewing the affected directory. Subscribers without
    /// this key (e.g. legacy posters) trigger a reload as before.
    nonisolated static let affectedDirKey = "affectedDir"
}

final class UncheckedSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Process-wide cache of the Trash listing, keyed by the directory's
/// `contentModificationDate`. Lock-protected so the nonisolated AppleScript
/// fallback can read/write it from any actor context.
final class TrashCache: @unchecked Sendable {
    static let shared = TrashCache()
    private let lock = NSLock()
    private var items: [FileItem] = []
    private var cachedMTime: Date?
    private var fetchedAt: Date = .distantPast
    /// Even if the directory mtime hasn't moved, refresh after this long.
    /// Guards against rare cases where Finder recategorises items without
    /// touching the directory's mtime (e.g. icon position writes).
    private let maxAge: TimeInterval = 30

    func get(mtime: Date?) -> [FileItem]? {
        lock.lock(); defer { lock.unlock() }
        guard cachedMTime == mtime else { return nil }
        guard Date().timeIntervalSince(fetchedAt) < maxAge else { return nil }
        return items
    }

    func set(_ items: [FileItem], mtime: Date?) {
        lock.lock(); defer { lock.unlock() }
        self.items = items
        self.cachedMTime = mtime
        self.fetchedAt = Date()
    }
}
