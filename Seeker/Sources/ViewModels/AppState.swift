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
        didSet { SettingsManager.shared.showDualPane = showDualPane }
    }
    var showInfoPanel: Bool = SettingsManager.shared.showInfoPanel {
        didSet { SettingsManager.shared.showInfoPanel = showInfoPanel }
    }
    var showGoToFolder: Bool = false

    /// Non-nil when the Metadata Editor sheet is open. Holds the URLs of
    /// the image(s) being edited.
    var metadataEditorTargets: [URL]?

    /// Opens the editor for the active pane's effective image selection.
    /// No-op when no editable images are selected.
    func openMetadataEditor() {
        let urls = activeExplorer.effectiveSelection
            .filter(\.isEditableImage)
            .map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        metadataEditorTargets = urls
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
