import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var spaceMonitor: Any?
    var mouseDownMonitor: Any?
    let quickLookPanel = QuickLookPanelController()
    weak var appState: AppState?
    private var typeAheadBuffer: String = ""
    private var typeAheadTimer: Timer?

    /// True if `window` is one of the standalone helper windows (duplicate
    /// finder / folder compare). Those windows handle their own keyboard
    /// shortcuts, so app-wide handlers must not act on the main window's
    /// state when one of them is key.
    static func isHelperWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        let id = window.identifier?.rawValue ?? ""
        if id.contains("duplicate-finder") || id.contains("directory-compare") {
            return true
        }
        return window.title == "Find Duplicates" || window.title == "Compare Folders"
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppDelegate.shared = self
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
               let iconImage = NSImage(contentsOf: iconURL) {
                NSApplication.shared.applicationIconImage = iconImage
            }
            checkFullDiskAccess()
        }
    }

    private func checkFullDiskAccess() {
        if UserDefaults.standard.bool(forKey: "hasPromptedFullDiskAccess") { return }
        let testURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let hasAccess = (try? FileManager.default.contentsOfDirectory(atPath: testURL.path)) != nil
        if !hasAccess {
            let alert = NSAlert()
            alert.messageText = "Full Disk Access Required"
            alert.informativeText = "Seeker needs Full Disk Access to browse all files and folders, including Trash.\n\nGo to System Settings → Privacy & Security → Full Disk Access and enable Seeker."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Don't Ask Again")
            alert.addButton(withTitle: "Later")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                UserDefaults.standard.set(true, forKey: "hasPromptedFullDiskAccess")
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            } else if response == .alertSecondButtonReturn {
                UserDefaults.standard.set(true, forKey: "hasPromptedFullDiskAccess")
            }
        }
    }

    private var hasResignedInitialFocus = false

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            guard !hasResignedInitialFocus else { return }
            hasResignedInitialFocus = true
            // Remove focus from text fields (filter) on first activation
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                if let responder = window.firstResponder as? NSTextView, responder.isFieldEditor {
                    window.makeFirstResponder(window.contentView)
                }
            }
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        // Intentionally empty: location persistence is handled by the
        // SwiftUI `willTerminateNotification` publisher in `SeekerApp.body`,
        // which runs on the MainActor naturally. Saving here as well
        // produced a duplicate UserDefaults write on every quit.
    }

    func installSpaceMonitor(appState: AppState) {
        self.appState = appState
        AppDelegate.shared = self

        if spaceMonitor == nil {
            // Space key → Quick Look, Return key → Open item
            spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // A modal alert is up (e.g. the "Move to Trash?" confirm).
                // Let every key go to it — otherwise this monitor would,
                // for example, treat Return as the Rename shortcut and
                // swallow it before the alert's default button sees it.
                if NSApp.modalWindow != nil {
                    return event
                }

                // Standalone helper windows (duplicate finder, folder
                // compare) own their own keyboard handling via SwiftUI's
                // `.onKeyPress`. Don't let this main-window monitor steal
                // Space / ⌘⌫ / arrows from them, or it would act on the
                // main window's selection instead of the helper window's.
                if AppDelegate.isHelperWindow(event.window) {
                    // ⌘A would otherwise be grabbed by the auto Edit-menu
                    // "Select All" key-equivalent (which targets the
                    // native table, not the panel's custom selection).
                    // Consume it here and tell the panel to select all.
                    if event.keyCode == 0, event.modifierFlags.contains(.command),
                       !event.modifierFlags.contains(.option),
                       !event.modifierFlags.contains(.control) {
                        NotificationCenter.default.post(name: .triageSelectAllRequested, object: nil)
                        return nil
                    }
                    return event
                }

                // Check if a shortcut recorder is active — forward event and consume
                if ShortcutRecorderNSView.isRecordingShortcut {
                    ShortcutRecorderNSView.activeRecorder?.keyDown(with: event)
                    return nil
                }

                // Check if user is typing in a text field (search/filter/rename)
                let isTypingInTextField: Bool = {
                    guard let firstResponder = event.window?.value(forKey: "firstResponder") as? NSResponder else {
                        return false
                    }
                    // NSTextView field editors used by focused text fields
                    if let textView = firstResponder as? NSTextView,
                       textView.isFieldEditor {
                        return true
                    }
                    if firstResponder is NSTextField {
                        return true
                    }
                    return false
                }()
                if isTypingInTextField {
                    // Still allow Cmd shortcuts (Cmd+C, Cmd+V, Cmd+A) to work normally in text fields
                    return event
                }

                if event.keyCode == 49, !event.isARepeat {
                    // Space → Quick Look (or pause/resume if a slideshow
                    // is currently running in the Quick Look panel).
                    if let delegate = AppDelegate.shared {
                        if delegate.quickLookPanel.isAutoPreviewing {
                            delegate.quickLookPanel.toggleAutoPreviewPaused()
                            return nil
                        }
                        if let url = delegate.appState?.activeExplorer.selectedFile?.url {
                            delegate.quickLookPanel.togglePreview(for: url)
                        }
                    }
                    return nil // consume space so List doesn't scroll/deselect
                } else if event.keyCode == 53 {
                    // Escape → close Quick Look preview if visible
                    if let delegate = AppDelegate.shared,
                       delegate.quickLookPanel.isVisible {
                        delegate.quickLookPanel.close()
                        return nil
                    }
                } else if event.keyCode == 8, event.modifierFlags.contains(.command) {
                    // Cmd+C → Copy selected files
                    if let delegate = AppDelegate.shared {
                        delegate.appState?.activeExplorer.copySelected()
                    }
                    return nil
                } else if event.keyCode == 7, event.modifierFlags.contains(.command) {
                    // Cmd+X → Cut selected files
                    if let delegate = AppDelegate.shared {
                        delegate.appState?.activeExplorer.cutSelected()
                    }
                    return nil
                } else if event.keyCode == 9, event.modifierFlags.contains(.command), event.modifierFlags.contains(.option) {
                    // Cmd+Option+V → Move (paste as move)
                    if let delegate = AppDelegate.shared {
                        delegate.appState?.activeExplorer.pasteMoving()
                    }
                    return nil
                } else if event.keyCode == 9, event.modifierFlags.contains(.command) {
                    // Cmd+V → Paste files
                    if let delegate = AppDelegate.shared {
                        delegate.appState?.activeExplorer.paste()
                    }
                    return nil
                } else if event.keyCode == 0, event.modifierFlags.contains(.command) {
                    // Cmd+A → Select all files
                    if let delegate = AppDelegate.shared {
                        delegate.appState?.activeExplorer.selectAll()
                    }
                    return nil
                } else if event.keyCode == 6, event.modifierFlags.contains(.command) {
                    // Cmd+Z → Undo last file operation
                    if let delegate = AppDelegate.shared {
                        delegate.appState?.activeExplorer.undo()
                    }
                    return nil
                } else if (event.keyCode == 124 || event.keyCode == 123), event.modifierFlags.contains(.command) {
                    // Cmd+Right / Cmd+Left → Switch active pane
                    if let delegate = AppDelegate.shared, let state = delegate.appState, state.showDualPane {
                        state.activePane = (event.keyCode == 124) ? .right : .left
                    }
                    return nil
                } else if event.keyCode == 125 || event.keyCode == 126 || event.keyCode == 123 || event.keyCode == 124 {
                    // Arrow keys: Down(125) Up(126) Left(123) Right(124)
                    if let delegate = AppDelegate.shared,
                       let vm = delegate.appState?.activeExplorer {
                        let files = vm.files
                        guard !files.isEmpty else { return event }
                        let currentIndex = files.firstIndex(where: { $0 == vm.selectedFile })

                        let step: Int
                        let forward: Bool
                        switch (vm.viewMode, event.keyCode) {
                        case (.icons, 125): // Icon view Down → jump one row down
                            step = vm.iconGridColumnCount; forward = true
                        case (.icons, 126): // Icon view Up → jump one row up
                            step = vm.iconGridColumnCount; forward = false
                        case (.icons, 124): // Icon view Right → next item
                            step = 1; forward = true
                        case (.icons, 123): // Icon view Left → previous item
                            step = 1; forward = false
                        case (.list, 124): // List view Right → expand or step into
                            guard let current = vm.selectedFile,
                                  vm.isExpandable(current) else {
                                return nil
                            }
                            if !vm.isExpanded(current) {
                                vm.expandDirectory(current)
                                return nil
                            }
                            // Already expanded: step into the first child,
                            // matching Finder behaviour.
                            step = 1; forward = true
                        case (.list, 123): // List view Left → collapse or step to parent
                            if let current = vm.selectedFile {
                                if vm.isExpandable(current), vm.isExpanded(current) {
                                    vm.collapseDirectory(current)
                                    return nil
                                }
                                // Step back to the nearest ancestor row in
                                // the flattened display.
                                let currentDepth = vm.depth(of: current)
                                if currentDepth > 0,
                                   let idx = files.firstIndex(where: { $0 == current }) {
                                    var i = idx - 1
                                    while i >= 0 {
                                        if vm.depth(of: files[i]) < currentDepth {
                                            let parent = files[i]
                                            vm.selectionAnchor = parent
                                            vm.selectedFileIDs = [parent.id]
                                            return nil
                                        }
                                        i -= 1
                                    }
                                }
                            }
                            return nil
                        case (_, 125): // List/Column Down → next item
                            step = 1; forward = true
                        case (_, 126): // List/Column Up → previous item
                            step = 1; forward = false
                        default:
                            return event // ignore left/right in list/column mode
                        }

                        let newIndex: Int
                        if forward {
                            newIndex = (currentIndex == nil) ? 0 : min((currentIndex! + step), files.count - 1)
                        } else {
                            newIndex = (currentIndex == nil) ? 0 : max((currentIndex! - step), 0)
                        }
                        let newFile = files[newIndex]
                        if event.modifierFlags.contains(.shift) {
                            // Shift+Arrow: extend range selection
                            if vm.selectedFileIDs.isEmpty, let current = vm.selectedFile {
                                vm.selectedFileIDs = [current.id]
                            }
                            vm.selectedFileIDs.insert(newFile.id)
                            vm.selectionAnchor = newFile
                        } else {
                            // Plain arrow: single select
                            vm.selectionAnchor = newFile
                            vm.selectedFileIDs = [newFile.id]
                        }
                    }
                    return nil // consume arrow keys
                }

                // Handle configurable shortcuts from Settings
                if let matched = Self.matchConfiguredShortcut(event: event),
                   let delegate = AppDelegate.shared,
                   let state = delegate.appState {
                    Self.executeShortcutAction(matched, appState: state)
                    return nil
                }

                // Type-ahead: printable characters jump to matching file
                if !event.modifierFlags.contains(.command),
                   !event.modifierFlags.contains(.control),
                   let chars = event.characters, !chars.isEmpty,
                   let scalar = chars.unicodeScalars.first,
                   CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains(scalar),
                   let delegate = AppDelegate.shared,
                   let vm = delegate.appState?.activeExplorer {
                    delegate.typeAheadBuffer += chars
                    delegate.typeAheadTimer?.invalidate()
                    delegate.typeAheadTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            delegate.typeAheadBuffer = ""
                        }
                    }
                    let prefix = delegate.typeAheadBuffer.lowercased()
                    if let match = vm.files.first(where: { $0.name.lowercased().hasPrefix(prefix) }) {
                        vm.selectionAnchor = match
                        vm.selectedFileIDs = [match.id]
                    }
                    return nil
                }

                return event
            }
        }

        if mouseDownMonitor == nil {
            // MouseDown → detect which pane was clicked to set activePane
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                guard let delegate = AppDelegate.shared,
                      let state = delegate.appState,
                      let window = event.window else {
                    return event
                }
                let windowPoint = event.locationInWindow
                let screenPoint = window.convertPoint(toScreen: windowPoint)
                let windowFrame = window.frame
                let flippedY = windowFrame.maxY - screenPoint.y
                let globalPoint = CGPoint(x: screenPoint.x - windowFrame.minX, y: flippedY)

                if state.leftPaneFrame.contains(globalPoint) && state.activePane != .left {
                    DispatchQueue.main.async { state.activePane = .left }
                } else if state.rightPaneFrame.contains(globalPoint) && state.activePane != .right {
                    DispatchQueue.main.async { state.activePane = .right }
                }
                return event
            }
        }
    }

    func updateQuickLookIfVisible(url: URL) {
        if quickLookPanel.isVisible {
            quickLookPanel.updatePreview(for: url)
        }
    }

    // MARK: - Configurable Shortcut Handling

    static func matchConfiguredShortcut(event: NSEvent) -> ShortcutAction? {
        let eventKey = keyString(from: event)
        guard !eventKey.isEmpty else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var eventMods: Set<KeyShortcut.KeyModifier> = []
        if flags.contains(.command) { eventMods.insert(.command) }
        if flags.contains(.shift) { eventMods.insert(.shift) }
        if flags.contains(.option) { eventMods.insert(.option) }
        if flags.contains(.control) { eventMods.insert(.control) }
        let eventShortcut = KeyShortcut(key: eventKey, modifiers: eventMods)
        // O(1) lookup via SettingsManager's reverse index. The previous
        // implementation walked every ShortcutAction per keystroke and
        // re-decoded each entry from UserDefaults on cold paths.
        return SettingsManager.shared.action(matching: eventShortcut)
    }

    private static func keyString(from event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case 51: return "⌫"    // kVK_Delete
        case 117: return "⌦"   // kVK_ForwardDelete
        case 36: return "⏎"    // kVK_Return
        case 48: return "⇥"    // kVK_Tab
        case 49: return "Space" // kVK_Space
        case 126: return "↑"   // kVK_UpArrow
        case 125: return "↓"   // kVK_DownArrow
        case 123: return "←"   // kVK_LeftArrow
        case 124: return "→"   // kVK_RightArrow
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PgUp"
        case 121: return "PgDn"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        default:
            return event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }

    static func executeShortcutAction(_ action: ShortcutAction, appState: AppState) {
        switch action {
        case .openFile:
            if let file = appState.activeExplorer.selectedFile {
                appState.activeExplorer.openItem(file)
            }
        case .newFolder:
            appState.activeExplorer.createNewFolder()
        case .newFile:
            appState.activeExplorer.createNewFile()
        case .moveToTrash:
            appState.activeExplorer.trashSelected()
        case .rename:
            if let file = appState.activeExplorer.selectedFile {
                appState.activeExplorer.beginRename(file)
            }
        case .copyToOtherPane:
            appState.copyToOtherPane()
        case .moveToOtherPane:
            appState.moveToOtherPane()
        case .goBack:
            appState.activeExplorer.goBack()
        case .goForward:
            appState.activeExplorer.goForward()
        case .enclosingFolder:
            appState.activeExplorer.goUp()
        case .goHome:
            appState.activeExplorer.navigateTo(FileManager.default.homeDirectoryForCurrentUser)
        case .goDesktop:
            appState.activeExplorer.navigateTo(
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
        case .goDownloads:
            appState.activeExplorer.navigateTo(
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
        case .goToFolder:
            appState.requestEditPath()
        case .toggleFavorites:
            withAnimation { appState.showFavorites.toggle() }
        case .toggleDualPane:
            withAnimation { appState.showDualPane.toggle() }
        case .listView:
            appState.activeExplorer.viewMode = .list
        case .iconView:
            appState.activeExplorer.viewMode = .icons
        case .columnView:
            appState.activeExplorer.viewMode = .columns
        case .toggleHiddenFiles:
            appState.activeExplorer.showHiddenFiles.toggle()
            appState.activeExplorer.loadFiles()
        case .newTab:
            let pane = appState.activePane == .left ? appState.leftPane : appState.rightPane
            pane.addTab()
        case .closeTab:
            let pane = appState.activePane == .left ? appState.leftPane : appState.rightPane
            pane.closeTab(at: pane.activeTabIndex)
        }
    }
}

@main
struct SeekerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @State private var shortcutVersion = 0

    init() {
        // Show .help(...) tooltips after 500ms instead of macOS default (~2s).
        // Must be set before AppKit reads it during launch.
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 500
        ])
        UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")
    }

    var body: some Scene {
        // Use `Window` (singleton) rather than `WindowGroup` so that
        // incoming `seeker://` URLs from "Reveal in Seeker" cannot spawn
        // additional windows. The app shares one AppState and one global
        // key-event monitor, so a second window would route its keystrokes
        // back into the first window's active pane.
        Window("Seeker", id: "main") {
            ContentView()
                .environment(appState)
                .onAppear {
                    appDelegate.installSpaceMonitor(appState: appState)
                    appState.restoreLastLocations()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                    appState.saveCurrentLocations()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.saveCurrentLocations()
                }
                .onReceive(NotificationCenter.default.publisher(for: .explorerDidNavigate)) { _ in
                    appState.saveCurrentLocations()
                }
                .onReceive(NotificationCenter.default.publisher(for: .shortcutsChanged)) { _ in
                    shortcutVersion += 1
                }
                .onOpenURL { url in
                    appState.handleIncomingURL(url)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 700)

        // Standalone duplicate-finder window. Non-modal so the user can
        // click "Open in new tab" on a row, switch to the main window,
        // inspect the file, and come back to keep triaging.
        WindowGroup("Find Duplicates", id: "duplicate-finder", for: [URL].self) { $rootURLs in
            if let urls = rootURLs, !urls.isEmpty {
                DuplicateFinderView(rootURLs: urls)
                    .environment(appState)
            }
        }
        .windowResizability(.contentMinSize)

        // Standalone folder-compare window. Two directories diffed by
        // file name; lives in its own window like the duplicate finder.
        WindowGroup("Compare Folders", id: "directory-compare", for: [URL].self) { $dirs in
            if let dirs, dirs.count == 2 {
                DirectoryCompareView(dirA: dirs[0], dirB: dirs[1])
                    .environment(appState)
            }
        }
        .windowResizability(.contentMinSize)

        // Standalone recursive search window.
        WindowGroup("Search", id: "file-search", for: URL.self) { $root in
            if let root {
                FileSearchView(root: root)
                    .environment(appState)
            }
        }
        .windowResizability(.contentMinSize)

        // Standalone folder-sync window.
        WindowGroup("Sync Folders", id: "folder-sync", for: [URL].self) { $dirs in
            if let dirs, dirs.count == 2 {
                FolderSyncView(rootA: dirs[0], rootB: dirs[1])
                    .environment(appState)
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // MARK: - View Menu
            CommandGroup(after: .sidebar) {
                Button("Toggle Favorites Sidebar") {
                    withAnimation { appState.showFavorites.toggle() }
                }
                .shortcut(for: .toggleFavorites)

                Button("Toggle Dual Pane") {
                    withAnimation { appState.showDualPane.toggle() }
                }
                .shortcut(for: .toggleDualPane)

                Button("Swap Panes") {
                    appState.swapPanes()
                }
                .disabled(!appState.showDualPane)

                Divider()

                Button("List View") {
                    appState.activeExplorer.viewMode = .list
                }
                .shortcut(for: .listView)

                Button("Icon View") {
                    appState.activeExplorer.viewMode = .icons
                }
                .shortcut(for: .iconView)

                Button("Column View") {
                    appState.activeExplorer.viewMode = .columns
                }
                .shortcut(for: .columnView)

                Divider()

                Button("Zoom In") {
                    appState.activeExplorer.zoomIconsIn()
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(appState.activeExplorer.viewMode != .icons)

                Button("Zoom Out") {
                    appState.activeExplorer.zoomIconsOut()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(appState.activeExplorer.viewMode != .icons)

                Button("Actual Size") {
                    appState.activeExplorer.resetIconZoom()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(appState.activeExplorer.viewMode != .icons)

                Divider()

                Button(appState.activeExplorer.showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files") {
                    appState.activeExplorer.showHiddenFiles.toggle()
                    appState.activeExplorer.loadFiles()
                }
                .shortcut(for: .toggleHiddenFiles)
            }

            // MARK: - File Operations (Edit menu)
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Open") {
                    if let file = appState.activeExplorer.selectedFile {
                        appState.activeExplorer.openItem(file)
                    }
                }
                .shortcut(for: .openFile)

                Button("New Folder") {
                    appState.activeExplorer.createNewFolder()
                }
                .shortcut(for: .newFolder)

                Button("New File") {
                    appState.activeExplorer.createNewFile()
                }
                .shortcut(for: .newFile)

                Divider()

                Button("Move to Trash") {
                    // ⌘⌫ is an app-wide menu shortcut, so it fires even
                    // when a standalone helper window is key. Route it to
                    // that window's triage panel instead of the main
                    // window's explorer.
                    if AppDelegate.isHelperWindow(NSApp.keyWindow) {
                        NotificationCenter.default.post(name: .triageMoveToTrashRequested, object: nil)
                    } else {
                        appState.activeExplorer.trashSelected()
                    }
                }
                .shortcut(for: .moveToTrash)

                Button("Delete Immediately\u{2026}") {
                    // Permanent delete bypasses the Trash. Only meaningful
                    // for the main window; ignore when a helper window
                    // (which only trashes) is key.
                    if !AppDelegate.isHelperWindow(NSApp.keyWindow) {
                        appState.activeExplorer.deleteSelectedPermanently()
                    }
                }
                .keyboardShortcut(.delete, modifiers: [.command, .option])

                Button("Rename") {
                    if let file = appState.activeExplorer.selectedFile {
                        appState.activeExplorer.beginRename(file)
                    }
                }

                Button("Batch Rename\u{2026}") {
                    appState.openBatchRename()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Copy to Other Pane") {
                    appState.copyToOtherPane()
                }
                .shortcut(for: .copyToOtherPane)

                Button("Move to Other Pane") {
                    appState.moveToOtherPane()
                }
                .shortcut(for: .moveToOtherPane)
            }

            // MARK: - Go Menu
            CommandMenu("Go") {
                Button("Back") {
                    appState.activeExplorer.goBack()
                }
                .shortcut(for: .goBack)

                Button("Forward") {
                    appState.activeExplorer.goForward()
                }
                .shortcut(for: .goForward)

                Button("Enclosing Folder") {
                    appState.activeExplorer.goUp()
                }
                .shortcut(for: .enclosingFolder)

                Divider()

                Button("Home") {
                    appState.activeExplorer.navigateTo(
                        FileManager.default.homeDirectoryForCurrentUser
                    )
                }
                .shortcut(for: .goHome)

                Button("Desktop") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                    appState.activeExplorer.navigateTo(url)
                }
                .shortcut(for: .goDesktop)

                Button("Downloads") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                    appState.activeExplorer.navigateTo(url)
                }
                .shortcut(for: .goDownloads)

                Button("Documents") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
                    appState.activeExplorer.navigateTo(url)
                }

                Button("Applications") {
                    appState.activeExplorer.navigateTo(URL(fileURLWithPath: "/Applications"))
                }

                Divider()

                Button("Go to Folder…") {
                    appState.requestEditPath()
                }
                .shortcut(for: .goToFolder)
            }

            // MARK: - Tabs
            CommandMenu("Tab") {
                Button("New Tab") {
                    let pane = appState.activePane == .left ? appState.leftPane : appState.rightPane
                    pane.addTab()
                }
                .shortcut(for: .newTab)

                Button("Close Tab") {
                    let pane = appState.activePane == .left ? appState.leftPane : appState.rightPane
                    pane.closeTab(at: pane.activeTabIndex)
                }
                .shortcut(for: .closeTab)
            }

            // MARK: - Refresh
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    appState.activeExplorer.loadFiles()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

// MARK: - Configurable Shortcut Modifier

extension View {
    /// Apply a user-configured keyboard shortcut without `AnyView` erasure.
    /// Returning a concrete `some View` keeps SwiftUI's structural diffing
    /// intact for menu commands (every menu item used `AnyView` previously,
    /// defeating diffing across menu rebuilds).
    @ViewBuilder
    func shortcut(for action: ShortcutAction) -> some View {
        if let s = SettingsManager.shared.shortcut(for: action).swiftUIKeyboardShortcut {
            self.keyboardShortcut(s)
        } else {
            self
        }
    }
}
