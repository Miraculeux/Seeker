import Foundation
import Observation
import AppKit

extension Notification.Name {
    static let explorerDidNavigate = Notification.Name("explorerDidNavigate")
    static let columnSettingsChanged = Notification.Name("columnSettingsChanged")
}

@MainActor @Observable
class FileExplorerViewModel: Identifiable {
    let id = UUID()
    var currentURL: URL
    var files: [FileItem] = []
    var selectionAnchor: FileItem?
    var selectedFileIDs: Set<FileItem.ID> = []

    var selectedFile: FileItem? {
        guard let anchorID = selectionAnchor?.id, selectedFileIDs.contains(anchorID) else {
            let fileMap = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
            return selectedFileIDs.first.flatMap { fileMap[$0] }
        }
        return selectionAnchor
    }

    var selectedFiles: Set<FileItem> {
        let fileMap = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        return Set(selectedFileIDs.compactMap { fileMap[$0] })
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
    var viewMode: ViewMode = .list

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

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = url
        navigateTo(url)
    }

    // MARK: - Navigation

    func navigateTo(_ url: URL) {
        currentURL = url
        searchText = ""
        isSearching = false
        selectionAnchor = nil
        selectedFileIDs = []

        // Manage history
        if historyIndex < pathHistory.count - 1 {
            pathHistory = Array(pathHistory.prefix(historyIndex + 1))
        }
        pathHistory.append(url)
        historyIndex = pathHistory.count - 1

        loadFiles()

        // Notify so AppState can persist location
        NotificationCenter.default.post(name: .explorerDidNavigate, object: nil)
    }

    func loadFiles() {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .fileSizeKey,
                    .contentModificationDateKey, .creationDateKey,
                    .isHiddenKey, .isPackageKey
                ],
                options: showHiddenFiles ? [] : [.skipsHiddenFiles]
            )
            var items = contents.map { FileItem(url: $0) }

            // Apply search filter
            if !searchText.isEmpty {
                items = items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            }

            items = sortItems(items)
            files = items
        } catch {
            files = []
        }
    }

    func sortItems(_ items: [FileItem]) -> [FileItem] {
        let sorted = items.sorted { a, b in
            // Directories first
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            switch sortOrder {
            case .name:
                return sortAscending
                    ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                    : a.name.localizedStandardCompare(b.name) == .orderedDescending
            case .date:
                let dateA = a.modificationDate ?? Date.distantPast
                let dateB = b.modificationDate ?? Date.distantPast
                return sortAscending ? dateA < dateB : dateA > dateB
            case .size:
                return sortAscending ? a.fileSize < b.fileSize : a.fileSize > b.fileSize
            case .kind:
                return sortAscending
                    ? a.typeDescription.localizedStandardCompare(b.typeDescription) == .orderedAscending
                    : a.typeDescription.localizedStandardCompare(b.typeDescription) == .orderedDescending
            }
        }
        return sorted
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
        if item.isDirectory {
            navigateTo(item.url)
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
        var components: [(String, URL)] = []
        var url = currentURL
        while url.path != "/" {
            components.insert((url.lastPathComponent, url), at: 0)
            url = url.deletingLastPathComponent()
        }
        components.insert(("/", URL(fileURLWithPath: "/")), at: 0)
        return components
    }

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
            loadFiles()
            // Select the new folder and start renaming
            let newItem = FileItem(url: newURL)
            selectionAnchor = newItem
            selectedFileIDs = [newItem.id]
            beginRename(newItem)
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
            loadFiles()
            let newItem = FileItem(url: newURL)
            selectionAnchor = newItem
            selectedFileIDs = [newItem.id]
            beginRename(newItem)
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

        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(renameText)
        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
            renamingFile = nil
            loadFiles()
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
            FileOperationManager.shared.startMove(sources: urls, to: dest) { [weak self] in
                self?.loadFiles()
            }
        } else {
            FileOperationManager.shared.startCopy(sources: urls, to: dest) { [weak self] in
                self?.loadFiles()
            }
        }
    }

    func duplicateSelected() {
        let items = effectiveSelection
        guard !items.isEmpty else { return }
        let sources = items.map(\.url)
        let dest = currentURL
        FileOperationManager.shared.startCopy(sources: sources, to: dest) { [weak self] in
            self?.loadFiles()
        }
    }

    func trashSelected() {
        let items = effectiveSelection
        guard !items.isEmpty else { return }
        for item in items {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                showFileError("Could not move to Trash: \(error.localizedDescription)")
                return
            }
        }
        selectionAnchor = nil
        selectedFileIDs = []
        loadFiles()
    }

    func moveSelectedTo(destination: URL) {
        let items = effectiveSelection
        guard !items.isEmpty else { return }
        let sources = items.map(\.url)
        FileOperationManager.shared.startMove(sources: sources, to: destination) { [weak self] in
            self?.loadFiles()
        }
    }

    // MARK: - Multi-Selection

    func handleFileClick(_ file: FileItem, command: Bool, shift: Bool) {
        if shift, let anchor = selectionAnchor ?? selectedFile {
            // Shift-click: range select from anchor to clicked file
            guard let anchorIndex = files.firstIndex(of: anchor),
                  let clickIndex = files.firstIndex(of: file) else {
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
                selectionAnchor = files.first { selectedFileIDs.contains($0.id) }
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

    private func showFileError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
