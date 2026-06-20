import Foundation
import Observation
import AppKit

@MainActor @Observable
class AppState {
    // Panel visibility
    var showFavorites: Bool = SettingsManager.shared.showFavorites {
        didSet { SettingsManager.shared.showFavorites = showFavorites }
    }
    var showDualPane: Bool = SettingsManager.shared.showDualPane {
        didSet {
            SettingsManager.shared.showDualPane = showDualPane
            // The right pane is hidden in single-pane mode. If the user
            // collapses to single-pane while `.right` is active, every
            // subsequent navigation (sidebar favorite click, Go To Folder,
            // etc.) would silently target the hidden right pane. Force
            // focus back to the only visible pane.
            if !showDualPane && activePane == .right {
                activePane = .left
            }
        }
    }
    var showInfoPanel: Bool = SettingsManager.shared.showInfoPanel {
        didSet { SettingsManager.shared.showInfoPanel = showInfoPanel }
    }
    /// Monotonically incremented whenever the user invokes the
    /// "Go to Folder…" command. The active `PaneView` observes this token
    /// and switches its path bar into the inline text-editing mode —
    /// matching the behavior of clicking the pencil icon in the toolbar.
    var pathEditRequestID: Int = 0

    /// Requests that the currently active pane enter inline path-editing
    /// mode. No popup; the breadcrumb is replaced by a text field.
    func requestEditPath() {
        pathEditRequestID &+= 1
    }

    /// Non-nil when the Metadata Editor sheet is open. Holds the URLs of
    /// the image(s) being edited.
    var metadataEditorTargets: [URL]?

    /// Non-nil when the audio/video tag editor sheet is open. Holds the
    /// URLs of the media file(s) being edited.
    var mediaMetadataEditorTargets: [URL]?

    /// Non-nil when the Batch Rename sheet is open. Holds the URLs of the
    /// files being renamed.
    var batchRenameTargets: [URL]?

    /// Opens the Batch Rename sheet for the active pane's selection (or
    /// all files in the current directory if nothing is selected).
    func openBatchRename() {
        let active = activeExplorer
        let selected = active.effectiveSelection.map(\.url)
        let targets = selected.isEmpty ? active.files.map(\.url) : selected
        guard !targets.isEmpty else { NSSound.beep(); return }
        batchRenameTargets = targets
    }

    /// Non-nil when the recursive Search window should open. Holds the
    /// directory to search under.
    var fileSearchRoot: URL?

    /// Opens the recursive search window rooted at the active pane's
    /// current directory (or a single selected sub-folder if there is one).
    func openSearch() {
        let active = activeExplorer
        if let dir = active.effectiveSelection.first(where: { $0.isDirectory })?.url {
            fileSearchRoot = dir
        } else {
            fileSearchRoot = active.currentURL
        }
    }

    /// Non-nil when the Find Duplicates sheet is open. Holds the root
    /// directories under which the duplicate scan should run. Multiple
    /// roots are scanned as one pool, so duplicates spanning separate
    /// folders or volumes (e.g. two external USB disks) are found.
    var duplicateFinderRoots: [URL]?

    /// Opens the duplicate finder rooted at the active pane's current
    /// directory. If the user has selected one or more directories, the
    /// scan is rooted at those directories instead — selecting multiple
    /// folders scans them together as a single candidate pool.
    func openDuplicateFinder() {
        let active = activeExplorer
        let selectedDirs = active.effectiveSelection
            .filter { $0.isDirectory }
            .map(\.url)
        duplicateFinderRoots = selectedDirs.isEmpty ? [active.currentURL] : selectedDirs
    }

    /// Opens the duplicate finder across both panes, scanning their
    /// directories as a single pool. For each pane, a selected sub-folder
    /// (if any) takes precedence over the pane's current directory — so
    /// you can pick a folder on each side and de-duplicate just those.
    /// The active pane is listed first so its copies are kept by default
    /// (keep-priority follows root order). Ideal for de-duplicating two
    /// mounted volumes side by side.
    func openDuplicateFinderAcrossPanes() {
        guard showDualPane else { openDuplicateFinder(); return }
        let first = activeExplorer.effectiveSelection.first { $0.isDirectory }?.url
            ?? activeExplorer.currentURL
        let second = inactiveExplorer.effectiveSelection.first { $0.isDirectory }?.url
            ?? inactiveExplorer.currentURL
        // Collapse to a single root if both panes point at the same place.
        duplicateFinderRoots = first.standardizedFileURL == second.standardizedFileURL
            ? [first]
            : [first, second]
    }

    /// Non-nil when the Compare Folders window should open. Holds exactly
    /// two directories: A (first) and B (second).
    var directoryCompareTargets: [URL]?

    /// Non-nil when the Sync Folders window should open. Holds exactly two
    /// directories: A (first) and B (second).
    var folderSyncRoots: [URL]?

    /// Resolves the (A, B) directory pair from the current selection /
    /// panes, in priority order:
    ///   1. One selected sub-folder in each pane (left = A, right = B).
    ///   2. Two selected sub-folders in the active pane.
    ///   3. A single selected sub-folder in the active pane vs. the
    ///      inactive pane's current directory.
    ///   4. The active pane's directory as A and the inactive pane's as B.
    /// Returns nil if it can't resolve two distinct directories.
    func resolveDirectoryPair() -> (URL, URL)? {
        let activeSel = activeExplorer.effectiveSelection
            .filter { $0.isDirectory }.map(\.url)
        let inactiveSel = inactiveExplorer.effectiveSelection
            .filter { $0.isDirectory }.map(\.url)

        let pair: (URL, URL)?
        if let first = activeSel.first, let second = inactiveSel.first {
            let leftURL = activePane == .left ? first : second
            let rightURL = activePane == .left ? second : first
            pair = (leftURL, rightURL)
        } else if activeSel.count >= 2 {
            pair = (activeSel[0], activeSel[1])
        } else if let only = activeSel.first, showDualPane {
            pair = (only, inactiveExplorer.currentURL)
        } else if showDualPane {
            pair = (activeExplorer.currentURL, inactiveExplorer.currentURL)
        } else {
            pair = nil
        }
        guard let (a, b) = pair, a.standardizedFileURL != b.standardizedFileURL else { return nil }
        return (a, b)
    }

    /// Opens the folder-compare window for the resolved directory pair.
    func openDirectoryCompare() {
        guard let (a, b) = resolveDirectoryPair() else { NSSound.beep(); return }
        directoryCompareTargets = [a, b]
    }

    /// Opens the folder-sync window for the resolved directory pair.
    func openFolderSync() {
        guard let (a, b) = resolveDirectoryPair() else { NSSound.beep(); return }
        folderSyncRoots = [a, b]
    }

    /// True when `resolveDirectoryPair()` can produce a pair (drives the
    /// Compare / Sync toolbar buttons' enabled state).
    var canCompareDirectories: Bool {
        resolveDirectoryPair() != nil
    }

    /// Opens the appropriate Metadata Editor for the active pane's effective
    /// selection: image EXIF editor for images, audio/video tag editor for
    /// media files. If the selection contains both, images win (matches the
    /// prior behavior where this command was image-only). No-op when nothing
    /// editable is selected.
    func openMetadataEditor() {
        let selection = activeExplorer.effectiveSelection
        let imageURLs = selection.filter(\.isEditableImage).map(\.url)
        if !imageURLs.isEmpty {
            metadataEditorTargets = imageURLs
            return
        }
        let mediaURLs = selection.filter(\.isReadableMedia).map(\.url)
        if !mediaURLs.isEmpty {
            mediaMetadataEditorTargets = mediaURLs
            return
        }
        NSSound.beep()
    }

    /// Strips GPS + body serial number + user comment from the current
    /// effective image selection, in place. Reloads the active pane.
    func stripPrivacyMetadata() {
        let urls = activeExplorer.effectiveSelection
            .filter(\.isEditableImage)
            .map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }

        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Remove location and personal info from this image?"
            : "Remove location and personal info from \(urls.count) images?"
        alert.informativeText = "GPS coordinates, the camera body serial number, and any user comment will be deleted from the file. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Strip")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let active = activeExplorer
        Task.detached(priority: .userInitiated) {
            for url in urls {
                try? ExifEditor.stripPrivacyFields(at: url)
            }
            await MainActor.run { active.loadFiles() }
        }
    }

    // Panes - each has tabs
    var leftPane = PaneState()
    var rightPane = PaneState()

    // Which pane is active
    var activePane: PaneSide = .left

    // Pane screen frames for click detection.
    // Read only from the global mouse-down monitor in AppDelegate; never
    // observed from any view body. Marked @ObservationIgnored so the
    // continuous writes during HSplitView drags don't invalidate views.
    @ObservationIgnored var leftPaneFrame: CGRect = .zero
    @ObservationIgnored var rightPaneFrame: CGRect = .zero

    enum PaneSide {
        case left, right
    }

    var activePaneState: PaneState {
        activePane == .left ? leftPane : rightPane
    }

    var inactivePaneState: PaneState {
        activePane == .left ? rightPane : leftPane
    }

    var activeExplorer: FileExplorerViewModel {
        activePaneState.activeTab
    }

    var inactiveExplorer: FileExplorerViewModel {
        inactivePaneState.activeTab
    }

    func navigateActivePane(to url: URL) {
        activeExplorer.navigateTo(url)
    }

    /// Swap the contents of the left and right panes. Each pane keeps its
    /// own tabs/history/view-mode — we just exchange which `PaneState`
    /// lives on which side. The active side (left/right) is preserved, so
    /// the user's focus follows the pane that moved, matching the typical
    /// ForkLift / Total Commander "Switch Panels" behavior.
    func swapPanes() {
        guard showDualPane else { NSSound.beep(); return }
        let temp = leftPane
        leftPane = rightPane
        rightPane = temp
    }

    // Copy/move selected files to inactive pane's directory
    func copyToOtherPane() {
        let items = activeExplorer.effectiveSelection
        guard !items.isEmpty else { return }
        let dest = inactiveExplorer.currentURL
        let sources = items.map(\.url)
        let inactive = inactiveExplorer
        let active = activeExplorer
        FileOperationManager.shared.startCopy(sources: sources, to: dest) { op in
            inactive.loadFiles()
            if !op.completedDestinations.isEmpty {
                active.undoStack.append(.copy(destinationURLs: op.completedDestinations))
            }
        }
    }

    func moveToOtherPane() {
        let items = activeExplorer.effectiveSelection
        guard !items.isEmpty else { return }
        let dest = inactiveExplorer.currentURL
        let sources = items.map(\.url)
        let active = activeExplorer
        let inactive = inactiveExplorer
        FileOperationManager.shared.startMove(sources: sources, to: dest) { op in
            active.loadFiles()
            inactive.loadFiles()
            if !op.completedDestinations.isEmpty {
                let originals = Array(op.sourceURLs.prefix(op.completedDestinations.count))
                active.undoStack.append(.move(originalURLs: originals, destinationURLs: op.completedDestinations))
            }
        }
    }

    private func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let fm = FileManager.default
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            counter += 1
            let numberedName = ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numberedName)
        }
        return candidate
    }

    // MARK: - Location Persistence

    func restoreLastLocations() {
        let settings = SettingsManager.shared
        if let leftURL = settings.savedLeftURL() {
            leftPane.activeTab.navigateTo(leftURL)
        }
        if let rightURL = settings.savedRightURL() {
            rightPane.activeTab.navigateTo(rightURL)
        }
        if settings.rememberLastLocation {
            if let raw = settings.lastLeftPaneViewMode,
               let mode = FileExplorerViewModel.ViewMode(rawValue: raw) {
                leftPane.activeTab.viewMode = mode
            }
            if let raw = settings.lastRightPaneViewMode,
               let mode = FileExplorerViewModel.ViewMode(rawValue: raw) {
                rightPane.activeTab.viewMode = mode
            }
        }
    }

    func saveCurrentLocations() {
        let settings = SettingsManager.shared
        guard settings.rememberLastLocation else { return }
        settings.saveLocations(
            left: leftPane.activeTab.currentURL,
            right: rightPane.activeTab.currentURL,
            leftViewMode: leftPane.activeTab.viewMode.rawValue,
            rightViewMode: rightPane.activeTab.viewMode.rawValue
        )
    }

    // MARK: - URL Scheme Handling

    /// Handle an incoming `seeker://` URL.
    ///
    /// Supported forms:
    /// - `seeker://reveal?path=<URL-encoded absolute path>` — navigates the
    ///   active pane to the parent directory and selects the target item.
    /// - `seeker://open?path=<URL-encoded absolute path>` — navigates the
    ///   active pane into the target directory (or its parent if a file).
    /// - `seeker://<absolute path>` / `seeker:///absolute/path` — short form
    ///   equivalent to `reveal`.
    ///
    /// The target path may also be supplied via the URL's `path` component
    /// instead of the `path` query item (e.g. `seeker://reveal/Users/me/foo`).
    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "seeker" else { return }

        // Extract target absolute path. Prefer ?path= query item; fall back
        // to the URL's own path component.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryPath = components?
            .queryItems?
            .first(where: { $0.name == "path" })?
            .value
        let rawPath: String? = {
            if let q = queryPath, !q.isEmpty { return q }
            let p = url.path
            return p.isEmpty ? nil : p
        }()

        guard let pathString = rawPath, !pathString.isEmpty else {
            NSSound.beep()
            return
        }
        // Expand `~` so callers can pass `seeker://reveal?path=~/Desktop/foo`.
        let expanded = (pathString as NSString).expandingTildeInPath
        let target = URL(fileURLWithPath: expanded).standardizedFileURL

        // Bring the app forward so the action is visible.
        NSApplication.shared.activate(ignoringOtherApps: true)

        let action = (url.host ?? "reveal").lowercased()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: target.path, isDirectory: &isDir)

        switch action {
        case "open":
            if exists && isDir.boolValue {
                activeExplorer.navigateTo(target)
            } else if exists {
                // File — fall through to reveal behavior.
                activeExplorer.revealAndSelect(target)
            } else {
                NSSound.beep()
            }
        case "reveal", "":
            if exists {
                if isDir.boolValue {
                    // Directory — navigate into the parent and select it,
                    // matching Finder's "Show in Finder" semantics.
                    let parent = target.deletingLastPathComponent()
                    if parent.path == target.path {
                        activeExplorer.navigateTo(target)
                    } else {
                        activeExplorer.revealAndSelect(target)
                    }
                } else {
                    activeExplorer.revealAndSelect(target)
                }
            } else {
                NSSound.beep()
            }
        default:
            NSSound.beep()
        }
    }
}

// MARK: - Pane State (tabs)

@MainActor @Observable
class PaneState {
    var tabs: [FileExplorerViewModel] = []
    var activeTabIndex: Int = 0

    init() {
        tabs = [FileExplorerViewModel()]
    }

    var activeTab: FileExplorerViewModel {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else {
            return tabs[0]
        }
        return tabs[activeTabIndex]
    }

    func addTab(url: URL? = nil) {
        let vm = FileExplorerViewModel(url: url ?? FileManager.default.homeDirectoryForCurrentUser)
        tabs.append(vm)
        activeTabIndex = tabs.count - 1
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1 else { return }
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
    }

    func selectTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabIndex = index
    }
}
