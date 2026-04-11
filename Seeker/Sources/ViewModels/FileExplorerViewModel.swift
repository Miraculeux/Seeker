import Foundation
import Observation
import AppKit

extension Notification.Name {
    static let explorerDidNavigate = Notification.Name("explorerDidNavigate")
    static let columnSettingsChanged = Notification.Name("columnSettingsChanged")
    static let filesDidChange = Notification.Name("filesDidChange")
}

@MainActor @Observable
class FileExplorerViewModel: Identifiable {
    let id = UUID()
    var currentURL: URL
    var files: [FileItem] = []
    var selectionAnchor: FileItem?
    var selectedFileIDs: Set<FileItem.ID> = []
    var iconGridColumnCount: Int = 1

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

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = url
        navigateTo(url)
        _observer.value = NotificationCenter.default.addObserver(
            forName: .filesDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, notification.object as AnyObject? !== self else { return }
            MainActor.assumeIsolated {
                self.loadFiles()
            }
        }
    }

    deinit {
        if let observer = _observer.value {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Navigation

    func navigateTo(_ url: URL) {
        let isSameURL = (currentURL == url)
        currentURL = url
        searchText = ""
        isSearching = false
        selectionAnchor = nil
        selectedFileIDs = []

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
        do {
            let url = currentURL.standardizedFileURL
            let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]

            // Try the URL as-is first, then resolve symlinks on failure
            // Pass nil for resource keys to avoid TCC prompts on protected directories
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: options
                )
            } catch {
                // If this is the Trash directory, use Finder AppleScript to list contents
                let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                if url.standardizedFileURL == trashURL.standardizedFileURL || url.resolvingSymlinksInPath() == trashURL.resolvingSymlinksInPath() {
                    files = loadTrashViaFinder()
                    return
                }
                let resolved = url.resolvingSymlinksInPath()
                contents = try FileManager.default.contentsOfDirectory(
                    at: resolved, includingPropertiesForKeys: nil, options: options
                )
            }

            var items = contents.map { FileItem(url: $0) }

            // Apply search filter
            if !searchText.isEmpty {
                items = items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            }

            items = sortItems(items)
            files = items
        } catch {
            print("[Seeker] Failed to load files at \(currentURL.path): \(error)")
            files = []
        }
    }

    private func loadTrashViaFinder() -> [FileItem] {
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

        var items: [FileItem] = []
        let count = result.numberOfItems
        guard count > 0 else { return [] }
        for i in 1...count {
            if let pathDesc = result.atIndex(i), let path = pathDesc.stringValue {
                let url = URL(fileURLWithPath: path)
                items.append(FileItem(url: url))
            }
        }

        if !searchText.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        return sortItems(items)
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
            undoStack.append(.create(url: newURL))
            loadFiles()
            notifyFilesChanged()
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
            undoStack.append(.create(url: newURL))
            loadFiles()
            notifyFilesChanged()
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
                self?.notifyFilesChanged()
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

    func duplicateSelected() {
        let items = effectiveSelection
        guard !items.isEmpty else { return }
        let sources = items.map(\.url)
        let dest = currentURL
        FileOperationManager.shared.startCopy(sources: sources, to: dest) { [weak self] op in
            self?.loadFiles()
            self?.notifyFilesChanged()
            if !op.completedDestinations.isEmpty {
                self?.undoStack.append(.copy(destinationURLs: op.completedDestinations))
            }
        }
    }

    func trashSelected() {
        let items = effectiveSelection
        guard !items.isEmpty else { return }
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
        loadFiles()
        notifyFilesChanged()
    }

    func moveSelectedTo(destination: URL) {
        let items = effectiveSelection
        guard !items.isEmpty else { return }
        let sources = items.map(\.url)
        FileOperationManager.shared.startMove(sources: sources, to: destination) { [weak self] op in
            self?.loadFiles()
            self?.notifyFilesChanged()
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
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            for file in ncmFiles {
                let outputDir = file.url.deletingLastPathComponent().path
                do {
                    var crypt = try NCMCrypt(path: file.url.path)
                    try crypt.dump(outputDir: outputDir)
                    crypt.fixMetadata()
                } catch {
                    errors.append("\(file.name): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { [weak self] in
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
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: folder.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            var errors: [String] = []
            var count = 0
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "ncm" else { continue }
                let outputDir = fileURL.deletingLastPathComponent().path
                do {
                    var crypt = try NCMCrypt(path: fileURL.path)
                    try crypt.dump(outputDir: outputDir)
                    crypt.fixMetadata()
                    count += 1
                } catch {
                    errors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.loadFiles()
                self?.notifyFilesChanged()
                if !errors.isEmpty {
                    self?.showFileError("NCM dump failed (\(count) ok, \(errors.count) failed):\n\(errors.joined(separator: "\n"))")
                }
            }
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
        NotificationCenter.default.post(name: .filesDidChange, object: self)
    }
}

final class UncheckedSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
