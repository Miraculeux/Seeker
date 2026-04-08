import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var spaceMonitor: Any?
    var doubleClickMonitor: Any?
    var mouseDownMonitor: Any?
    let quickLookPanel = QuickLookPanelController()
    weak var appState: AppState?
    private var typeAheadBuffer: String = ""
    private var typeAheadTimer: Timer?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
               let iconImage = NSImage(contentsOf: iconURL) {
                NSApplication.shared.applicationIconImage = iconImage
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
        MainActor.assumeIsolated {
            appState?.saveCurrentLocations()
        }
    }

    func installSpaceMonitor(appState: AppState) {
        self.appState = appState
        AppDelegate.shared = self

        if spaceMonitor == nil {
            // Space key → Quick Look, Return key → Open item
            spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
                    // Space → Quick Look
                    if let delegate = AppDelegate.shared,
                       let url = delegate.appState?.activeExplorer.selectedFile?.url {
                        delegate.quickLookPanel.togglePreview(for: url)
                    }
                    return nil // consume space so List doesn't scroll/deselect
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

        if doubleClickMonitor == nil {
            // Double-click → Open item (only on actual list/collection rows)
            doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                guard event.clickCount == 2,
                      let delegate = AppDelegate.shared,
                      let state = delegate.appState,
                      let window = event.window else { return event }

                // Only proceed if the click is on a table row (file list row)
                let windowPoint = event.locationInWindow
                if let hitView = window.contentView?.hitTest(windowPoint) {
                    var isOnRow = false
                    var view: NSView? = hitView
                    while let v = view {
                        if v is NSTableRowView || v is NSCollectionView {
                            isOnRow = true
                            break
                        }
                        view = v.superview
                    }
                    guard isOnRow else { return event }
                }

                let screenPoint = window.convertPoint(toScreen: windowPoint)
                let windowFrame = window.frame
                let flippedY = windowFrame.maxY - screenPoint.y
                let globalPoint = CGPoint(x: screenPoint.x - windowFrame.minX, y: flippedY)
                // Only trigger if click is inside a pane
                guard state.leftPaneFrame.contains(globalPoint) ||
                      state.rightPaneFrame.contains(globalPoint) else { return event }
                if let file = state.activeExplorer.selectedFile {
                    state.activeExplorer.openItem(file)
                }
                return event
            }
        }

        if mouseDownMonitor == nil {
            // MouseDown → detect which pane was clicked to set activePane
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
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

        for action in ShortcutAction.allCases {
            let configured = SettingsManager.shared.shortcut(for: action)
            if configured == eventShortcut {
                return action
            }
        }
        return nil
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
        case .duplicate:
            appState.activeExplorer.duplicateSelected()
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
            appState.showGoToFolder = true
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

    var body: some Scene {
        WindowGroup {
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
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 700)
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

                Button("Duplicate") {
                    appState.activeExplorer.duplicateSelected()
                }
                .shortcut(for: .duplicate)

                Button("Move to Trash") {
                    appState.activeExplorer.trashSelected()
                }
                .shortcut(for: .moveToTrash)

                Button("Rename") {
                    if let file = appState.activeExplorer.selectedFile {
                        appState.activeExplorer.beginRename(file)
                    }
                }

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
                    appState.showGoToFolder = true
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
        }
    }
}

// MARK: - Configurable Shortcut Modifier

extension View {
    func shortcut(for action: ShortcutAction) -> some View {
        let ks = SettingsManager.shared.shortcut(for: action)
        if let shortcut = ks.swiftUIKeyboardShortcut {
            return AnyView(self.keyboardShortcut(shortcut))
        }
        return AnyView(self)
    }
}
