import SwiftUI
import AppKit

private struct SeekerAppStateFocusedKey: FocusedValueKey {
    typealias Value = AppState
}

private extension FocusedValues {
    var seekerAppState: AppState? {
        get { self[SeekerAppStateFocusedKey.self] }
        set { self[SeekerAppStateFocusedKey.self] = newValue }
    }
}

struct DuplicateFinderWindowRequest: Codable, Hashable {
    let rootURLs: [URL]
    let sourceWindowID: UUID
}

struct DirectoryCompareWindowRequest: Codable, Hashable {
    let directories: [URL]
    let sourceWindowID: UUID
}

struct FileSearchWindowRequest: Codable, Hashable {
    let root: URL
    let sourceWindowID: UUID
}

struct FolderSyncWindowRequest: Codable, Hashable {
    let directories: [URL]
    let sourceWindowID: UUID
}

@MainActor
final class MainWindowRegistry {
    static let shared = MainWindowRegistry()

    private final class Entry {
        weak var window: NSWindow?
        weak var appState: AppState?

        init(window: NSWindow, appState: AppState) {
            self.window = window
            self.appState = appState
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private(set) weak var mostRecentAppState: AppState?
    private var pendingRevealURL: URL?

    func register(window: NSWindow, appState: AppState) {
        entries[ObjectIdentifier(window)] = Entry(window: window, appState: appState)
        mostRecentAppState = appState
    }

    func unregister(window: NSWindow, appState: AppState) {
        let key = ObjectIdentifier(window)
        guard entries[key]?.appState === appState else { return }
        entries.removeValue(forKey: key)
        if mostRecentAppState === appState {
            mostRecentAppState = entries.values.compactMap(\.appState).last
        }
    }

    func appState(for window: NSWindow?) -> AppState? {
        guard let window else { return nil }
        if let state = entries[ObjectIdentifier(window)]?.appState { return state }
        if let parent = window.sheetParent {
            return entries[ObjectIdentifier(parent)]?.appState
        }
        return nil
    }

    func window(for appState: AppState) -> NSWindow? {
        entries.values.first(where: { $0.appState === appState })?.window
    }

    func appState(for windowID: UUID?) -> AppState? {
        guard let windowID else { return nil }
        return entries.values.compactMap(\.appState).first { $0.windowID == windowID }
    }

    func queueReveal(_ url: URL) {
        pendingRevealURL = url
    }

    func consumePendingReveal() -> URL? {
        defer { pendingRevealURL = nil }
        return pendingRevealURL
    }

    func markActive(window: NSWindow) {
        if let state = appState(for: window) { mostRecentAppState = state }
        pruneReleasedEntries()
    }

    private func pruneReleasedEntries() {
        entries = entries.filter { $0.value.window != nil && $0.value.appState != nil }
    }
}

private struct MainWindowRegistrationView: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(appState: appState)
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.appState = appState
        nsView.registerCurrentWindow()
    }

    static func dismantleNSView(_ nsView: RegistrationView, coordinator: ()) {
        nsView.unregisterCurrentWindow()
    }

    final class RegistrationView: NSView {
        weak var appState: AppState?
        private weak var registeredWindow: NSWindow?
        private var activationObserver: NSObjectProtocol?

        init(appState: AppState) {
            self.appState = appState
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerCurrentWindow()
        }

        func registerCurrentWindow() {
            guard let window, let appState else { return }
            if registeredWindow !== window {
                unregisterCurrentWindow()
                registeredWindow = window
                MainWindowRegistry.shared.register(window: window, appState: appState)
                activationObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window { MainWindowRegistry.shared.markActive(window: window) }
                    }
                }
            }
        }

        func unregisterCurrentWindow() {
            if let activationObserver {
                NotificationCenter.default.removeObserver(activationObserver)
                self.activationObserver = nil
            }
            if let registeredWindow, let appState {
                MainWindowRegistry.shared.unregister(window: registeredWindow, appState: appState)
            }
            registeredWindow = nil
        }

    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var spaceMonitor: Any?
    var mouseDownMonitor: Any?
    let quickLookPanel = QuickLookPanelController()
    let textPreviewPanel = TextPreviewPanelController()
    private weak var quickLookAppState: AppState?
    private weak var textPreviewAppState: AppState?
    private var typeAheadBuffer: String = ""
    private var typeAheadTimer: Timer?
    private var typeAheadWindowID: ObjectIdentifier?

    /// True if `window` is one of the standalone helper windows (duplicate
    /// finder / folder compare). Those windows handle their own keyboard
    /// shortcuts, so app-wide handlers must not act on the main window's
    /// state when one of them is key.
    static func isHelperWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        let id = window.identifier?.rawValue ?? ""
        if id.contains("duplicate-finder") || id.contains("directory-compare")
            || id.contains("file-search") || id.contains("similar-images")
            || id.contains("semantic-search") || id.contains("folder-sync") {
            return true
        }
        return window.title == "Find Duplicates" || window.title == "Compare Folders"
            || window.title == "Search" || window.title == "Similar Images"
            || window.title == "Semantic Search" || window.title == "Sync Folders"
    }

    static func isTriageWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        let id = window.identifier?.rawValue ?? ""
        if id.contains("duplicate-finder") || id.contains("directory-compare")
            || id.contains("similar-images") || id.contains("semantic-search") {
            return true
        }
        return window.title == "Find Duplicates" || window.title == "Compare Folders"
            || window.title == "Similar Images" || window.title == "Semantic Search"
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

    func installSpaceMonitor() {
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
                    // Floating preview panels are shared with the main
                    // window. Close them here before returning helper-window
                    // events, so Escape works without clicking the panel.
                    if event.keyCode == 53, let delegate = AppDelegate.shared {
                        if delegate.textPreviewPanel.isVisible {
                            delegate.textPreviewPanel.close()
                            return nil
                        }
                        if delegate.quickLookPanel.isVisible {
                            delegate.quickLookPanel.close()
                            return nil
                        }
                    }
                    // ⌘A would otherwise be grabbed by the auto Edit-menu
                    // "Select All" key-equivalent (which targets the
                    // native table, not the panel's custom selection).
                    // Consume it here and tell the panel to select all.
                          if AppDelegate.isTriageWindow(event.window), event.keyCode == 0,
                              event.modifierFlags.contains(.command),
                       !event.modifierFlags.contains(.option),
                       !event.modifierFlags.contains(.control) {
                        NotificationCenter.default.post(name: .triageSelectAllRequested, object: nil)
                        return nil
                    }
                    return event
                }

                // Once the user clicks into the text preview, let its native
                // NSTextView handle selection, copy, Select All and navigation.
                if let delegate = AppDelegate.shared,
                   delegate.textPreviewPanel.isTextViewFirstResponder(in: event.window) {
                    if event.keyCode == 53 {
                        delegate.textPreviewPanel.close()
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

                guard let state = MainWindowRegistry.shared.appState(for: event.window) else {
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
                        if let url = state.activeExplorer.selectedFile?.url {
                            delegate.toggleQuickLookPreview(for: url, appState: state)
                        }
                    }
                    return nil // consume space so List doesn't scroll/deselect
                } else if event.keyCode == 33 || event.keyCode == 30 {
                    // `[` (33) or `]` (30) → toggle the plain-text preview
                    // panel for the current selection. While it's open the
                    // arrow keys move the selection and it auto-updates.
                    if !event.isARepeat, let delegate = AppDelegate.shared {
                        if delegate.textPreviewPanel.isVisible {
                            delegate.textPreviewPanel.close()
                        } else if let url = state.activeExplorer.selectedFile?.url {
                            delegate.textPreviewAppState = state
                            delegate.textPreviewPanel.togglePreview(for: url)
                        }
                    }
                    return nil
                } else if event.keyCode == 53 {
                    // Escape → close text preview / Quick Look preview if visible
                    if let delegate = AppDelegate.shared {
                        if delegate.textPreviewPanel.isVisible {
                            delegate.textPreviewPanel.close()
                            return nil
                        }
                        if delegate.quickLookPanel.isVisible {
                            delegate.quickLookPanel.close()
                            return nil
                        }
                    }
                } else if event.keyCode == 8, event.modifierFlags.contains(.command) {
                    // Cmd+C → Copy selected files
                    state.activeExplorer.copySelected()
                    return nil
                } else if event.keyCode == 7, event.modifierFlags.contains(.command) {
                    // Cmd+X → Cut selected files
                    state.activeExplorer.cutSelected()
                    return nil
                } else if event.keyCode == 9, event.modifierFlags.contains(.command), event.modifierFlags.contains(.option) {
                    // Cmd+Option+V → Move (paste as move)
                    state.activeExplorer.pasteMoving()
                    return nil
                } else if event.keyCode == 9, event.modifierFlags.contains(.command) {
                    // Cmd+V → Paste files
                    state.activeExplorer.paste()
                    return nil
                } else if event.keyCode == 0, event.modifierFlags.contains(.command) {
                    // Cmd+A → Select all files
                    state.activeExplorer.selectAll()
                    return nil
                } else if event.keyCode == 6, event.modifierFlags.contains(.command) {
                    // Cmd+Z → Undo last file operation
                    state.activeExplorer.undo()
                    return nil
                } else if (event.keyCode == 124 || event.keyCode == 123), event.modifierFlags.contains(.command) {
                    // Cmd+Right / Cmd+Left → Switch active pane
                    if state.showDualPane {
                        state.activePane = (event.keyCode == 124) ? .right : .left
                    }
                    return nil
                } else if event.keyCode == 125 || event.keyCode == 126 || event.keyCode == 123 || event.keyCode == 124 {
                    // Arrow keys: Down(125) Up(126) Left(123) Right(124)
                    let vm = state.activeExplorer
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
                    return nil // consume arrow keys
                }

                // Handle configurable shortcuts from Settings
                if let matched = Self.matchConfiguredShortcut(event: event) {
                    Self.executeShortcutAction(matched, appState: state)
                    return nil
                }

                // Type-ahead: printable characters jump to matching file
                if !event.modifierFlags.contains(.command),
                   !event.modifierFlags.contains(.control),
                   let chars = event.characters, !chars.isEmpty,
                   let scalar = chars.unicodeScalars.first,
                   CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains(scalar),
                   let delegate = AppDelegate.shared {
                    let vm = state.activeExplorer
                    if let window = event.window {
                        let windowID = ObjectIdentifier(window)
                        if delegate.typeAheadWindowID != windowID {
                            delegate.typeAheadBuffer = ""
                            delegate.typeAheadWindowID = windowID
                        }
                    }
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
                                guard let window = event.window,
                                            let state = MainWindowRegistry.shared.appState(for: window) else {
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

    func toggleQuickLookPreview(for url: URL, appState: AppState) {
        quickLookAppState = appState
        quickLookPanel.togglePreview(for: url)
    }

    func startAutoPreview(urls: [URL], startingAt startURL: URL? = nil, interval: TimeInterval, appState: AppState) {
        quickLookAppState = appState
        quickLookPanel.startAutoPreview(urls: urls, startingAt: startURL, interval: interval)
    }

    func showTextPreview(for url: URL, appState: AppState) {
        textPreviewAppState = appState
        if textPreviewPanel.isVisible {
            textPreviewPanel.updatePreview(for: url)
        } else {
            textPreviewPanel.togglePreview(for: url)
        }
    }

    func updateQuickLookIfVisible(url: URL, appState: AppState) {
        if quickLookPanel.isVisible, quickLookAppState === appState {
            quickLookPanel.updatePreview(for: url)
        }
    }

    func updateTextPreviewIfVisible(url: URL, appState: AppState) {
        if textPreviewPanel.isVisible, textPreviewAppState === appState {
            textPreviewPanel.updatePreview(for: url)
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

private struct MainWindowRoot: View {
    @Environment(\.openWindow) private var openWindow
    @State private var appState = AppState()
    @SceneStorage("mainWindow.leftPath") private var savedLeftPath = ""
    @SceneStorage("mainWindow.rightPath") private var savedRightPath = ""
    @SceneStorage("mainWindow.leftViewMode") private var savedLeftViewMode = ""
    @SceneStorage("mainWindow.rightViewMode") private var savedRightViewMode = ""
    @State private var didRestore = false
    @State private var shortcutVersion = 0

    let appDelegate: AppDelegate

    var body: some View {
        ContentView()
            .environment(appState)
            .focusedSceneValue(\.seekerAppState, appState)
            .background(MainWindowRegistrationView(appState: appState))
            .onAppear {
                appDelegate.installSpaceMonitor()
                restoreLocationsOnce()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                saveSceneLocations()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                saveSceneLocations()
            }
            .onReceive(NotificationCenter.default.publisher(for: .explorerDidNavigate)) { _ in
                saveSceneLocations()
            }
            .onReceive(NotificationCenter.default.publisher(for: .shortcutsChanged)) { _ in
                shortcutVersion += 1
            }
            .onOpenURL { url in
                appState.handleIncomingURL(url)
            }
    }

    private func restoreLocationsOnce() {
        guard !didRestore else { return }
        didRestore = true
        if !savedLeftPath.isEmpty || !savedRightPath.isEmpty {
            if !savedLeftPath.isEmpty {
                appState.leftPane.activeTab.navigateTo(URL(fileURLWithPath: savedLeftPath))
            }
            if !savedRightPath.isEmpty {
                appState.rightPane.activeTab.navigateTo(URL(fileURLWithPath: savedRightPath))
            }
            if let mode = FileExplorerViewModel.ViewMode(rawValue: savedLeftViewMode) {
                appState.leftPane.activeTab.applyViewModeWithoutPersisting(mode)
            }
            if let mode = FileExplorerViewModel.ViewMode(rawValue: savedRightViewMode) {
                appState.rightPane.activeTab.applyViewModeWithoutPersisting(mode)
            }
        } else {
            appState.restoreLastLocations()
        }
        if let url = MainWindowRegistry.shared.consumePendingReveal() {
            appState.activeExplorer.revealAndSelect(url)
        }
        saveSceneLocations()
    }

    private func saveSceneLocations() {
        savedLeftPath = appState.leftPane.activeTab.currentURL.path
        savedRightPath = appState.rightPane.activeTab.currentURL.path
        savedLeftViewMode = appState.leftPane.activeTab.viewMode.rawValue
        savedRightViewMode = appState.rightPane.activeTab.viewMode.rawValue
        if MainWindowRegistry.shared.mostRecentAppState === appState {
            appState.saveCurrentLocations()
        } else {
            DirectoryViewStateStore.shared.flushNow()
        }
    }
}

private struct HelperWindowRoot<Content: View>: View {
    @State private var sourceAppState: AppState
    private let content: (AppState) -> Content

    init(
        sourceWindowID: UUID?,
        fallback: AppState,
        @ViewBuilder content: @escaping (AppState) -> Content
    ) {
        _sourceAppState = State(initialValue:
            MainWindowRegistry.shared.appState(for: sourceWindowID)
                ?? MainWindowRegistry.shared.mostRecentAppState
                ?? fallback
        )
        self.content = content
    }

    var body: some View {
        content(sourceAppState)
            .environment(sourceAppState)
            .focusedSceneValue(\.seekerAppState, sourceAppState)
    }
}

@main
struct SeekerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.seekerAppState) private var focusedAppState
    @State private var appState = AppState()

    private var mainWindowCommandsEnabled: Bool {
        !AppDelegate.isHelperWindow(NSApp.keyWindow)
    }

    private var activeAppState: AppState {
        focusedAppState
            ?? MainWindowRegistry.shared.appState(for: NSApp.keyWindow)
            ?? MainWindowRegistry.shared.mostRecentAppState
            ?? appState
    }

    init() {
        // Show .help(...) tooltips after 500ms instead of macOS default (~2s).
        // Must be set before AppKit reads it during launch.
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 500
        ])
        UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")
    }

    var body: some Scene {
        WindowGroup("Seeker", id: "main") {
            MainWindowRoot(appDelegate: appDelegate)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 700)

        // Standalone duplicate-finder window. Non-modal so the user can
        // click "Open in new tab" on a row, switch to the main window,
        // inspect the file, and come back to keep triaging.
        WindowGroup("Find Duplicates", id: "duplicate-finder", for: DuplicateFinderWindowRequest.self) { $request in
            HelperWindowRoot(sourceWindowID: request?.sourceWindowID, fallback: appState) { source in
                DuplicateFinderView(rootURLs: request.flatMap { $0.rootURLs.isEmpty ? nil : $0.rootURLs }
                    ?? [source.activeExplorer.currentURL])
            }
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        // Standalone folder-compare window. Two directories diffed by
        // file name; lives in its own window like the duplicate finder.
        WindowGroup("Compare Folders", id: "directory-compare", for: DirectoryCompareWindowRequest.self) { $request in
            HelperWindowRoot(sourceWindowID: request?.sourceWindowID, fallback: appState) { source in
                let dirs = request?.directories
                if let dirs, dirs.count == 2 {
                    DirectoryCompareView(dirA: dirs[0], dirB: dirs[1])
                } else if let pair = source.resolveDirectoryPair() {
                    DirectoryCompareView(dirA: pair.0, dirB: pair.1)
                } else {
                    ContentUnavailableView(
                        "Choose Two Folders",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Open two different folders in the panes, then create this window again.")
                    )
                    .frame(minWidth: 640, minHeight: 420)
                }
            }
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        // Standalone recursive search window.
        WindowGroup("Search", id: "file-search", for: FileSearchWindowRequest.self) { $request in
            HelperWindowRoot(sourceWindowID: request?.sourceWindowID, fallback: appState) { source in
                FileSearchView(
                    root: request?.root ?? source.activeExplorer.currentURL,
                    sourceWindowID: request?.sourceWindowID
                )
            }
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        WindowGroup("Similar Images", id: "similar-images", for: SimilarImageSearchRequest.self) { $request in
            HelperWindowRoot(sourceWindowID: request?.sourceWindowID, fallback: appState) { source in
                if let request {
                    SimilarImageSearchView(request: request)
                } else if source.activeExplorer.canOpenSimilarImageSearch,
                          let referenceURL = source.activeExplorer.selectedFile?.url {
                    SimilarImageSearchView(request: SimilarImageSearchRequest(
                        referenceURL: referenceURL,
                        targetDirectory: source.activeExplorer.currentURL
                    ))
                } else {
                    ContentUnavailableView(
                        "Select an Image",
                        systemImage: "photo.badge.magnifyingglass",
                        description: Text("Select an image in the main window, then create this window again.")
                    )
                    .frame(minWidth: 640, minHeight: 420)
                }
            }
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        WindowGroup("Semantic Search", id: "semantic-search", for: SemanticSearchRequest.self) { $request in
            HelperWindowRoot(sourceWindowID: request?.sourceWindowID, fallback: appState) { source in
                SemanticSearchView(request: request ?? SemanticSearchRequest(
                    targetDirectory: source.activeExplorer.currentURL
                ))
            }
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        // Standalone folder-sync window.
        WindowGroup("Sync Folders", id: "folder-sync", for: FolderSyncWindowRequest.self) { $request in
            HelperWindowRoot(sourceWindowID: request?.sourceWindowID, fallback: appState) { source in
                let dirs = request?.directories
                if let dirs, dirs.count == 2 {
                    FolderSyncView(rootA: dirs[0], rootB: dirs[1])
                } else if let pair = source.resolveDirectoryPair() {
                    FolderSyncView(rootA: pair.0, rootB: pair.1)
                } else {
                    ContentUnavailableView(
                        "Choose Two Folders",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                        description: Text("Open two different folders in the panes, then create this window again.")
                    )
                    .frame(minWidth: 640, minHeight: 420)
                }
            }
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()
        .commands {
            // MARK: - File Menu Windows
            CommandGroup(replacing: .newItem) {
                let appState = activeAppState
                Button("New Seeker Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Find Duplicates\u{2026}") {
                    appState.openDuplicateFinder()
                }
                .disabled(!mainWindowCommandsEnabled)

                Button("Compare Folders\u{2026}") {
                    appState.openDirectoryCompare()
                }
                .disabled(!mainWindowCommandsEnabled || !appState.canCompareDirectories)

                Button("Search\u{2026}") {
                    appState.openSearch()
                }
                .disabled(!mainWindowCommandsEnabled)

                Button("Find Similar Images\u{2026}") {
                    appState.openSimilarImageSearch()
                }
                .disabled(!mainWindowCommandsEnabled || !appState.activeExplorer.canOpenSimilarImageSearch)

                Button("Semantic Search\u{2026}") {
                    appState.openSemanticSearch()
                }
                .disabled(!mainWindowCommandsEnabled)

                Button("Sync Folders\u{2026}") {
                    appState.openFolderSync()
                }
                .disabled(!mainWindowCommandsEnabled || !appState.canCompareDirectories)
            }

            // MARK: - View Menu
            CommandGroup(after: .sidebar) {
                let appState = activeAppState
                Button("Toggle Favorites Sidebar") {
                    withAnimation { appState.showFavorites.toggle() }
                }
                .shortcut(for: .toggleFavorites)
                .disabled(!mainWindowCommandsEnabled)

                Button("Toggle Dual Pane") {
                    withAnimation { appState.showDualPane.toggle() }
                }
                .shortcut(for: .toggleDualPane)
                .disabled(!mainWindowCommandsEnabled)

                Button("Swap Panes") {
                    appState.swapPanes()
                }
                .disabled(!mainWindowCommandsEnabled || !appState.showDualPane)

                Divider()

                Button("List View") {
                    appState.activeExplorer.viewMode = .list
                }
                .shortcut(for: .listView)
                .disabled(!mainWindowCommandsEnabled)

                Button("Icon View") {
                    appState.activeExplorer.viewMode = .icons
                }
                .shortcut(for: .iconView)
                .disabled(!mainWindowCommandsEnabled)

                Button("Column View") {
                    appState.activeExplorer.viewMode = .columns
                }
                .shortcut(for: .columnView)
                .disabled(!mainWindowCommandsEnabled)

                Divider()

                Button("Zoom In") {
                    appState.activeExplorer.zoomIconsIn()
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!mainWindowCommandsEnabled || appState.activeExplorer.viewMode != .icons)

                Button("Zoom Out") {
                    appState.activeExplorer.zoomIconsOut()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!mainWindowCommandsEnabled || appState.activeExplorer.viewMode != .icons)

                Button("Actual Size") {
                    appState.activeExplorer.resetIconZoom()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!mainWindowCommandsEnabled || appState.activeExplorer.viewMode != .icons)

                Divider()

                Button(appState.activeExplorer.showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files") {
                    appState.activeExplorer.showHiddenFiles.toggle()
                    appState.activeExplorer.loadFiles()
                }
                .shortcut(for: .toggleHiddenFiles)
                .disabled(!mainWindowCommandsEnabled)
            }

            // MARK: - File Operations (Edit menu)
            CommandGroup(after: .pasteboard) {
                let appState = activeAppState
                Divider()

                Button("Open") {
                    if let file = appState.activeExplorer.selectedFile {
                        appState.activeExplorer.openItem(file)
                    }
                }
                .shortcut(for: .openFile)
                .disabled(!mainWindowCommandsEnabled)

                Button("New Folder") {
                    appState.activeExplorer.createNewFolder()
                }
                .shortcut(for: .newFolder)
                .disabled(!mainWindowCommandsEnabled)

                Button("New File") {
                    appState.activeExplorer.createNewFile()
                }
                .shortcut(for: .newFile)
                .disabled(!mainWindowCommandsEnabled)

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
                .disabled(AppDelegate.isHelperWindow(NSApp.keyWindow)
                    && !AppDelegate.isTriageWindow(NSApp.keyWindow))

                Button("Delete Immediately\u{2026}") {
                    // Permanent delete bypasses the Trash. Only meaningful
                    // for the main window; ignore when a helper window
                    // (which only trashes) is key.
                    if !AppDelegate.isHelperWindow(NSApp.keyWindow) {
                        appState.activeExplorer.deleteSelectedPermanently()
                    }
                }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(!mainWindowCommandsEnabled)

                Button("Rename") {
                    if let file = appState.activeExplorer.selectedFile {
                        appState.activeExplorer.beginRename(file)
                    }
                }
                .disabled(!mainWindowCommandsEnabled)

                Button("Batch Rename\u{2026}") {
                    appState.openBatchRename()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!mainWindowCommandsEnabled)

                Divider()

                Button("Copy to Other Pane") {
                    appState.copyToOtherPane()
                }
                .shortcut(for: .copyToOtherPane)
                .disabled(!mainWindowCommandsEnabled)

                Button("Move to Other Pane") {
                    appState.moveToOtherPane()
                }
                .shortcut(for: .moveToOtherPane)
                .disabled(!mainWindowCommandsEnabled)
            }

            // MARK: - Go Menu
            CommandMenu("Go") {
                let appState = activeAppState
                Button("Back") {
                    appState.activeExplorer.goBack()
                }
                .shortcut(for: .goBack)
                .disabled(!mainWindowCommandsEnabled)

                Button("Forward") {
                    appState.activeExplorer.goForward()
                }
                .shortcut(for: .goForward)
                .disabled(!mainWindowCommandsEnabled)

                Button("Enclosing Folder") {
                    appState.activeExplorer.goUp()
                }
                .shortcut(for: .enclosingFolder)
                .disabled(!mainWindowCommandsEnabled)

                Divider()

                Button("Home") {
                    appState.activeExplorer.navigateTo(
                        FileManager.default.homeDirectoryForCurrentUser
                    )
                }
                .shortcut(for: .goHome)
                .disabled(!mainWindowCommandsEnabled)

                Button("Desktop") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                    appState.activeExplorer.navigateTo(url)
                }
                .shortcut(for: .goDesktop)
                .disabled(!mainWindowCommandsEnabled)

                Button("Downloads") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                    appState.activeExplorer.navigateTo(url)
                }
                .shortcut(for: .goDownloads)
                .disabled(!mainWindowCommandsEnabled)

                Button("Documents") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
                    appState.activeExplorer.navigateTo(url)
                }
                .disabled(!mainWindowCommandsEnabled)

                Button("Applications") {
                    appState.activeExplorer.navigateTo(URL(fileURLWithPath: "/Applications"))
                }
                .disabled(!mainWindowCommandsEnabled)

                Divider()

                Button("Go to Folder…") {
                    appState.requestEditPath()
                }
                .shortcut(for: .goToFolder)
                .disabled(!mainWindowCommandsEnabled)
            }

            // MARK: - Tabs
            CommandMenu("Tab") {
                let appState = activeAppState
                Button("New Tab") {
                    let pane = appState.activePane == .left ? appState.leftPane : appState.rightPane
                    pane.addTab()
                }
                .shortcut(for: .newTab)
                .disabled(!mainWindowCommandsEnabled)

                Button("Close Tab") {
                    let pane = appState.activePane == .left ? appState.leftPane : appState.rightPane
                    pane.closeTab(at: pane.activeTabIndex)
                }
                .shortcut(for: .closeTab)
                .disabled(!mainWindowCommandsEnabled)
            }

            // MARK: - Refresh
            CommandGroup(after: .toolbar) {
                let appState = activeAppState
                Button("Refresh") {
                    appState.activeExplorer.loadFiles()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!mainWindowCommandsEnabled)
            }
        }

        Settings {
            SettingsView()
                .environment(activeAppState)
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
