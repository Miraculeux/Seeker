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

    // Panes - each has tabs
    var leftPane = PaneState()
    var rightPane = PaneState()

    // Which pane is active
    var activePane: PaneSide = .left

    // Pane screen frames for click detection
    var leftPaneFrame: CGRect = .zero
    var rightPaneFrame: CGRect = .zero

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
        FileOperationManager.shared.startCopy(sources: sources, to: dest) {
            inactive.loadFiles()
        }
    }

    func moveToOtherPane() {
        let items = activeExplorer.effectiveSelection
        guard !items.isEmpty else { return }
        let dest = inactiveExplorer.currentURL
        let sources = items.map(\.url)
        let active = activeExplorer
        let inactive = inactiveExplorer
        FileOperationManager.shared.startMove(sources: sources, to: dest) {
            active.loadFiles()
            inactive.loadFiles()
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
    }

    func saveCurrentLocations() {
        let settings = SettingsManager.shared
        guard settings.rememberLastLocation else { return }
        settings.saveLocations(
            left: leftPane.activeTab.currentURL,
            right: rightPane.activeTab.currentURL
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
